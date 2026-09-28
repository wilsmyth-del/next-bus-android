import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DbService {
  static Database? _db;

  // ---------------------------------------------------------------------------
  // GTFS import — stage and swap
  //
  // The feed used to be written straight over the live tables: six independent
  // DELETE-then-insert transactions, plus one more per stop_times chunk. Between
  // the first commit and the last, the database held new stops against old trips
  // against half-written stop_times, and any interruption — process killed, app
  // backgrounded, network dropped — left it that way with nothing to roll back
  // to. Slice B requires that failure or cancellation preserves the last working
  // schedule. That was not merely unmet; it was the default outcome.
  //
  // Now every row lands in a parallel set of `_import` tables, the result is
  // checked before anything live is touched, and the swap is one transaction.
  // Two consequences worth naming:
  //   * the live tables stay queryable for the whole download, so a refresh no
  //     longer has any reason to block navigation;
  //   * the data can be validated before it is adopted, which is impossible once
  //     you have already deleted the alternative.
  // ---------------------------------------------------------------------------

  static const String _importSuffix = '_import';

  /// The tables the GTFS import replaces, in swap order. Deliberately excludes
  /// `favourites` and `metadata`: those are the user's, they are not in the
  /// feed, and they must never sit inside the blast radius of an import.
  static const List<String> _feedTables = [
    'stops',
    'routes',
    'trips',
    'calendar',
    'calendar_dates',
    'stop_times',
  ];

  /// One definition per feed table, used for the live schema *and* for the
  /// staging copies. Written once because a staging table whose shape has
  /// drifted from the live table is worse than no staging at all — it would swap
  /// in cleanly and be wrong.
  static const Map<String, String> _feedTableDdl = {
    'stops': '''
      stop_code TEXT PRIMARY KEY,
      stop_id   TEXT NOT NULL,
      stop_name TEXT NOT NULL DEFAULT ""
    ''',
    'routes': '''
      route_id         TEXT PRIMARY KEY,
      route_short_name TEXT NOT NULL DEFAULT ''
    ''',
    'trips': '''
      trip_id    TEXT PRIMARY KEY,
      route_id   TEXT NOT NULL,
      service_id TEXT NOT NULL,
      headsign   TEXT DEFAULT ''
    ''',
    'calendar': '''
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
    ''',
    'calendar_dates': '''
      service_id     TEXT NOT NULL,
      date           TEXT NOT NULL,
      exception_type INTEGER NOT NULL,
      PRIMARY KEY (service_id, date)
    ''',
    // No primary key, deliberately. `PRIMARY KEY (trip_id, stop_sequence)` built
    // a second index across all ~3.7M rows and nothing ever read either column —
    // every query goes through idx_stop_times_stop. It existed only so that
    // ConflictAlgorithm.replace could dedupe, which staging does not need
    // because it starts empty on every import. Dropping it removes an index of
    // that size and speeds the inserts up as well.
    //
    // Trade-off, stated rather than buried: a duplicate (trip_id, stop_sequence)
    // in the feed used to be silently replaced and would now render as a
    // duplicate departure. GTFS forbids it and TransLink's feed is generated, so
    // this trades a silent correction for a visible symptom — which is the right
    // way round, but it is a change.
    //
    // stop_sequence itself is kept: it costs an integer, it is the natural key
    // if dedupe or direction is ever needed, and removing it is a separate call.
    'stop_times': '''
      trip_id        TEXT NOT NULL,
      stop_id        TEXT NOT NULL,
      departure_time TEXT NOT NULL,
      stop_sequence  INTEGER NOT NULL
    ''',
  };

  static String _createFeedTable(String table, {String suffix = ''}) =>
      // Null-asserted deliberately: a table in _feedTables with no DDL is a
      // programming error, and failing loudly beats creating a table whose body
      // is the literal string "null".
      'CREATE TABLE IF NOT EXISTS $table$suffix (${_feedTableDdl[table]!})';

  /// Only ever built on the live table, after the swap. Staging is left
  /// unindexed on purpose: inserting a few million stop_times rows without
  /// maintaining an index is markedly faster, and building it once at the end
  /// also keeps it under its canonical name.
  static const String _stopTimesIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_stop_times_stop '
      'ON stop_times(stop_id, departure_time)';

  static Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final path = join(await getDatabasesPath(), _legacyDbName);
    return openDatabase(
      path,
      version: 5,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE metadata (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await db.execute('CREATE TABLE favourites ($_favouritesDdl)');
        // Built from the same definitions the import staging tables use, so a
        // staging table cannot drift from the table it is going to become.
        for (final t in _feedTables) {
          await db.execute(_createFeedTable(t));
        }
        await db.execute(_stopTimesIndexSql);
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
        if (oldV < 5) {
          // Slice F: favourites become hand-orderable. Seed sort_order from
          // the order the list has displayed until now (added_at DESC) so the
          // upgrade moves nothing on screen — the first drag is the first
          // visible change.
          await db.execute('ALTER TABLE favourites ADD COLUMN sort_order INTEGER');
          final existing = await db.query(
            'favourites',
            columns: ['stop_code'],
            orderBy: 'added_at DESC',
          );
          // Row by row in Dart rather than one UPDATE with a window function:
          // ROW_NUMBER() needs SQLite 3.25+, which not every supported Android
          // version ships, and this list is a handful of rows.
          for (var i = 0; i < existing.length; i++) {
            await db.update(
              'favourites',
              {'sort_order': i},
              where: 'stop_code = ?',
              whereArgs: [existing[i]['stop_code']],
            );
          }
        }
      },
    );
  }

  static Future<void> insertStops(List<Map<String, String>> stops) =>
      _insertStaging('stops', stops);

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

  static Future<String?> getGtfsDate() => _metadata('gtfs_date');

  /// When the last import actually succeeded, ISO-8601 local (#321 slice B2).
  ///
  /// Distinct from `gtfs_date`, which is the *feed's* date. The two answer
  /// different questions — "how old is the schedule I am using" versus "when did
  /// this phone last manage to update" — and a user staring at a stale feed date
  /// cannot tell a feed that has not moved from downloads that have been failing.
  static Future<String?> getGtfsUpdatedAt() => _metadata('gtfs_updated_at');

  static Future<String?> _metadata(String key) async {
    final db = await database;
    final rows = await db.query(
      'metadata',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }


  // ---------------------------------------------------------------------------
  // The profile store — slice G
  //
  // Favourites used to live in `next_bus.db`, alongside ~3.7M rows of
  // `stop_times`. Android's Auto Backup has a 25MB per-app quota and skips an
  // app **entirely** once it is over — so the schedule database was not merely
  // failing to back itself up, it was taking the user's own data down with it.
  // One fault, three faces: favourites lost on every reinstall, the TransLink
  // API key lost with them (it lives in SharedPreferences, which the same sweep
  // drops), and realtime silently dead ever after, because `_getFeed()` had no
  // key left to send.
  //
  // Backup rules select **files**, not tables. So the fix is a second, small
  // database holding nothing but the user's own rows: `res/xml/backup_rules.xml`
  // and `res/xml/data_extraction_rules.xml` name this file and the shared-prefs
  // domain and nothing else, and the schedule stops counting against the quota.
  //
  // The table definition below is deliberately byte-identical to the one in
  // [_open]. That is what lets every favourites query in this class run
  // unchanged against whichever database is currently authoritative — see
  // [_favDb], which is the whole safety story of the migration.
  // ---------------------------------------------------------------------------

  static const String _legacyDbName = 'next_bus.db';
  static const String _profileDbName = 'next_bus_profile.db';

  static const String _migratedKey = 'favourites_migrated_at';
  static const String _migratedCountKey = 'favourites_migrated_count';
  static const String _migrationErrorKey = 'favourites_migration_error';

  /// The shape of the favourites table, in one place, used by both databases.
  static const String _favouritesDdl = '''
    stop_code TEXT PRIMARY KEY,
    stop_name TEXT NOT NULL,
    added_at  TEXT DEFAULT (datetime('now')),
    sort_order INTEGER
  ''';

  /// True once the copy into the profile store has been made *and verified*.
  /// Until then every favourites read and write still goes to the old table —
  /// the user's data is never in only one place at a time.
  static bool _favouritesInProfile = false;

  /// Shared across concurrent callers on purpose: this is the future, not the
  /// database. Two screens asking for favourites at once must not each start
  /// their own migration.
  static Future<Database>? _profileOpening;

  static Future<Database> get profileDatabase =>
      _profileOpening ??= _openProfileOnce();

  static Future<Database> _openProfileOnce() async {
    try {
      return await _openProfile();
    } catch (_) {
      // Let a later call try again rather than caching the failure for the
      // lifetime of the process.
      _profileOpening = null;
      rethrow;
    }
  }

  static Future<Database> _openProfile() async {
    final path = join(await getDatabasesPath(), _profileDbName);
    final db = await openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        // DELETE journalling keeps every committed byte inside the single .db
        // file. Android opens SQLite in WAL by default, which parks recent
        // commits in a sibling `-wal` file that the backup rules do not name —
        // so a backup could faithfully capture a database that is missing the
        // user's most recent stars. This store is a handful of rows written a
        // few times a day; there is nothing here that WAL was buying us.
        await db.rawQuery('PRAGMA journal_mode = DELETE');
      },
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE favourites ($_favouritesDdl)');
        await db.execute('''
          CREATE TABLE profile_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        // The store declares its own version, so an import in a later release
        // can tell what it is reading rather than guessing from the columns.
        await db.insert('profile_meta', {
          'key': 'profile_format_version',
          'value': '1',
        });
      },
    );
    await _adoptLegacyFavourites(db);
    return db;
  }

  /// Copy the favourites out of `next_bus.db` exactly once, and only start
  /// reading the new store when the copy has been counted back.
  ///
  /// The old table is **not** dropped. A release that both moves data and
  /// destroys the only other copy of it has no way back if the move was wrong,
  /// and the move cannot be tested on every device before it ships.
  static Future<void> _adoptLegacyFavourites(Database profile) async {
    try {
      if (await _profileMeta(profile, _migratedKey) != null) {
        _favouritesInProfile = true;
        return;
      }

      final legacyPath = join(await getDatabasesPath(), _legacyDbName);
      if (!await File(legacyPath).exists()) {
        // A fresh install, or a restore that brought the profile store back
        // without the schedule. There is nothing to copy and nothing to fall
        // back to, so the new store is authoritative from birth.
        await _finishMigration(profile, 0);
        return;
      }

      final legacy = await database;
      final rows = await legacy.query(
        'favourites',
        orderBy: 'sort_order IS NULL, sort_order, added_at DESC',
      );

      await profile.transaction((txn) async {
        for (final row in rows) {
          await txn.insert('favourites', {
            'stop_code': row['stop_code'],
            'stop_name': row['stop_name'],
            'added_at': row['added_at'],
            'sort_order': row['sort_order'],
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        // Count the destination rather than trusting the loop. A short copy
        // must fail the whole transaction, not leave a plausible-looking
        // subset of someone's favourites behind.
        final copied = Sqflite.firstIntValue(
              await txn.rawQuery('SELECT COUNT(*) FROM favourites'),
            ) ??
            -1;
        if (copied != rows.length) {
          throw StateError(
            'profile migration copied $copied of ${rows.length} favourites',
          );
        }
        await txn.insert('profile_meta', {
          'key': _migratedKey,
          'value': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.insert('profile_meta', {
          'key': _migratedCountKey,
          'value': '${rows.length}',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
      _favouritesInProfile = true;
    } catch (e) {
      // Stay on the old table and say why. The failure mode this slice exists
      // to end is data disappearing quietly; a migration that fails silently
      // and shows an empty list would be the same bug wearing a new hat.
      _favouritesInProfile = false;
      try {
        await profile.insert('profile_meta', {
          'key': _migrationErrorKey,
          'value': '${DateTime.now().toIso8601String()}: $e',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } catch (_) {
        // The store itself is unwritable; the fallback above is the answer.
      }
    }
  }

  static Future<void> _finishMigration(Database profile, int count) async {
    await profile.insert('profile_meta', {
      'key': _migratedKey,
      'value': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await profile.insert('profile_meta', {
      'key': _migratedCountKey,
      'value': '$count',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _favouritesInProfile = true;
  }

  static Future<String?> _profileMeta(Database profile, String key) async {
    final rows = await profile.query(
      'profile_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// Whichever database currently owns the favourites.
  ///
  /// Both have the same table, so callers never learn which one answered. If
  /// the profile store cannot be opened or its migration has not been verified,
  /// this returns the original database and the app behaves exactly as it did
  /// before this slice — degraded to "no automatic backup", never to "no
  /// favourites".
  static Future<Database> _favDb() async {
    try {
      final profile = await profileDatabase;
      if (_favouritesInProfile) return profile;
    } catch (_) {
      // Fall through to the table that has always worked.
    }
    return database;
  }

  /// What the profile store thinks happened, for diagnostics and for slice E's
  /// fresh-install checks. Never throws: a store that cannot be read reports
  /// that it cannot be read.
  static Future<Map<String, String?>> profileStatus() async {
    try {
      final profile = await profileDatabase;
      return {
        'in_profile_store': '$_favouritesInProfile',
        'format_version': await _profileMeta(profile, 'profile_format_version'),
        'migrated_at': await _profileMeta(profile, _migratedKey),
        'migrated_count': await _profileMeta(profile, _migratedCountKey),
        'migration_error': await _profileMeta(profile, _migrationErrorKey),
      };
    } catch (e) {
      return {
        'in_profile_store': 'false',
        'migration_error': 'profile store unavailable: $e',
      };
    }
  }

  /// Favourites in the user's hand-set order (slice F).
  ///
  /// `sort_order IS NULL` leads the ORDER BY so that a row which somehow
  /// escaped the v5 migration sorts last rather than first — SQLite sorts
  /// NULLs before everything else ascending, which would put an unpositioned
  /// stop at the top of the list. `added_at DESC` breaks any tie, keeping the
  /// pre-F behaviour as the fallback.
  static Future<List<Map<String, dynamic>>> getFavourites() async {
    final db = await _favDb();
    return db.query(
      'favourites',
      orderBy: 'sort_order IS NULL, sort_order, added_at DESC',
    );
  }

  static Future<bool> isFavourite(String stopCode) async {
    final db = await _favDb();
    final rows = await db.query('favourites',
        where: 'stop_code = ?', whereArgs: [stopCode], limit: 1);
    return rows.isNotEmpty;
  }

  /// Save a stop, or refresh the name of one already saved.
  ///
  /// This used to be a single `ConflictAlgorithm.replace` insert. With slice F
  /// that is no longer safe: replacing the row drops its `sort_order`, so
  /// re-starring a stop you had already placed would jerk it out of position.
  /// So an existing row is updated in place and keeps both its position and
  /// its `added_at`.
  ///
  /// A genuinely new stop goes on **top** (Wil, 2026-09-20): a new star has to
  /// be visible, and appending to the bottom of a long hand-ordered list reads
  /// as the star having failed. One below the current minimum is enough — the
  /// order is relative, and the next drag renumbers densely anyway.
  static Future<void> addFavourite(String stopCode, String stopName) async {
    final db = await _favDb();
    await db.transaction((txn) async {
      final existing = await txn.query(
        'favourites',
        columns: ['stop_code'],
        where: 'stop_code = ?',
        whereArgs: [stopCode],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        await txn.update(
          'favourites',
          {'stop_name': stopName},
          where: 'stop_code = ?',
          whereArgs: [stopCode],
        );
        return;
      }
      final top = await txn.rawQuery('SELECT MIN(sort_order) AS m FROM favourites');
      final minOrder = (top.first['m'] as num?)?.toInt();
      await txn.insert('favourites', {
        'stop_code': stopCode,
        'stop_name': stopName,
        'sort_order': (minOrder ?? 0) - 1,
      });
    });
  }

  /// Persist a whole new favourites order, top first, in one transaction.
  ///
  /// Renumbers densely from 0 on every drop, which also tidies the negative
  /// values [addFavourite] leaves behind and any NULL that predates the
  /// migration. Returns the number of rows it actually moved so the caller can
  /// tell a silent no-op from a real write.
  static Future<int> reorderFavourites(List<String> stopCodesTopFirst) async {
    final db = await _favDb();
    var updated = 0;
    await db.transaction((txn) async {
      for (var i = 0; i < stopCodesTopFirst.length; i++) {
        updated += await txn.update(
          'favourites',
          {'sort_order': i},
          where: 'stop_code = ?',
          whereArgs: [stopCodesTopFirst[i]],
        );
      }
    });
    return updated;
  }

  static Future<int> removeFavourite(String stopCode) async {
    final db = await _favDb();
    return db.delete('favourites',
        where: 'stop_code = ?', whereArgs: [stopCode]);
  }

  /// What an import actually did. Counts, not a bool: "imported successfully"
  /// while silently dropping half the file is the failure this project keeps
  /// meeting, so the caller is handed the numbers and has to show them.
  static Future<ProfileImportOutcome> importProfile(
    List<Map<String, dynamic>> rows, {
    required bool replace,
  }) async {
    final db = await _favDb();
    var added = 0, skipped = 0, removed = 0;

    await db.transaction((txn) async {
      if (replace) {
        removed = await txn.delete('favourites');
        for (var i = 0; i < rows.length; i++) {
          await txn.insert('favourites', _rowFor(rows[i], i));
          added++;
        }
        return;
      }

      final existing = await txn.query('favourites', columns: ['stop_code']);
      final have = {for (final r in existing) r['stop_code'] as String};

      // Merged stops land at the BOTTOM, keeping the file's relative order.
      //
      // This deliberately breaks slice F's "a new star goes on top" rule, and
      // for the reason that rule exists: a single star has to be visible, so it
      // goes where the eye is. An import is not one star — it is a handful at
      // once, and putting them on top shoves the hand-ordered stops the user
      // actually arranged down the screen. The user already knows an import
      // happened; they do not need it announced by displacement.
      final top =
          await txn.rawQuery('SELECT MAX(sort_order) AS m FROM favourites');
      // A NULL sort_order predates slice F and sorts last under
      // [getFavourites]'s ORDER BY, so imported rows can appear above those.
      // Only reachable on a database that somehow skipped the v5 seeding.
      var next = ((top.first['m'] as num?)?.toInt() ?? -1) + 1;

      for (final row in rows) {
        if (have.contains(row['stop_code'])) {
          skipped++;
          continue;
        }
        await txn.insert('favourites', _rowFor(row, next++));
        added++;
      }
    });

    return ProfileImportOutcome(
        added: added, skipped: skipped, removed: removed);
  }

  /// One row, ready to insert. `added_at` is omitted rather than written as
  /// null when the file has none, so the column default supplies today instead
  /// of the row carrying a NULL that sorts oddly for the rest of its life.
  static Map<String, Object?> _rowFor(Map<String, dynamic> row, int order) {
    final out = <String, Object?>{
      'stop_code': row['stop_code'],
      'stop_name': row['stop_name'],
      'sort_order': order,
    };
    if (row['added_at'] is String) out['added_at'] = row['added_at'];
    return out;
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

  /// All feed inserts go to staging. There is no DELETE here any more: the
  /// staging tables are created empty by [beginImport], so an import never has a
  /// destructive first step.
  static Future<void> _insertStaging(
    String table,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert('$table$_importSuffix', r,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<void> insertRoutes(List<Map<String, String>> routes) =>
      _insertStaging('routes', routes);

  static Future<void> insertTrips(List<Map<String, String>> trips) =>
      _insertStaging('trips', trips);

  static Future<void> insertCalendar(
    List<Map<String, dynamic>> calendar,
    List<Map<String, dynamic>> calendarDates,
  ) async {
    await _insertStaging('calendar', calendar);
    await _insertStaging('calendar_dates', calendarDates);
  }

  static Future<void> insertStopTimesBatch(List<Map<String, dynamic>> rows) =>
      _insertStaging('stop_times', rows);

  /// Drops any staging left behind by an interrupted import and creates a fresh,
  /// empty set. Touches nothing live, so it is safe to call at any time.
  static Future<void> beginImport() async {
    final db = await database;
    await db.transaction((txn) async {
      for (final t in _feedTables) {
        await txn.execute('DROP TABLE IF EXISTS $t$_importSuffix');
        await txn.execute(_createFeedTable(t, suffix: _importSuffix));
      }
    });
  }

  /// Throws away a failed import. Cheap and total: staging is inert, so there is
  /// nothing to unwind and nothing live to restore.
  static Future<void> abortImport() async {
    final db = await database;
    await db.transaction((txn) async {
      for (final t in _feedTables) {
        await txn.execute('DROP TABLE IF EXISTS $t$_importSuffix');
      }
    });
  }

  /// The other half of finding 2.
  ///
  /// The old code answered an empty schedule query by re-running it with the
  /// calendar filter removed, which served Sunday buses on a Tuesday. A0 deleted
  /// that fallback, which removed the wrong answer but not the condition it was
  /// hiding: if `trips.service_id` does not join to `calendar`/`calendar_dates`
  /// — a feed that changes id format, a calendar.txt we failed to parse — then
  /// every stop in the app goes quiet and nothing says why.
  ///
  /// Checked here, against staging, because this is the only moment at which
  /// rejecting the data still leaves a working schedule to fall back to.
  static Future<ImportReport> validateImport() async {
    final db = await database;

    Future<int> count(String table) async {
      return Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM $table$_importSuffix'),
          ) ??
          0;
    }

    final orphanTrips = Sqflite.firstIntValue(await db.rawQuery('''
          SELECT COUNT(*) FROM trips$_importSuffix
          WHERE service_id NOT IN (SELECT service_id FROM calendar$_importSuffix)
            AND service_id NOT IN
                (SELECT service_id FROM calendar_dates$_importSuffix)
        ''')) ??
        0;

    final report = ImportReport(
      stops: await count('stops'),
      routes: await count('routes'),
      trips: await count('trips'),
      stopTimes: await count('stop_times'),
      calendar: await count('calendar'),
      calendarDates: await count('calendar_dates'),
      tripsWithoutService: orphanTrips,
    );

    void require(bool ok, String message) {
      if (!ok) throw ImportValidationException(message, report);
    }

    require(report.stops > 0, 'The schedule contained no stops.');
    require(report.routes > 0, 'The schedule contained no routes.');
    require(report.trips > 0, 'The schedule contained no trips.');
    require(report.stopTimes > 0, 'The schedule contained no departure times.');
    require(report.calendar > 0 || report.calendarDates > 0,
        'The schedule contained no service calendar.');

    // Does stop_times actually reach trips? A trip_id format change between the
    // two files would leave both tables full and every join empty.
    final linked = await db.rawQuery('''
      SELECT 1 FROM stop_times$_importSuffix st
      JOIN trips$_importSuffix t ON st.trip_id = t.trip_id
      LIMIT 1
    ''');
    require(linked.isNotEmpty,
        'Departure times in the schedule do not match any trip.');

    // Deliberately a majority rather than a totality. A real feed can carry a
    // few orphan trips, and failing a good download over one stray row would be
    // its own kind of outage. Nothing near this threshold occurs in a healthy
    // feed — the failure this guards against reads as 0%, not as 94%.
    require(
        report.serviceJoinRate >= 0.5,
        'Only ${(report.serviceJoinRate * 100).toStringAsFixed(1)}% of trips in '
        'this schedule have a matching service calendar, so the download was '
        'not applied. Your existing schedule is unchanged.');

    return report;
  }

  /// The swap. One transaction: the old tables go, staging takes their names,
  /// the index is rebuilt, and the feed date is recorded — so a reader sees
  /// either the whole old schedule or the whole new one, and the stored date can
  /// never describe data that is not there.
  ///
  /// sqflite serialises work on a single connection, so queries issued during
  /// the swap wait rather than observing a half-swapped database. The index
  /// build is the slow part and is inside the transaction on purpose: a schedule
  /// that is live but unindexed would be correct and unusably slow.
  static Future<void> commitImport(String gtfsDate) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final t in _feedTables) {
        await txn.execute('DROP TABLE IF EXISTS $t');
        await txn.execute('ALTER TABLE $t$_importSuffix RENAME TO $t');
      }
      await txn.execute(_stopTimesIndexSql);
      await txn.insert(
        'metadata',
        {'key': 'gtfs_date', 'value': gtfsDate},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      // In the same transaction as the swap and the feed date, for the same
      // reason: a recorded success that is not tied to the data landing is a
      // recorded success that can lie.
      await txn.insert(
        'metadata',
        {'key': 'gtfs_updated_at', 'value': DateTime.now().toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  static Future<void> updateFavouriteName(String stopCode, String newName) async {
    final db = await _favDb();
    await db.update(
      'favourites',
      {'stop_name': newName},
      where: 'stop_code = ?',
      whereArgs: [stopCode],
    );
  }

  // setGtfsDate is deliberately gone. The feed date is now written inside
  // commitImport's transaction, because a second way to set it is a second way
  // for the recorded date to describe data that is not there.
}

/// What the pre-swap checks found. Reported on success as well as failure: a
/// check that only ever speaks when it fails cannot be told apart from a check
/// that never ran.
class ImportReport {
  final int stops;
  final int routes;
  final int trips;
  final int stopTimes;
  final int calendar;
  final int calendarDates;

  /// Trips whose `service_id` appears in neither `calendar` nor
  /// `calendar_dates`. In a healthy feed this is zero or near it.
  final int tripsWithoutService;

  const ImportReport({
    required this.stops,
    required this.routes,
    required this.trips,
    required this.stopTimes,
    required this.calendar,
    required this.calendarDates,
    required this.tripsWithoutService,
  });

  int get tripsWithService => trips - tripsWithoutService;

  double get serviceJoinRate => trips == 0 ? 0 : tripsWithService / trips;

  @override
  String toString() =>
      '$stops stops, $routes routes, $trips trips, $stopTimes times, '
      'service match ${(serviceJoinRate * 100).toStringAsFixed(1)}%';
}

/// The result of [DbService.importProfile].
class ProfileImportOutcome {
  /// Stops written.
  final int added;

  /// Stops in the file that were already saved here, left exactly as they
  /// were — their name and their hand-set position both (Wil, 2026-09-28).
  final int skipped;

  /// Stops cleared out first. Non-zero only on a replace.
  final int removed;

  const ProfileImportOutcome({
    required this.added,
    required this.skipped,
    required this.removed,
  });
}

/// Thrown when a downloaded feed fails its pre-swap checks. The live schedule is
/// untouched when this is raised, which is the whole point of raising it here.
class ImportValidationException implements Exception {
  final String message;
  final ImportReport? report;
  const ImportValidationException(this.message, [this.report]);

  @override
  String toString() => message;
}
