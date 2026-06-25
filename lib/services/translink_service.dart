import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'api_key_service.dart';
import 'db_service.dart';
import 'gtfs_rt_parser.dart';

class Arrival {
  final String route;
  final String destination;
  final int minutesAway;
  final String arrivalTime;
  final String source; // 'live', 'approx', 'scheduled'
  final int delaySeconds;

  const Arrival({
    required this.route,
    required this.destination,
    required this.minutesAway,
    required this.arrivalTime,
    required this.source,
    required this.delaySeconds,
  });
}

enum ArrivalMode { live, scheduled }

class ArrivalResult {
  final List<Arrival> arrivals;
  final ArrivalMode mode;
  const ArrivalResult(this.arrivals, this.mode);
}

class TranslinkService {
  static final Map<String, (ArrivalResult, DateTime)> _cache = {};
  static const _cacheTtl = Duration(seconds: 60);
  static const _maxArrivals = 4;

  // Feed-level cache — the GTFS-RT payload is shared across all stop lookups
  static Uint8List? _feedBytes;
  static DateTime? _feedFetchedAt;
  static const _feedTtl = Duration(seconds: 30);

  static Future<ArrivalResult> getArrivals(String stopCode, {bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = _cache[stopCode];
      if (cached != null && DateTime.now().difference(cached.$2) < _cacheTtl) {
        return cached.$1;
      }
    }

    // Try direct TransLink GTFS-RT
    try {
      final feedBytes = await _getFeed(forceRefresh: forceRefresh);
      if (feedBytes != null) {
        final stopRow = await DbService.lookupStop(stopCode);
        if (stopRow != null) {
          final stopId = stopRow['stop_id'] as String;
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

          // Parse full feed and filter to our stop
          final allArrivals = GtfsRtParser.parse(feedBytes);
          final relevant = allArrivals
              .where((a) => a.stopId == stopId && a.arrivalTimestamp > nowSec)
              .toList()
            ..sort((a, b) => a.arrivalTimestamp.compareTo(b.arrivalTimestamp));

          // Batch route-name lookup
          final routeIds = relevant.map((a) => a.routeId).where((r) => r.isNotEmpty).toSet().toList();
          final routeNames = await DbService.getRouteShortNames(routeIds);

          final liveTripIds = <String>{};
          final merged = <Arrival>[];

          for (final a in relevant) {
            final routeName = routeNames[a.routeId] ?? a.routeId;
            final minutesAway = (a.arrivalTimestamp - nowSec) ~/ 60;
            final dt = DateTime.fromMillisecondsSinceEpoch(a.arrivalTimestamp * 1000);
            final arrivalTime =
                '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
            merged.add(Arrival(
              route:        routeName,
              destination:  '',
              minutesAway:  minutesAway < 0 ? 0 : minutesAway,
              arrivalTime:  arrivalTime,
              source:       a.hasGps ? 'live' : 'approx',
              delaySeconds: a.delaySeconds,
            ));
            liveTripIds.add(a.tripId);
          }

          // Fill gaps with static schedule for trips not tracked in the live feed
          final staticRows = await DbService.getScheduledArrivals(stopCode);
          for (final r in staticRows) {
            final tripId = r['trip_id'] as String? ?? '';
            if (liveTripIds.contains(tripId)) continue;
            merged.add(Arrival(
              route:        r['route'] as String? ?? '',
              destination:  r['headsign'] as String? ?? '',
              minutesAway:  r['minutes_away'] as int? ?? 0,
              arrivalTime:  r['arrival_time'] as String? ?? '',
              source:       'scheduled',
              delaySeconds: 0,
            ));
          }

          merged.sort((a, b) => a.minutesAway.compareTo(b.minutesAway));
          final result = ArrivalResult(merged.take(_maxArrivals).toList(), ArrivalMode.live);
          _cache[stopCode] = (result, DateTime.now());
          return result;
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[TranslinkService] GTFS-RT failed: $e');
    }

    // Fall back to on-device GTFS static schedule
    final rows = await DbService.getScheduledArrivals(stopCode);
    final arrivals = rows.take(_maxArrivals).map((r) => Arrival(
      route:        r['route'] as String? ?? '',
      destination:  r['headsign'] as String? ?? '',
      minutesAway:  r['minutes_away'] as int? ?? 0,
      arrivalTime:  r['arrival_time'] as String? ?? '',
      source:       'scheduled',
      delaySeconds: 0,
    )).toList();
    final result = ArrivalResult(arrivals, ArrivalMode.scheduled);
    _cache[stopCode] = (result, DateTime.now());
    return result;
  }

  static Future<Uint8List?> _getFeed({bool forceRefresh = false}) async {
    if (!forceRefresh && _feedBytes != null && _feedFetchedAt != null &&
        DateTime.now().difference(_feedFetchedAt!) < _feedTtl) {
      return _feedBytes;
    }
    final apiKey = await ApiKeyService.getKey();
    if (apiKey == null) return null;
    final url = Uri.parse('${Config.transitRtUrl}?apikey=$apiKey');
    final resp = await http.get(url).timeout(const Duration(seconds: 8));
    if (resp.statusCode == 200) {
      _feedBytes = resp.bodyBytes;
      _feedFetchedAt = DateTime.now();
      return _feedBytes;
    }
    return null;
  }
}
