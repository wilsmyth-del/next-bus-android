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
  Arrival? _nextDeparture;
  bool _isFavourite = false;
  ArrivalMode _mode = ArrivalMode.live;

  /// null = Now. Non-null = Time mode, anchored here. Deliberately not
  /// persisted: every stop opens on Now, always. A stop that silently reopens
  /// showing 14:00 results three days later is the app being confidently wrong,
  /// which is the failure family this project keeps hitting.
  TimeOfDay? _planTime;

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
      final plan = _planTime;
      final result = plan == null
          ? await TranslinkService.getArrivals(widget.stopCode,
              forceRefresh: forceRefresh)
          : await TranslinkService.getArrivalsAt(
              widget.stopCode, plan.hour * 3600 + plan.minute * 60);
      // Max 3 per route, preserving sort order (soonest first). Skipped in Time
      // mode: there, a chosen departure time deliberately brings every route at
      // it, and capping per route would silently drop one of them.
      List<Arrival> filtered;
      if (plan != null) {
        filtered = result.arrivals;
      } else {
        final routeCount = <String, int>{};
        filtered = <Arrival>[];
        for (final a in result.arrivals) {
          final count = routeCount[a.route] ?? 0;
          if (count < 3) {
            filtered.add(a);
            routeCount[a.route] = count + 1;
          }
        }
      }
      if (mounted) setState(() {
        _loading = false;
        _arrivals = filtered;
        _nextDeparture = result.nextDeparture;
        _mode = result.mode;
      });
    } catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Opens the OS picker at the currently-anchored time, or at now when
  /// switching into Time mode. Deliberately `showTimePicker` and not a dropdown
  /// of times: a dropdown has to answer "what increment?", and every answer is
  /// wrong — 5 minutes gives 288 entries, 15 minutes still cannot express 14:05.
  /// The native picker has no increment question to answer.
  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _planTime ?? TimeOfDay.now(),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF60A5FA),
            surface: Color(0xFF1A1D27),
          ),
        ),
        child: child!,
      ),
    );
    if (picked == null) return;          // cancelled — stay where we were
    setState(() => _planTime = picked);
    await _load();
  }

  Future<void> _setNowMode() async {
    if (_planTime == null) return;       // already there, nothing to reload
    setState(() => _planTime = null);
    await _load();
  }

  /// Now | Time, in a strip below the AppBar rather than an AppBar action: the
  /// bar already carries star and refresh, and a segmented control does not
  /// belong in an action slot. The Time segment shows the chosen time as its own
  /// label once set, so the current state is readable with no caption; tapping
  /// it again reopens the picker.
  Widget _buildModeStrip() {
    final plan = _planTime;
    return Container(
      width: double.infinity,
      color: const Color(0xFF1A1D27),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SegmentedButton<bool>(
        segments: [
          const ButtonSegment<bool>(value: false, label: Text('Now')),
          ButtonSegment<bool>(
            value: true,
            label: Text(plan == null ? 'Time' : plan.format(context)),
          ),
        ],
        selected: {plan != null},
        showSelectedIcon: false,
        onSelectionChanged: (sel) {
          if (sel.first) {
            _pickTime();
          } else {
            _setNowMode();
          }
        },
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected)
                  ? const Color(0xFF60A5FA)
                  : const Color(0xFF0F1117)),
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected)
                  ? const Color(0xFF0F1117)
                  : Colors.white70),
        ),
      ),
    );
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
      body: Column(
        children: [
          _buildModeStrip(),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return _loading
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
                  ? Center(child: _buildEmptyState())
                  : ListView.builder(
                      itemCount: _arrivals.length,
                      itemBuilder: (context, i) => _buildRow(_arrivals[i]),
                    );
  }

  /// Empty is not one state. "Nothing due, and the first bus back is at 07:30"
  /// is a useful answer; "nothing due" on its own is indistinguishable from a
  /// stale schedule, which is the failure this app most needs to not have.
  Widget _buildEmptyState() {
    final plan = _planTime;
    if (plan != null) {
      // Time mode has an anchor, so it can name what it found nothing near —
      // which distinguishes "nothing around 03:00" from "this app is broken".
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          'No buses near ${plan.format(context)}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54),
        ),
      );
    }

    final next = _nextDeparture;
    if (next == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          'No upcoming buses',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    final hours = next.minutesAway ~/ 60;
    final mins = next.minutesAway % 60;
    final away = hours > 0 ? '${hours}h ${mins}m' : '${mins}m';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'No buses due',
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 12),
          Text(
            'Next bus ${next.arrivalTime}',
            style: const TextStyle(
              color: Color(0xFF60A5FA),
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            next.route.isEmpty ? 'in $away' : '${next.route} · in $away',
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(Arrival a) {
    final planning = _planTime != null;
    final past = a.isPast;

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

    // Planning at noon for a 14:00 bus renders "120m" — true, useless, faintly
    // absurd. In Time mode the clock time is the answer and minutes-away is
    // noise, so the two swap places.
    final leadText = planning ? a.arrivalTime : '${a.minutesAway}m';

    // The headsign is already in the pipeline and has never been shown.
    // Planning is exactly when it earns its place: "25 → Brentwood" is worth
    // more than "Route 25" when you are deciding from the kitchen.
    final title = a.destination.isEmpty
        ? 'Route ${a.route}'
        : '${a.route} → ${a.destination}';

    final String subtitle;
    if (!planning) {
      subtitle = a.arrivalTime;
    } else if (past) {
      subtitle = 'Departed';
    } else {
      final h = a.minutesAway ~/ 60;
      final m = a.minutesAway % 60;
      subtitle = h > 0 ? 'in ${h}h ${m}m' : 'in ${m}m';
    }

    // A bus you cannot catch must not look like one you can, least of all to
    // someone who is already rushing. Struck through AND dimmed AND labelled —
    // one signal would be a colour a tired user reads past at a dark bus stop.
    return Opacity(
      opacity: past ? 0.45 : 1.0,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: const Color(0xFF1E293B),
          child: Text(
            leadText,
            style: TextStyle(
              color: past ? Colors.white38 : const Color(0xFF60A5FA),
              fontSize: 12,
              fontWeight: FontWeight.bold,
              decoration: past ? TextDecoration.lineThrough : null,
              decorationColor: Colors.white38,
            ),
          ),
        ),
        title: Text(
          title,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: past ? Colors.white54 : Colors.white,
            fontWeight: FontWeight.bold,
            decoration: past ? TextDecoration.lineThrough : null,
            decorationColor: Colors.white38,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            color: past ? Colors.white38 : Colors.white54,
            fontStyle: past ? FontStyle.italic : FontStyle.normal,
          ),
        ),
        trailing: Text(
          sourceLabel,
          style: TextStyle(color: sourceColor, fontSize: 12),
        ),
      ),
    );
  }
}
