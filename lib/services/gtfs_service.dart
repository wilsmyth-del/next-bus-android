import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'db_service.dart';

class FeedInfo {
  final String url;
  final String date; // YYYY-MM-DD
  const FeedInfo(this.url, this.date);
}

class GtfsService {
  static String _urlFor(DateTime d) {
    final s =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return 'https://gtfs-static.translink.ca/gtfs/History/$s/google_transit.zip';
  }

  static String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // Mirror server-side logic: recent Thursdays first, then daily fallback
  static Iterable<DateTime> _candidates() sync* {
    final today = DateTime.now();
    final daysSinceThursday = (today.weekday - 4) % 7;
    final seen = <String>{};

    for (int i = 0; i < 4; i++) {
      final d = today.subtract(Duration(days: daysSinceThursday + i * 7));
      final date = DateTime(d.year, d.month, d.day);
      if (seen.add(_dateStr(date))) yield date;
    }
    for (int i = 0; i < 14; i++) {
      final d = today.subtract(Duration(days: i));
      final date = DateTime(d.year, d.month, d.day);
      if (seen.add(_dateStr(date))) yield date;
    }
  }

  static Future<FeedInfo?> findLatestFeed() async {
    for (final d in _candidates()) {
      final url = _urlFor(d);
      try {
        final resp = await http
            .head(Uri.parse(url))
            .timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) {
          return FeedInfo(url, _dateStr(d));
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  // Returns non-null FeedInfo if an update is available, null if already current
  static Future<FeedInfo?> checkForUpdate() async {
    final latest = await findLatestFeed();
    if (latest == null) return null;
    final stored = await DbService.getGtfsDate();
    if (stored == latest.date) return null;
    return latest;
  }

  static Future<void> downloadAndBuild({
    required FeedInfo feed,
    required void Function(String) onStatus,
  }) async {
    onStatus('Downloading transit data (~15 MB)...');
    final resp = await http
        .get(Uri.parse(feed.url))
        .timeout(const Duration(seconds: 120));
    if (resp.statusCode != 200) {
      throw Exception('Download failed: ${resp.statusCode}');
    }

    final archive = ZipDecoder().decodeBytes(resp.bodyBytes);

    // --- stops.txt ---
    onStatus('Parsing stops...');
    final stopsEntry = archive.findFile('stops.txt');
    if (stopsEntry == null) throw Exception('stops.txt missing from zip');
    final stopsLines = const LineSplitter().convert(utf8.decode(stopsEntry.content));
    if (stopsLines.isEmpty) throw Exception('stops.txt is empty');
    final sHeaders = stopsLines[0].split(',').map((h) => h.trim()).toList();
    final codeIdx = sHeaders.indexOf('stop_code');
    final idIdx   = sHeaders.indexOf('stop_id');
    final nameIdx = sHeaders.indexOf('stop_name');
    if (codeIdx < 0 || idIdx < 0) throw Exception('Unexpected stops.txt format');
    final stops = <Map<String, String>>[];
    for (final line in stopsLines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final cols = _parseCsv(line);
      if (cols.length <= codeIdx || cols.length <= idIdx) continue;
      final code = cols[codeIdx].trim();
      final id   = cols[idIdx].trim();
      if (code.isEmpty || id.isEmpty) continue;
      stops.add({
        'stop_code': code,
        'stop_id':   id,
        'stop_name': nameIdx >= 0 && cols.length > nameIdx ? cols[nameIdx].trim() : '',
      });
    }

    // --- routes.txt ---
    onStatus('Parsing routes...');
    final routes = <Map<String, String>>[];
    final routesEntry = archive.findFile('routes.txt');
    if (routesEntry != null) {
      final lines = const LineSplitter().convert(utf8.decode(routesEntry.content));
      if (lines.isNotEmpty) {
        final h = lines[0].split(',').map((e) => e.trim()).toList();
        final rIdIdx    = h.indexOf('route_id');
        final rShortIdx = h.indexOf('route_short_name');
        for (final line in lines.skip(1)) {
          if (line.trim().isEmpty) continue;
          final cols = _parseCsv(line);
          if (rIdIdx < 0 || cols.length <= rIdIdx) continue;
          routes.add({
            'route_id':         cols[rIdIdx].trim(),
            'route_short_name': rShortIdx >= 0 && cols.length > rShortIdx
                ? cols[rShortIdx].trim()
                : '',
          });
        }
      }
    }

    // --- trips.txt ---
    onStatus('Parsing trips...');
    final trips = <Map<String, String>>[];
    final tripsEntry = archive.findFile('trips.txt');
    if (tripsEntry != null) {
      final lines = const LineSplitter().convert(utf8.decode(tripsEntry.content));
      if (lines.isNotEmpty) {
        final h = lines[0].split(',').map((e) => e.trim()).toList();
        final tIdIdx    = h.indexOf('trip_id');
        final tRouteIdx = h.indexOf('route_id');
        final tSvcIdx   = h.indexOf('service_id');
        final tHeadIdx  = h.indexOf('trip_headsign');
        for (final line in lines.skip(1)) {
          if (line.trim().isEmpty) continue;
          final cols = _parseCsv(line);
          if (tIdIdx < 0 || cols.length <= tIdIdx) continue;
          trips.add({
            'trip_id':    cols[tIdIdx].trim(),
            'route_id':   tRouteIdx >= 0 && cols.length > tRouteIdx ? cols[tRouteIdx].trim() : '',
            'service_id': tSvcIdx >= 0 && cols.length > tSvcIdx ? cols[tSvcIdx].trim() : '',
            'headsign':   tHeadIdx >= 0 && cols.length > tHeadIdx ? cols[tHeadIdx].trim() : '',
          });
        }
      }
    }

    // --- calendar.txt ---
    onStatus('Parsing calendar...');
    final calendarRows = <Map<String, dynamic>>[];
    final calEntry = archive.findFile('calendar.txt');
    if (calEntry != null) {
      final lines = const LineSplitter().convert(utf8.decode(calEntry.content));
      if (lines.isNotEmpty) {
        final h = lines[0].split(',').map((e) => e.trim()).toList();
        final dayNames = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday'];
        final dayIdxs  = dayNames.map((d) => h.indexOf(d)).toList();
        final svcIdx   = h.indexOf('service_id');
        final startIdx = h.indexOf('start_date');
        final endIdx   = h.indexOf('end_date');
        for (final line in lines.skip(1)) {
          if (line.trim().isEmpty) continue;
          final cols = _parseCsv(line);
          if (svcIdx < 0 || cols.length <= svcIdx) continue;
          final row = <String, dynamic>{
            'service_id': cols[svcIdx].trim(),
            'start_date': startIdx >= 0 && cols.length > startIdx ? cols[startIdx].trim() : '',
            'end_date':   endIdx >= 0 && cols.length > endIdx ? cols[endIdx].trim() : '',
          };
          for (int i = 0; i < dayNames.length; i++) {
            final idx = dayIdxs[i];
            row[dayNames[i]] = idx >= 0 && cols.length > idx
                ? (int.tryParse(cols[idx].trim()) ?? 0)
                : 0;
          }
          calendarRows.add(row);
        }
      }
    }

    // --- calendar_dates.txt ---
    final calDateRows = <Map<String, dynamic>>[];
    final calDatesEntry = archive.findFile('calendar_dates.txt');
    if (calDatesEntry != null) {
      final lines = const LineSplitter().convert(utf8.decode(calDatesEntry.content));
      if (lines.isNotEmpty) {
        final h    = lines[0].split(',').map((e) => e.trim()).toList();
        final sIdx = h.indexOf('service_id');
        final dIdx = h.indexOf('date');
        final eIdx = h.indexOf('exception_type');
        for (final line in lines.skip(1)) {
          if (line.trim().isEmpty) continue;
          final cols = _parseCsv(line);
          if (sIdx < 0 || cols.length <= sIdx) continue;
          calDateRows.add({
            'service_id':     cols[sIdx].trim(),
            'date':           dIdx >= 0 && cols.length > dIdx ? cols[dIdx].trim() : '',
            'exception_type': eIdx >= 0 && cols.length > eIdx
                ? (int.tryParse(cols[eIdx].trim()) ?? 0)
                : 0,
          });
        }
      }
    }

    // --- Save stops, routes, trips, calendar ---
    onStatus('Saving ${stops.length} stops...');
    await DbService.insertStops(stops);

    onStatus('Saving routes and trips...');
    await DbService.insertRoutes(routes);
    await DbService.insertTrips(trips);
    await DbService.insertCalendar(calendarRows, calDateRows);

    // --- stop_times.txt (largest file — chunked) ---
    onStatus('Parsing schedule times...');
    final stEntry = archive.findFile('stop_times.txt');
    if (stEntry != null) {
      final stLines = const LineSplitter().convert(utf8.decode(stEntry.content));
      if (stLines.isNotEmpty) {
        final h      = stLines[0].split(',').map((e) => e.trim()).toList();
        final tIdx   = h.indexOf('trip_id');
        final siIdx  = h.indexOf('stop_id');
        final depIdx = h.indexOf('departure_time');
        final seqIdx = h.indexOf('stop_sequence');

        await DbService.clearStopTimes();

        const chunkSize = 5000;
        var chunk = <Map<String, dynamic>>[];
        final total = stLines.length - 1;
        var saved = 0;

        for (final line in stLines.skip(1)) {
          if (line.trim().isEmpty) continue;
          final cols = _parseCsv(line);
          if (tIdx < 0 || cols.length <= tIdx) continue;
          chunk.add({
            'trip_id':        cols[tIdx].trim(),
            'stop_id':        siIdx >= 0 && cols.length > siIdx ? cols[siIdx].trim() : '',
            'departure_time': depIdx >= 0 && cols.length > depIdx ? cols[depIdx].trim() : '',
            'stop_sequence':  seqIdx >= 0 && cols.length > seqIdx
                ? (int.tryParse(cols[seqIdx].trim()) ?? 0)
                : 0,
          });
          if (chunk.length >= chunkSize) {
            await DbService.insertStopTimesBatch(chunk);
            saved += chunk.length;
            onStatus('Saving schedule... $saved / $total');
            chunk = [];
          }
        }
        if (chunk.isNotEmpty) {
          await DbService.insertStopTimesBatch(chunk);
        }
      }
    }

    await DbService.setGtfsDate(feed.date);
  }

  static List<String> _parseCsv(String line) {
    final result = <String>[];
    final buf = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        inQuotes = !inQuotes;
      } else if (c == ',' && !inQuotes) {
        result.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    result.add(buf.toString().replaceAll('\r', ''));
    return result;
  }
}
