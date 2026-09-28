import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'db_service.dart';

class FeedInfo {
  final String url;
  final String date; // YYYY-MM-DD
  const FeedInfo(this.url, this.date);
}

/// Why a schedule download is or is not on offer.
enum UpdateStatus {
  /// A newer feed than the stored one exists.
  available,

  /// A feed was found and it is the one already imported.
  current,

  /// No feed could be found at all — offline, or TransLink moved the files.
  noFeed,
}

/// The outcome of [GtfsService.checkForUpdate].
///
/// [feed] is non-null for both [UpdateStatus.available] and
/// [UpdateStatus.current], so a caller can name the date it found either way.
class UpdateCheck {
  final UpdateStatus status;
  final FeedInfo? feed;
  const UpdateCheck(this.status, this.feed);
}

class GtfsService {
  static String _urlFor(DateTime d) {
    final s =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return 'https://gtfs-static.translink.ca/gtfs/History/$s/google_transit.zip';
  }

  static String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// How far back a plain day-by-day scan looks. A weekly feed is always
  /// inside this window, so the scan finds the newest one without needing to
  /// know which day of the week it lands on.
  static const int _dailyScanDays = 14;

  /// Only used once the daily scan has found nothing, which means nothing has
  /// published in two weeks. Measured, not assumed — see [_candidates].
  static const int _observedPublishWeekday = DateTime.friday;

  /// Three, not two. The long-stop counts back from the most recent Friday,
  /// and Friday is a day later in the week than the Thursday this replaced —
  /// so matching weeks would have quietly reduced how far back the app can
  /// still find a feed. Three weeks makes the reach 28-34 days, strictly
  /// better than before, at the cost of one extra request in a case that only
  /// arises when nothing has published in a fortnight.
  static const int _longStopWeeks = 3;

  /// Feed dates to try, newest first.
  ///
  /// This used to try four recent **Thursdays** before anything else, on the
  /// belief that TransLink publishes weekly on a Thursday. Measured against the
  /// live server on 2026-09-28, that belief is simply false, and had been
  /// costing four guaranteed 404s on every single check:
  ///
  ///     2026-08-28 Fri 200      2026-09-10 Thu 404
  ///     2026-09-04 Fri 200      2026-09-17 Thu 404
  ///     2026-09-11 Fri 200      2026-09-24 Thu 404
  ///     2026-09-18 Fri 200
  ///     2026-09-25 Fri 200
  ///
  /// The daily fallback had been carrying the feature the whole time, which is
  /// exactly why nothing ever looked broken. The fix is deliberately NOT to
  /// swap one hard-coded weekday for another: a newest-first daily scan cannot
  /// be wrong about the publication day at all, and a weekly feed is always
  /// within a week of dates. The weekday survives only as a long-stop for the
  /// abnormal case where nothing has published in a fortnight — where being
  /// wrong costs two requests and no correctness.
  ///
  /// Dates are built with the `DateTime(y, m, d - n)` constructor rather than
  /// `subtract(Duration(days: n))`. Duration arithmetic is absolute, so a
  /// subtraction spanning a DST change lands at 23:00 on the previous day and
  /// [_dateStr] then names the wrong date. The constructor normalises calendar
  /// fields and is unaffected — it also rolls back over month and year ends.
  static Iterable<DateTime> _candidates() sync* {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final seen = <String>{};

    for (int i = 0; i < _dailyScanDays; i++) {
      final date = DateTime(today.year, today.month, today.day - i);
      if (seen.add(_dateStr(date))) yield date;
    }

    final daysSincePublishDay = (today.weekday - _observedPublishWeekday) % 7;
    for (int w = 2; w < 2 + _longStopWeeks; w++) {
      final date = DateTime(
          today.year, today.month, today.day - (daysSincePublishDay + w * 7));
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

  /// The single answer to "is there a newer schedule?" (#321 slice B2).
  ///
  /// This used to return a nullable FeedInfo, which forced every caller to
  /// decide what null meant — and they disagreed. Settings re-derived
  /// "already current" itself by comparing `_gtfsDate == feed.date`, while the
  /// home path did not check at all and would happily re-download a feed it
  /// already had. Two entrances, two answers, one of them wrong. Now there is
  /// one function, it distinguishes the three real outcomes, and nobody
  /// re-derives anything.
  static Future<UpdateCheck> checkForUpdate() async {
    final latest = await findLatestFeed();
    if (latest == null) return const UpdateCheck(UpdateStatus.noFeed, null);
    final stored = await DbService.getGtfsDate();
    if (stored == latest.date) return UpdateCheck(UpdateStatus.current, latest);
    return UpdateCheck(UpdateStatus.available, latest);
  }

  /// Guards against two imports running at once.
  ///
  /// Both entrances — the home banner and Settings — call straight through to
  /// the import with nothing stopping them overlapping. Found on device
  /// 2026-08-30: a Settings refresh was still running when the banner refresh
  /// was tapped. The second beginImport drops the first one's staging tables out
  /// from under it, and whichever reaches the swap first can commit a feed that
  /// is missing whatever the other had already written. What makes that worse
  /// than a crash is that the result is structurally clean and passes every
  /// check — it is simply short of rows, and nothing says so.
  static bool _importing = false;

  static bool get importInProgress => _importing;

  static Future<void> downloadAndBuild({
    required FeedInfo feed,
    required void Function(String) onStatus,
  }) async {
    if (_importing) throw const ImportInProgressException();
    _importing = true;
    try {
      await _downloadAndBuild(feed: feed, onStatus: onStatus);
    } finally {
      // Released even when the import threw, so one failure cannot lock the app
      // out of ever updating again until it is restarted.
      _importing = false;
    }
  }

  static Future<void> _downloadAndBuild({
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

    // Everything below writes to staging only. The live schedule is not touched
    // until commitImport, so a malformed file, a killed process, or a user
    // walking out of Wi-Fi range leaves the last working schedule exactly as it
    // was — which is what slice B requires and what the old write-in-place
    // import could not offer.
    await DbService.beginImport();
    try {
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
        final stLines =
            const LineSplitter().convert(utf8.decode(stEntry.content));
        if (stLines.isNotEmpty) {
          final h = stLines[0].split(',').map((e) => e.trim()).toList();
          final tIdx = h.indexOf('trip_id');
          final siIdx = h.indexOf('stop_id');
          final depIdx = h.indexOf('departure_time');
          final seqIdx = h.indexOf('stop_sequence');

          const chunkSize = 5000;
          var chunk = <Map<String, dynamic>>[];
          final total = stLines.length - 1;
          var saved = 0;

          for (final line in stLines.skip(1)) {
            if (line.trim().isEmpty) continue;
            final cols = _parseCsv(line);
            if (tIdx < 0 || cols.length <= tIdx) continue;
            chunk.add({
              'trip_id': cols[tIdx].trim(),
              'stop_id':
                  siIdx >= 0 && cols.length > siIdx ? cols[siIdx].trim() : '',
              'departure_time':
                  depIdx >= 0 && cols.length > depIdx ? cols[depIdx].trim() : '',
              'stop_sequence': seqIdx >= 0 && cols.length > seqIdx
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

      // Checked before the swap, while there is still something to fall back to.
      onStatus('Checking schedule data...');
      final report = await DbService.validateImport();

      onStatus('Applying update...');
      await DbService.commitImport(feed.date);

      // Reported on the way out rather than only on failure, so a healthy import
      // says what it actually loaded.
      onStatus('Schedule updated — $report');
    } catch (_) {
      try {
        await DbService.abortImport();
      } catch (_) {
        // Staging is inert: leaving it behind costs disk, not correctness, and
        // the next import drops it. Never let cleanup replace the real error.
      }
      rethrow;
    }
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

/// Thrown when a schedule update is requested while one is already running.
class ImportInProgressException implements Exception {
  const ImportInProgressException();

  @override
  String toString() => 'A schedule update is already running.';
}
