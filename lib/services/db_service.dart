import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DbService {
  static Database? _db;

  static Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'next_bus.db');
    return openDatabase(
      path,
      version: 4,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE stops (
            stop_code TEXT PRIMARY KEY,
            stop_id   TEXT NOT NULL,
            stop_name TEXT NOT NULL DEFAULT ""
          )
        ''');
        await db.execute('''
          CREATE TABLE metadata (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE favourites (
            stop_code TEXT PRIMARY KEY,
            stop_name TEXT NOT NULL,
            added_at  TEXT DEFAULT (datetime('now'))
          )
        ''');
        await db.execute('''
          CREATE TABLE routes (
            route_id         TEXT PRIMARY KEY,
            route_short_name TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE trips (
            trip_id    TEXT PRIMARY KEY,
            route_id   TEXT NOT NULL,
            service_id TEXT NOT NULL,
            headsign   TEXT DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE calendar (
            service_id TEXT PRIMARY KEY,
            monday     INTEGER DEFAULT 0,
            tuesday    INTEGER DEFAULT 0,
            wednesday  INTEGER DEFAULT 0,
            thursday   INTEGER DEFAULT 0,
            friday     INTEGER DEFAULT 0,
            saturday   INTEGER DEFAULT 0,
            sunday     INTEGER DEFAULT 0,
            start_date TEXT NOT NULL DEFAULT '',
            end_date   TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE calendar_dates (
            service_id     TEXT NOT NULL,
            date           TEXT NOT NULL,
            exception_type INTEGER NOT NULL,
            PRIMARY KEY (service_id, date)
          )
        ''');
        await db.execute('''
          CREATE TABLE stop_times (
            trip_id        TEXT NOT NULL,
            stop_id        TEXT NOT NULL,
            departure_time TEXT NOT NULL,
            stop_sequence  INTEGER NOT NULL,
            PRIMARY KEY (trip_id, stop_sequence)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_stop_times_stop ON stop_times(stop_id, departure_time)',
        );
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS metadata (
              key   TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        }
        if (oldV < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS favourites (
              stop_code TEXT PRIMARY KEY,
              stop_name TEXT NOT NULL,
              added_at  TEXT DEFAULT (datetime('now'))
            )
          ''');
        }
        if (oldV < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS routes (
              route_id         TEXT PRIMARY KEY,
              route_short_name TEXT NOT NULL DEFAULT ''
            )
          ''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS trips (
              trip_id    TEXT PRIMARY KEY,
              route_id   TEXT NOT NULL,
              service_id TEXT NOT NULL,
              headsign   TEXT DEFAULT ''
            )
          ''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS calendar (
              service_id TEXT PRIMARY KEY,
              monday     INTEGER DEFAULT 0,
              tuesday    INTEGER DEFAULT 0,
              wednesday  INTEGER DEFAULT 0,
              thursday   INTEGER DEFAULT 0,
              friday     INTEGER DEFAULT 0,
              saturday   INTEGER DEFAULT 0,
              sunday     INTEGER DEFAULT 0,
              start_date TEXT NOT NULL DEFAULT '',
              end_date   TEXT NOT NULL DEFAULT ''
            )
          ''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS calendar_dates (
              service_id     TEXT NOT NULL,
              date           TEXT NOT NULL,
              exception_type INTEGER NOT NULL,
              PRIMARY KEY (service_id, date)
            )
          ''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS stop_times (
              trip_id        TEXT NOT NULL,
              stop_id        TEXT NOT NULL,
              departure_time TEXT NOT NULL,
              stop_sequence  INTEGER NOT NULL,
              PRIMARY KEY (trip_id, stop_sequence)
            )
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_stop_times_stop ON stop_times(stop_id, departure_time)',
          );
        }
      },
    );
  }

  static Future<void> insertStops(List<Map<String, String>> stops) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.execute('DELETE FROM stops');
      final batch = txn.batch();
      for (final s in stops) {
        batch.insert('stops', s, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<List<Map<String, dynamic>>> searchStops(String query) async {
    final db = await database;
    return db.query(
      'stops',
      where: 'stop_code LIKE ?',
      whereArgs: ['%$query%'],
      orderBy: 'stop_code',
      limit: 20,
    );
  }

  static Future<Map<String, dynamic>?> lookupStop(String stopCode) async {
    final db = await database;
    final rows = await db.query(
      'stops',
      where: 'stop_code = ?',
      whereArgs: [stopCode],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<bool> hasStops() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM stops'),
    );
    return (count ?? 0) > 0;
  }

  static Future<String?> getGtfsDate() async {
    final db = await database;
    final rows = await db.query(
      'metadata',
      where: 'key = ?',
      whereArgs: ['gtfs_date'],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  static Future<List<Map<String, dynamic>>> getFavourites() async {
    final db = await database;
    return db.query('favourites', orderBy: 'added_at DESC');
  }

  static Future<bool> isFavourite(String stopCode) async {
    final db = await database;
    final rows = await db.query('favourites',
        where: 'stop_code = ?', whereArgs: [stopCode], limit: 1);
    return rows.isNotEmpty;
  }

  static Future<void> addFavourite(String stopCode, String stopName) async {
    final db = await database;
    await db.insert(
      'favourites',
      {'stop_code': stopCode, 'stop_name': stopName},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<int> removeFavourite(String stopCode) async {
    final db = await database;
    return db.delete('favourites',
        where: 'stop_code = ?', whereArgs: [stopCode]);
  }

  /// How far ahead a schedule lookup reports. GTFS keeps post-midnight trips in
  /// the *previous* service day as "24:xx"/"25:xx", so with no horizon a stop
  /// whose last bus has already gone will cheerfully answer with tomorrow's
  /// first bus and render it as "1470m" — arithmetically right, useless on
  /// screen. Six hours lets a genuine 3am gap read as "no upcoming buses" while
  /// still finding the first bus of the morning.
  static const Duration scheduleHorizon = Duration(hours: 6);

  /// How far either side of a planned time slice A looks when centring a
  /// lookup. Back far enough to find "the one just before" at an hourly stop;
  /// forward far enough to still offer options when the next few are sparse.
  static const Duration _planningLookback = Duration(hours: 3);
  static const Duration _planningLookahead = Duration(hours: 6);

  /// No real feed schedules a trip beyond this point in its service day. Past
  /// it, yesterday's service day cannot contribute anything and is skipped.
  static const int _maxServiceDaySecs = 30 * 3600; // 30:00:00

  static const List<String> _dayNames = [
    'monday','tuesday','wednesday','thursday','friday','saturday','sunday',
  ];

  // GTFS often stores single-digit-hour departure times unpadded ("7:15:00"
  // instead of "07:15:00"). Plain string comparison/ordering sorts those
  // after any "1X:" or "2X:" time, hiding genuinely-due early buses. Pad
  // before comparing/ordering so string sort matches actual time order.
  static const String _padExpr =
      "(CASE WHEN length(st.departure_time) = 7 THEN '0' || st.departure_time ELSE st.departure_time END)";

  /// Formats seconds-since-service-day-midnight as a GTFS time string. Hours
  /// are allowed past 23 — that is the entire point of the format.
  static String _gtfsTime(int secs) {
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    return '${h.toString().padLeft(2, '0')}'
        ':${m.toString().padLeft(2, '0')}'
        ':${s.toString().padLeft(2, '0')}';
  }

  static String _yyyymmdd(DateTime d) =>
      '${d.year}'
      '${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}';

  /// Departures at [stopId] belonging to a single service day.
  ///
  /// [serviceDay] is the day the *service* is scheduled under, which for
  /// post-midnight trips is yesterday, not the date on the clock. [offsetSecs]
  /// is how far that service day's midnight sits behind today's: 0 for today,
  /// 86400 for yesterday. The window is shifted by that offset rather than the
  /// trips being shifted, so every comparison stays in the strings GTFS ships.
  ///
  /// Appends onto [into] instead of returning, because two service days merge
  /// into one list and the caller sorts once at the end.
  static Future<void> _collectServiceDay({
    required Database db,
    required String stopId,
    required DateTime serviceDay,
    required int offsetSecs,
    required int windowFromSecs,
    required int windowToSecs,
    required int nowSecs,
    required bool includePast,
    required List<Map<String, dynamic>> into,
  }) async {
    // Clamped at zero so a *future* service day (negative offset) is read from
    // its own midnight — all of it is ahead of us — rather than from a negative
    // time that has no GTFS representation.
    final rawFrom = windowFromSecs + offsetSecs;
    final fromSecs = rawFrom < 0 ? 0 : rawFrom;
    final toSecs = windowToSecs + offsetSecs;
    // Nothing to ask for: the window has run past any plausible GTFS time
    // (yesterday's service day, late in the day) or has not reached this
    // service day at all yet (tomorrow's, for most of the day).
    if (fromSecs > _maxServiceDaySecs || toSecs < 0) return;

    final dateStr = _yyyymmdd(serviceDay);
    final dowCol = _dayNames[serviceDay.weekday - 1];

    // Calendar logic stays fully in SQL to avoid intermediate state bugs.
    // dowCol is interpolated from the fixed list above, never from input.
    final rows = await db.rawQuery('''
      SELECT st.trip_id, st.departure_time, r.route_short_name, t.headsign
      FROM stop_times st
      JOIN trips t ON st.trip_id = t.trip_id
      JOIN routes r ON t.route_id = r.route_id
      WHERE st.stop_id = ?
        AND $_padExpr >= ?
        AND $_padExpr <= ?
        AND (
          t.service_id IN (
            SELECT service_id FROM calendar
            WHERE $dowCol = 1 AND start_date <= ? AND end_date >= ?
          )
          OR t.service_id IN (
            SELECT service_id FROM calendar_dates
            WHERE date = ? AND exception_type = 1
          )
        )
        AND t.service_id NOT IN (
          SELECT service_id FROM calendar_dates
          WHERE date = ? AND exception_type = 2
        )
      ORDER BY $_padExpr
      LIMIT 30
    ''', [
      stopId,
      _gtfsTime(fromSecs),
      _gtfsTime(toSecs),
      dateStr, dateStr, dateStr, dateStr,
    ]);

    for (final r in rows) {
      final rawTime = (r['departure_time'] as String).trim();
      final parts = rawTime.split(':');
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
      final s = int.tryParse(parts.length > 2 ? parts[2] : '0') ?? 0;

      // "24:30" and "00:30" are the same clock face; which service day the trip
      // belongs to is what tells them apart, and offsetSecs already carries it.
      final displayH = h % 24;
      final displayTime =
          '${displayH.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

      final depSecs = h * 3600 + m * 60 + s;
      final minutesAway = (depSecs - offsetSecs - nowSecs) ~/ 60;
      if (!includePast && minutesAway < 0) continue;

      into.add({
        'trip_id':      r['trip_id'] ?? '',
        'route':        r['route_short_name'] ?? '',
        'headsign':     r['headsign'] ?? '',
        'arrival_time': displayTime,
        'minutes_away': minutesAway,
        // Absolute position in *today's* frame. Two service days can both offer
        // an "00:30", so the display string is not a safe key for grouping or
        // sorting departures across them. This is.
        'departure_secs': depSecs - offsetSecs,
      });
    }
  }

  /// Every departure at [stopId] inside [windowFromSecs]..[windowToSecs]
  /// (seconds since midnight in *today's* frame), merged across
  /// all three service days that can contribute one: yesterday's (its
  /// post-midnight trips, stored as 24:xx), today's, and tomorrow's — which is
  /// reachable whenever the window crosses midnight, e.g. a 23:50 lookup with a
  /// six-hour horizon needs tomorrow's 05:14. Sorted by time.
  static Future<List<Map<String, dynamic>>> _departuresWithin({
    required Database db,
    required String stopId,
    required DateTime now,
    required int nowSecs,
    required int windowFromSecs,
    required int windowToSecs,
    bool includePast = false,
  }) async {
    final result = <Map<String, dynamic>>[];

    for (final dayDelta in [-1, 0, 1]) {
      await _collectServiceDay(
        db: db,
        stopId: stopId,
        // Built from components rather than today.add(Duration(days: n)):
        // adding a Duration across a daylight-saving boundary lands on 23:00 or
        // 01:00 of the neighbouring day, which would read the wrong weekday
        // column out of `calendar`. Dart normalises out-of-range day values.
        serviceDay: DateTime(now.year, now.month, now.day + dayDelta),
        // Exactly one nominal day per step, and deliberately not a measured
        // difference — that returns 23 or 25 hours across a DST change. GTFS
        // service days are 24 hours wide in the strings the feed ships; the
        // publisher absorbs the clock change, not us.
        offsetSecs: -dayDelta * 86400,
        windowFromSecs: windowFromSecs,
        windowToSecs: windowToSecs,
        nowSecs: nowSecs,
        includePast: includePast,
        into: result,
      );
    }

    // TranslinkService takes the first N of this list as "the next N", so a
    // merge across service days has to be re-sorted, not just concatenated.
    result.sort((a, b) =>
        (a['departure_secs'] as int).compareTo(b['departure_secs'] as int));
    return result;
  }

  static Future<String?> _stopIdFor(Database db, String stopCode) async {
    final rows = await db.query('stops',
        where: 'stop_code = ?', whereArgs: [stopCode], limit: 1);
    return rows.isEmpty ? null : rows.first['stop_id'] as String;
  }

  /// Upcoming scheduled departures at [stopCode] within [scheduleHorizon],
  /// soonest first.
  ///
  /// Deliberately has no "calendar matched nothing, so return everything"
  /// fallback. That path used to drop the service filter entirely and hand back
  /// trips from any day of the week — Sunday buses on a Tuesday, indistinguish-
  /// able from real ones. Empty is the honest answer; [getNextDeparture] is
  /// what turns that emptiness into something a user can read.
  static Future<List<Map<String, dynamic>>> getScheduledArrivals(String stopCode) async {
    final db = await database;
    final stopId = await _stopIdFor(db, stopCode);
    if (stopId == null) return [];

    final now = DateTime.now();
    final nowSecs = now.hour * 3600 + now.minute * 60 + now.second;
    final result = await _departuresWithin(
      db: db,
      stopId: stopId,
      now: now,
      nowSecs: nowSecs,
      windowFromSecs: nowSecs,
      windowToSecs: nowSecs + scheduleHorizon.inSeconds,
    );
    return result.length > 30 ? result.sublist(0, 30) : result;
  }

  /// The next departure at [stopCode] looking further ahead than
  /// [scheduleHorizon], or null if there is none within [within].
  ///
  /// Only worth calling when [getScheduledArrivals] came back empty. It is what
  /// lets the empty state say "next bus 05:14" instead of "no upcoming buses" —
  /// and that distinction carries real information, because a stop that can
  /// name its next departure has proved its schedule data is present and valid.
  /// Silence cannot tell the user whether the buses stopped or the data did.
  static Future<Map<String, dynamic>?> getNextDeparture(
    String stopCode, {
    Duration within = const Duration(hours: 24),
  }) async {
    final db = await database;
    final stopId = await _stopIdFor(db, stopCode);
    if (stopId == null) return null;

    final now = DateTime.now();
    final nowSecs = now.hour * 3600 + now.minute * 60 + now.second;
    final result = await _departuresWithin(
      db: db,
      stopId: stopId,
      now: now,
      nowSecs: nowSecs,
      windowFromSecs: nowSecs,
      windowToSecs: nowSecs + within.inSeconds,
    );
    return result.isEmpty ? null : result.first;
  }

  /// Departures at [stopCode] centred on [targetSecs] — seconds since midnight
  /// in today's frame — for slice A's Time mode.
  ///
  /// Returns every departure at the last [before] distinct departure times at or
  /// before the target, and the next [after] distinct times following it.
  ///
  /// The unit is a **departure time, not a trip**. Several routes can leave one
  /// stop at 14:00, and the question being asked is "when do I need to be at the
  /// stop" — a question about times. So a chosen time brings all its routes with
  /// it, and three chosen times can be more than three rows.
  ///
  /// Past departures are included and carry a negative `minutes_away`. That is
  /// deliberate: planning at 13:55 for 14:00, the 13:52 bus is part of the
  /// answer. The caller must render it as uncatchable — see [Arrival.isPast].
  static Future<List<Map<String, dynamic>>> getArrivalsAround(
    String stopCode,
    int targetSecs, {
    int before = 1,
    int after = 2,
  }) async {
    final db = await database;
    final stopId = await _stopIdFor(db, stopCode);
    if (stopId == null) return [];

    final now = DateTime.now();
    final nowSecs = now.hour * 3600 + now.minute * 60 + now.second;

    final rows = await _departuresWithin(
      db: db,
      stopId: stopId,
      now: now,
      nowSecs: nowSecs,
      windowFromSecs: targetSecs - _planningLookback.inSeconds,
      windowToSecs: targetSecs + _planningLookahead.inSeconds,
      includePast: true,
    );
    if (rows.isEmpty) return [];

    // rows is already sorted by departure_secs.
    final times = <int>[];
    for (final r in rows) {
      final t = r['departure_secs'] as int;
      if (times.isEmpty || times.last != t) times.add(t);
    }

    final pivot = times.indexWhere((t) => t > targetSecs);
    // Every departure in the window is at or before the target — the target sits
    // after the last bus of the night. Fall back to the latest times available
    // rather than returning nothing.
    final firstAfter = pivot < 0 ? times.length : pivot;

    final lo = (firstAfter - before) < 0 ? 0 : firstAfter - before;
    final hi = (firstAfter + after) > times.length ? times.length : firstAfter + after;
    final chosen = times.sublist(lo, hi).toSet();

    return rows
        .where((r) => chosen.contains(r['departure_secs'] as int))
        .toList();
  }

  static Future<Map<String, String>> getRouteShortNames(List<String> routeIds) async {
    if (routeIds.isEmpty) return {};
    final db = await database;
    final placeholders = List.filled(routeIds.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT route_id, route_short_name FROM routes WHERE route_id IN ($placeholders)',
      routeIds,
    );
    return {
      for (final r in rows)
        r['route_id'] as String: r['route_short_name'] as String? ?? '',
    };
  }

  static Future<void> insertRoutes(List<Map<String, String>> routes) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.execute('DELETE FROM routes');
      final batch = txn.batch();
      for (final r in routes) {
        batch.insert('routes', r, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<void> insertTrips(List<Map<String, String>> trips) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.execute('DELETE FROM trips');
      final batch = txn.batch();
      for (final t in trips) {
        batch.insert('trips', t, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<void> insertCalendar(
    List<Map<String, dynamic>> calendar,
    List<Map<String, dynamic>> calendarDates,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.execute('DELETE FROM calendar');
      await txn.execute('DELETE FROM calendar_dates');
      final batch = txn.batch();
      for (final r in calendar) {
        batch.insert('calendar', r, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in calendarDates) {
        batch.insert('calendar_dates', r, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<void> clearStopTimes() async {
    final db = await database;
    await db.execute('DELETE FROM stop_times');
  }

  static Future<void> insertStopTimesBatch(List<Map<String, dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert('stop_times', r, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<void> updateFavouriteName(String stopCode, String newName) async {
    final db = await database;
    await db.update(
      'favourites',
      {'stop_name': newName},
      where: 'stop_code = ?',
      whereArgs: [stopCode],
    );
  }

  static Future<void> setGtfsDate(String date) async {
    final db = await database;
    await db.insert(
      'metadata',
      {'key': 'gtfs_date', 'value': date},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
