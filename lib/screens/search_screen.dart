import 'package:flutter/material.dart';
import '../services/db_service.dart';
import '../services/gtfs_service.dart';
import 'arrivals_screen.dart';
import 'camera_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  bool _loading = true;
  bool _updating = false;
  String _status = 'Checking local data...';
  String? _error;
  FeedInfo? _pendingUpdate;
  List<Map<String, dynamic>> _results = [];
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
      _status = 'Checking local data...';
      _pendingUpdate = null;
    });
    try {
      final hasData = await DbService.hasStops();
      if (!hasData) {
        setState(() => _status = 'Finding latest GTFS feed...');
        final feed = await GtfsService.findLatestFeed();
        if (feed == null) throw Exception('GTFS feed not found');
        await GtfsService.downloadAndBuild(
          feed: feed,
          onStatus: (s) {
            if (mounted) setState(() => _status = s);
          },
        );
      } else {
        // Stops exist — check quietly for an update
        setState(() => _status = 'Checking for updates...');
        final update = await GtfsService.checkForUpdate();
        if (mounted) setState(() => _pendingUpdate = update);
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _applyUpdate(FeedInfo feed) async {
    setState(() {
      _updating = true;
      _pendingUpdate = null;
      _status = 'Updating...';
    });
    try {
      await GtfsService.downloadAndBuild(
        feed: feed,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _manualRefresh() async {
    setState(() {
      _updating = true;
      _pendingUpdate = null;
      _status = 'Looking for updates...';
    });
    try {
      final feed = await GtfsService.findLatestFeed();
      if (feed == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No GTFS feed found')),
          );
        }
        return;
      }
      final stored = await DbService.getGtfsDate();
      if (stored == feed.date) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Already up to date (${feed.date})')),
          );
        }
        return;
      }
      await GtfsService.downloadAndBuild(
        feed: feed,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Updated to ${feed.date}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _search(String query) async {
    if (query.length < 2) {
      setState(() => _results = []);
      return;
    }
    final results = await DbService.searchStops(query);
    if (mounted) setState(() => _results = results);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Next Bus', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1A1D27),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.camera_alt_outlined),
            tooltip: 'Scan stop number',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CameraScreen()),
            ),
          ),
          if (!_loading)
            _updating
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF60A5FA),
                      ),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Check for GTFS update',
                    onPressed: _manualRefresh,
                  ),
        ],
      ),
      body: _loading
          ? _buildLoading()
          : _error != null
              ? _buildError()
              : _buildSearch(),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Color(0xFF60A5FA)),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _status,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
            const SizedBox(height: 16),
            Text(
              _error!,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _init,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearch() {
    return Column(
      children: [
        if (_pendingUpdate != null)
          MaterialBanner(
            backgroundColor: const Color(0xFF1E293B),
            content: Text(
              'GTFS update available (${_pendingUpdate!.date})',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => _applyUpdate(_pendingUpdate!),
                child: const Text('Update', style: TextStyle(color: Color(0xFF60A5FA))),
              ),
              TextButton(
                onPressed: () => setState(() => _pendingUpdate = null),
                child: const Text('Later', style: TextStyle(color: Colors.white38)),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _controller,
            onChanged: _search,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Enter stop number',
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon: const Icon(Icons.search, color: Colors.white38),
              filled: true,
              fillColor: const Color(0xFF1A1D27),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, i) {
              final stop = _results[i];
              return ListTile(
                leading: const Icon(Icons.directions_bus, color: Color(0xFF60A5FA)),
                title: Text(
                  stop['stop_code'] as String,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  stop['stop_name'] as String,
                  style: const TextStyle(color: Colors.white54),
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ArrivalsScreen(
                        stopCode: stop['stop_code'] as String,
                        stopName: stop['stop_name'] as String,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
