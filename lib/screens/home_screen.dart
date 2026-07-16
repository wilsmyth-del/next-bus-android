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
        final update = await GtfsService.checkForUpdate();
        if (update != null && mounted) {
          setState(() => _pendingUpdate = update);
        }
      } catch (_) {
        // Ignore background check failures silently.
      }
    }

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadFavourites() async {
    final favs = await DbService.getFavourites();
    if (mounted) setState(() => _favourites = favs);
  }

  // ── GTFS refresh (AppBar action) ──────────────────────────────────────────

  Future<void> _manualRefresh() async {
    setState(() {
      _loading = true;
      _loadingStatus = 'Checking for GTFS update…';
    });

    try {
      final feed = await GtfsService.findLatestFeed();
      if (feed == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No GTFS feed found.')),
          );
        }
        setState(() => _loading = false);
        return;
      }

      setState(() => _loadingStatus = 'Downloading stop data…');
      await GtfsService.downloadAndBuild(
        feed: feed,
        onStatus: (msg) {
          if (mounted) setState(() => _loadingStatus = msg);
        },
      );

      await _loadFavourites();

      if (mounted) {
        setState(() {
          _pendingUpdate = null;
          _loading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Stop data updated.')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: $e')),
        );
      }
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
    setState(() => _favourites.removeWhere((f) => f['stop_code'] == stopCode));
    await DbService.removeFavourite(stopCode);
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
            icon: const Icon(Icons.refresh),
            tooltip: 'Check for GTFS update',
            onPressed: _liteMode ? null : _manualRefresh,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
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

  Widget _buildUpdateBanner() {
    return MaterialBanner(
      backgroundColor: _surface,
      content: Text(
        'GTFS update available (${_pendingUpdate!.date}).',
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => _pendingUpdate = null),
          child: const Text('Dismiss', style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: _liteMode ? null : _manualRefresh,
          child: const Text('Refresh', style: TextStyle(color: _accent)),
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

    return ListView.builder(
      itemCount: _favourites.length,
      itemBuilder: (context, index) {
        final fav = _favourites[index];
        final stopCode = fav['stop_code'] as String;
        final stopName = fav['stop_name'] as String;

        return Slidable(
          key: Key(stopCode),
          endActionPane: ActionPane(
            motion: const DrawerMotion(),
            extentRatio: 0.5,
            children: [
              SlidableAction(
                onPressed: (ctx) {
                  Slidable.of(ctx)?.close();
                  _renameFavourite(stopCode, stopName);
                },
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                icon: Icons.edit,
                label: 'Rename',
              ),
              SlidableAction(
                onPressed: (ctx) {
                  Slidable.of(ctx)?.close();
                  _deleteFavourite(stopCode);
                },
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
        );
      },
    );
  }
}
