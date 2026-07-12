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

  static Future<void> removeFavourite(String stopCode) async {
    final db = await database;
    await db.delete('favourites',
        where: 'stop_code = ?', whereArgs: [stopCode]);
  }

  /// Diagnostic for the Settings screen — exposes the day-matching internals
  /// so a calendar-filter bug can be seen directly instead of guessed at.
  static Future<String> diagnoseSchedule(String stopCode) async {
    final db = await database;
    final stopRows = await db.query('stops',
        where: 'stop_code = ?', whereArgs: [stopCode], limit: 1);
    if (stopRows.isEmpty) return 'Stop $stopCode not found in local DB';
    final stopId = stopRows.first['stop_id'] as String;

    final now = DateTime.now();
    final todayStr = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    const dayNames = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday'];
    final dowCol = dayNames[now.weekday - 1];
    final nowTime = '${now.hour.toString().padLeft(2, '0')}'
        ':${now.minute.toString().padLeft(2, '0')}'
        ':${now.second.toString().padLeft(2, '0')}';

    const padExpr = "(CASE WHEN length(st.departure_time) = 7 THEN '0' || st.departure_time ELSE st.departure_time END)";

    final calMatch = await db.rawQuery('''
      SELECT COUNT(*) AS n FROM calendar
      WHERE $dowCol = 1 AND start_date <= ? AND end_date >= ?
    ''', [todayStr, todayStr]);
    final calTotal = await db.rawQuery('SELECT COUNT(*) AS n FROM calendar');
    final calDateRange = await db.rawQuery('SELECT MIN(start_date) AS lo, MAX(end_date) AS hi FROM calendar');
    final filteredRows = await db.rawQuery('''
      SELECT COUNT(*) AS n FROM stop_times st JOIN trips t ON st.trip_id = t.trip_id
      WHERE st.stop_id = ? AND $padExpr >= ?
        AND t.service_id IN (SELECT service_id FROM calendar WHERE $dowCol = 1 AND start_date <= ? AND end_date >= ?)
    ''', [stopId, nowTime, todayStr, todayStr]);
    final unfilteredRows = await db.rawQuery('''
      SELECT st.departure_time AS dep, t.service_id AS sid FROM stop_times st JOIN trips t ON st.trip_id = t.trip_id
      WHERE st.stop_id = ? AND $padExpr >= ?
      ORDER BY $padExpr LIMIT 5
    ''', [stopId, nowTime]);

    return 'day=$dowCol todayStr=$todayStr nowTime=$nowTime\n'
        'calendar rows total=${calTotal.first['n']} matching today=${calMatch.first['n']}\n'
        'calendar date range: ${calDateRange.first['lo']} to ${calDateRange.first['hi']}\n'
        'stop_times matched via calendar filter=${filteredRows.first['n']}\n'
        'next 5 unfiltered (dep,service_id)=${unfilteredRows.map((r) => '${r['dep']}/${r['sid']}').join(', ')}';
  }

  static Future<List<Map<String, dynamic>>> getScheduledArrivals(String stopCode) async {
    final db = await database;

    final stopRows = await db.query('stops',
        where: 'stop_code = ?', whereArgs: [stopCode], limit: 1);
    if (stopRows.isEmpty) return [];
    final stopId = stopRows.first['stop_id'] as String;

    final now = DateTime.now();
    final todayStr = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    const dayNames = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday'];
    final dowCol = dayNames[now.weekday - 1];
    final nowTime = '${now.hour.toString().padLeft(2, '0')}'
        ':${now.minute.toString().padLeft(2, '0')}'
        ':${now.second.toString().padLeft(2, '0')}';

    // GTFS often stores single-digit-hour departure times unpadded ("7:15:00"
    // instead of "07:15:00"). Plain string comparison/ordering sorts those
    // after any "1X:" or "2X:" time, hiding genuinely-due early buses. Pad
    // before comparing/ordering so string sort matches actual time order.
    const padExpr = "(CASE WHEN length(st.departure_time) = 7 THEN '0' || st.departure_time ELSE st.departure_time END)";

    // Single query — calendar logic fully in SQL to avoid intermediate state bugs
    List<Map<String, dynamic>> rows = await db.rawQuery('''
      SELECT st.trip_id, st.departure_time, r.route_short_name, t.headsign
      FROM stop_times st
      JOIN trips t ON st.trip_id = t.trip_id
      JOIN routes r ON t.route_id = r.route_id
      WHERE st.stop_id = ?
        AND $padExpr >= ?
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
      ORDER BY $padExpr
      LIMIT 30
    ''', [stopId, nowTime, todayStr, todayStr, todayStr, todayStr]);

    // Fallback: if calendar filter found nothing but stop has stop_times data,
    // the service_id pattern is likely non-standard — return unfiltered by service
    if (rows.isEmpty) {
      final check = await db.rawQuery(
          'SELECT 1 FROM stop_times WHERE stop_id = ? LIMIT 1', [stopId]);
      if (check.isNotEmpty) {
        rows = await db.rawQuery('''
          SELECT st.trip_id, st.departure_time, r.route_short_name, t.headsign
          FROM stop_times st
          JOIN trips t ON st.trip_id = t.trip_id
          JOIN routes r ON t.route_id = r.route_id
          WHERE st.stop_id = ? AND $padExpr >= ?
          ORDER BY $padExpr
          LIMIT 30
        ''', [stopId, nowTime]);
      }
    }

    final result = <Map<String, dynamic>>[];
    for (final r in rows) {
      final rawTime = (r['departure_time'] as String).trim();
      final parts = rawTime.split(':');
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
      final displayH = h % 24;
      final displayTime =
          '${displayH.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
      final depSecs = h * 3600 + m * 60;
      final nowSecs = now.hour * 3600 + now.minute * 60 + now.second;
      final minutesAway = (depSecs - nowSecs) ~/ 60;
      if (minutesAway < 0) continue;
      result.add({
        'trip_id':      r['trip_id'] ?? '',
        'route':        r['route_short_name'] ?? '',
        'headsign':     r['headsign'] ?? '',
        'arrival_time': displayTime,
        'minutes_away': minutesAway,
      });
    }
    return result;
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
