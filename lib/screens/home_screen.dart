import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../services/api_key_service.dart';
import '../services/db_service.dart';
import '../services/gtfs_service.dart';
import 'arrivals_screen.dart';
import 'camera_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ── colours ──────────────────────────────────────────────────────────────
  static const Color _bg      = Color(0xFF0F1117);
  static const Color _surface = Color(0xFF1A1D27);
  static const Color _accent  = Color(0xFF60A5FA);

  // ── state ─────────────────────────────────────────────────────────────────
  bool _liteMode = false;
  List<Map<String, dynamic>> _favourites = [];
  FeedInfo? _pendingUpdate;

  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];

  bool _loading = true;
  String _loadingStatus = 'Loading…';
  bool _hasStops = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ── initialisation ────────────────────────────────────────────────────────

  Future<void> _init() async {
    _liteMode = await ApiKeyService.getLiteMode();
    _hasStops = await DbService.hasStops();

    if (!_hasStops) {
      // First-launch GTFS download flow.
      if (_liteMode) {
        setState(() {
          _loading = false;
          _loadingStatus = '';
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Lite mode is on — GTFS data cannot be downloaded. '
                'Disable Lite mode in Settings first.',
              ),
            ),
          );
        }
        return;
      }

      setState(() => _loadingStatus = 'Checking for GTFS data…');

      try {
        final feed = await GtfsService.findLatestFeed();
        if (feed == null) {
          setState(() {
            _loading = false;
            _loadingStatus = 'No GTFS feed found.';
          });
          return;
        }

        setState(() => _loadingStatus = 'Downloading stop data…');
        await GtfsService.downloadAndBuild(
          feed: feed,
          onStatus: (msg) {
            if (mounted) setState(() => _loadingStatus = msg);
          },
        );

        _hasStops = await DbService.hasStops();
      } catch (e) {
        if (mounted) {
          setState(() {
            _loading = false;
            _loadingStatus = 'Download failed: $e';
          });
        }
        return;
      }
    }

    // Stops exist — load favourites.
    await _loadFavourites();

    // Passive update check (not in lite mode).
    if (!_liteMode) {
      try {
        final check = await GtfsService.checkForUpdate();
        if (check.status == UpdateStatus.available && mounted) {
          setState(() => _pendingUpdate = check.feed);
        }
      } catch (_) {
        // Ignore background check failures silently. The check is a courtesy;
        // it never downloads anything, so a failure costs the user nothing.
      }
    }

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadFavourites() async {
    // sqflite's query() result is backed by the platform-channel decode and
    // is not growable/modifiable — wrap in a real growable list so local
    // removeAt/insert (used for optimistic delete below) don't throw.
    final favs = await DbService.getFavourites();
    if (mounted) {
      setState(() => _favourites = List<Map<String, dynamic>>.from(favs));
    }
  }

  // ── search ────────────────────────────────────────────────────────────────

  Future<void> _onSearchChanged(String query) async {
    if (query.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    final results = await DbService.searchStops(query);
    if (mounted) setState(() => _searchResults = results);
  }

  // ── favourites actions ────────────────────────────────────────────────────

  Future<void> _deleteFavourite(String stopCode) async {
    try {
      final removedIndex = _favourites.indexWhere((f) => f['stop_code'] == stopCode);
      if (removedIndex == -1) return;
      final removed = _favourites[removedIndex];

      setState(() => _favourites.removeAt(removedIndex));

      final rowsAffected = await DbService.removeFavourite(stopCode);
      if (rowsAffected == 0) {
        if (mounted) {
          setState(() => _favourites.insert(removedIndex, removed));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Delete did not match any row for stop_code=$stopCode')),
          );
        }
      }
    } catch (e, st) {
      debugPrint('_deleteFavourite failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  /// Persist a drag. Optimistic like [_deleteFavourite]: the list moves first
  /// and rolls back whole if the write does not take.
  Future<void> _reorderFavourites(int oldIndex, int newIndex) async {
    // ReorderableListView reports newIndex as the slot the row would occupy
    // *before* it is lifted out, so every downward move is reported one too
    // far. This adjustment is the framework's documented contract, not a
    // workaround.
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex == oldIndex) return;

    // _favourites is already a growable copy (see _loadFavourites) — the #308
    // read-only-list bug is guarded there, and removeAt/insert rely on it.
    final previous = List<Map<String, dynamic>>.from(_favourites);

    setState(() {
      final moved = _favourites.removeAt(oldIndex);
      _favourites.insert(newIndex, moved);
    });

    try {
      final order = _favourites.map((f) => f['stop_code'] as String).toList();
      final updated = await DbService.reorderFavourites(order);
      if (updated != order.length && mounted) {
        setState(() => _favourites = previous);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Reorder wrote $updated of ${order.length} stops — order restored'),
          ),
        );
      }
    } catch (e, st) {
      debugPrint('_reorderFavourites failed: $e\n$st');
      if (mounted) {
        setState(() => _favourites = previous);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reorder failed: $e')),
        );
      }
    }
  }

  Future<void> _renameFavourite(String stopCode, String currentName) async {
    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: const Text('Rename stop', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white38),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: _accent),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save', style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
    controller.dispose();

    if (newName != null && newName.isNotEmpty && newName != currentName) {
      await DbService.updateFavouriteName(stopCode, newName);
      await _loadFavourites();
    }
  }

  // ── navigation helpers ────────────────────────────────────────────────────

  Future<void> _openArrivals(String stopCode, String stopName) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArrivalsScreen(stopCode: stopCode, stopName: stopName),
      ),
    );
    // Clear the search so returning from arrivals lands back on favourites,
    // not stuck on stale search results with no way back.
    _searchController.clear();
    // Reload in case a stop was starred/unstarred while viewing arrivals.
    await _loadFavourites();
  }

  /// Shared by the AppBar icon and the update banner. Re-checks on return so a
  /// banner does not sit there claiming an update is available after Settings
  /// has just installed it.
  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (!mounted) return;
    try {
      final check = await GtfsService.checkForUpdate();
      if (mounted) {
        setState(() => _pendingUpdate =
            check.status == UpdateStatus.available ? check.feed : null);
      }
    } catch (_) {
      // A failed re-check should not leave a stale banner asserting an update.
      if (mounted) setState(() => _pendingUpdate = null);
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchResults = []);
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        foregroundColor: Colors.white,
        title: const Text(
          'Next Bus',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.camera_alt_outlined),
            tooltip: 'Scan stop number',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CameraScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: _loading ? _buildLoadingView() : _buildMainBody(),
    );
  }

  // ── loading view ──────────────────────────────────────────────────────────

  Widget _buildLoadingView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: _accent),
            const SizedBox(height: 24),
            Text(
              _loadingStatus,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ── main body ─────────────────────────────────────────────────────────────

  Widget _buildMainBody() {
    final bool searching = _searchController.text.isNotEmpty;

    return Column(
      children: [
        // Pending GTFS update banner.
        if (_pendingUpdate != null) _buildUpdateBanner(),

        // Search field.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _searchController,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Enter stop number',
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon: const Icon(Icons.search, color: Colors.white38),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Colors.white38),
                      tooltip: 'Back to favourites',
                      onPressed: _clearSearch,
                    )
                  : null,
              filled: true,
              fillColor: _surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            ),
            onChanged: _onSearchChanged,
          ),
        ),

        // Results area.
        Expanded(
          child: searching ? _buildSearchResults() : _buildFavouritesList(),
        ),
      ],
    );
  }

  // ── GTFS update banner ────────────────────────────────────────────────────

  /// Tells, and points. It does not download (#321 slice B2).
  ///
  /// This banner used to call the same `_manualRefresh` as the AppBar icon, so
  /// the worst possible moment to start a multi-minute blocking download — the
  /// moment someone opened the app to catch a bus — was two taps away on the
  /// first screen. Settings is now the only path, and it is the path that asks
  /// about mobile data first.
  Widget _buildUpdateBanner() {
    return MaterialBanner(
      backgroundColor: _surface,
      content: Text(
        'Newer schedule data is available (${_pendingUpdate!.date}). '
        'Update it in Settings — it takes a few minutes.',
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => _pendingUpdate = null),
          child: const Text('Dismiss', style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: _openSettings,
          child: const Text('Settings', style: TextStyle(color: _accent)),
        ),
      ],
    );
  }

  // ── search results list ───────────────────────────────────────────────────

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty) {
      return const Center(
        child: Text('No stops found.', style: TextStyle(color: Colors.white38)),
      );
    }

    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final stop = _searchResults[index];
        final stopCode = stop['stop_code'] as String;
        final stopName = stop['stop_name'] as String;
        return ListTile(
          leading: const Icon(Icons.directions_bus, color: _accent),
          title: Text(stopCode,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          subtitle: Text(stopName, style: const TextStyle(color: Colors.white54)),
          onTap: () => _openArrivals(stopCode, stopName),
        );
      },
    );
  }

  // ── favourites list ───────────────────────────────────────────────────────

  Widget _buildFavouritesList() {
    if (_favourites.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.star_border, size: 48, color: Colors.white24),
              SizedBox(height: 16),
              Text('No saved stops yet.',
                  style: TextStyle(color: Colors.white54, fontSize: 16)),
              SizedBox(height: 8),
              Text(
                'Tap the star on any arrivals screen to save a stop here.',
                style: TextStyle(color: Colors.white38, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // Long-press to drag, with no drag handles (Wil, 2026-09-20): the default
    // Android handle sits on the right edge, which is exactly where
    // flutter_slidable's swipe-to-remove begins. That swipe took four rounds
    // to get right (#308) and is not being asked to share an edge.
    return ReorderableListView.builder(
      itemCount: _favourites.length,
      onReorder: _reorderFavourites,
      buildDefaultDragHandles: false,
      itemBuilder: (context, index) {
        final fav = _favourites[index];
        final stopCode = fav['stop_code'] as String;
        final stopName = fav['stop_name'] as String;

        return ReorderableDelayedDragStartListener(
          key: ValueKey(stopCode),
          index: index,
          child: Slidable(
            key: Key(stopCode),
            endActionPane: ActionPane(
              motion: const DrawerMotion(),
              extentRatio: 0.5,
              children: [
                SlidableAction(
                  onPressed: (_) => _renameFavourite(stopCode, stopName),
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  icon: Icons.edit,
                  label: 'Rename',
                ),
                SlidableAction(
                  onPressed: (_) => _deleteFavourite(stopCode),
                  backgroundColor: Colors.red.shade700,
                  foregroundColor: Colors.white,
                  icon: Icons.delete,
                  label: 'Delete',
                ),
              ],
            ),
            child: ListTile(
              tileColor: _surface,
              leading: const Icon(Icons.star, color: _accent, size: 20),
              title: Text(stopCode,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: Text(stopName, style: const TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () => _openArrivals(stopCode, stopName),
            ),
          ),
        );
      },
    );
  }
}
