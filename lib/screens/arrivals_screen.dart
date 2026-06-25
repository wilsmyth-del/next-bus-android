import 'package:flutter/material.dart';
import '../services/translink_service.dart';
import '../services/db_service.dart';

class ArrivalsScreen extends StatefulWidget {
  final String stopCode;
  final String stopName;

  const ArrivalsScreen({
    super.key,
    required this.stopCode,
    required this.stopName,
  });

  @override
  State<ArrivalsScreen> createState() => _ArrivalsScreenState();
}

class _ArrivalsScreenState extends State<ArrivalsScreen> {
  bool _loading = true;
  String? _error;
  List<Arrival> _arrivals = [];
  bool _isFavourite = false;
  ArrivalMode _mode = ArrivalMode.live;

  @override
  void initState() {
    super.initState();
    _load();
    _checkFavourite();
  }

  Future<void> _checkFavourite() async {
    final fav = await DbService.isFavourite(widget.stopCode);
    if (mounted) setState(() => _isFavourite = fav);
  }

  Future<void> _toggleFavourite() async {
    if (_isFavourite) {
      await DbService.removeFavourite(widget.stopCode);
    } else {
      await DbService.addFavourite(widget.stopCode, widget.stopName);
    }
    if (mounted) setState(() => _isFavourite = !_isFavourite);
  }

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await TranslinkService.getArrivals(widget.stopCode, forceRefresh: forceRefresh);
      // Max 3 per route, preserving sort order (soonest first)
      final routeCount = <String, int>{};
      final filtered = <Arrival>[];
      for (final a in result.arrivals) {
        final count = routeCount[a.route] ?? 0;
        if (count < 3) {
          filtered.add(a);
          routeCount[a.route] = count + 1;
        }
      }
      if (mounted) setState(() {
        _loading = false;
        _arrivals = filtered;
        _mode = result.mode;
      });
    } catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1117),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Stop ${widget.stopCode}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              widget.stopName,
              style: const TextStyle(fontSize: 12, color: Colors.white54),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1A1D27),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(
              _isFavourite ? Icons.star : Icons.star_border,
              color: _isFavourite ? const Color(0xFF60A5FA) : null,
            ),
            onPressed: _toggleFavourite,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(forceRefresh: true),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF60A5FA)),
            )
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline,
                            color: Colors.redAccent, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          style: const TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : _arrivals.isEmpty
                  ? const Center(
                      child: Text(
                        'No upcoming buses',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _arrivals.length,
                      itemBuilder: (context, i) => _buildRow(_arrivals[i]),
                    ),
    );
  }

  Widget _buildRow(Arrival a) {
    final sourceColor = a.source == 'live'
        ? Colors.greenAccent
        : a.source == 'approx'
            ? Colors.orangeAccent
            : Colors.white38;
    final sourceLabel = a.source == 'live'
        ? 'Live'
        : a.source == 'approx'
            ? 'Approx'
            : 'Scheduled';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF1E293B),
        child: Text(
          '${a.minutesAway}m',
          style: const TextStyle(
            color: Color(0xFF60A5FA),
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(
        'Route ${a.route}',
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        a.arrivalTime,
        style: const TextStyle(color: Colors.white54),
      ),
      trailing: Text(
        sourceLabel,
        style: TextStyle(color: sourceColor, fontSize: 12),
      ),
    );
  }
}
