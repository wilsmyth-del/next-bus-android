#!/usr/bin/env python3
"""Model check for the GTFS stage-and-swap import (#321 slice B1).

WHAT THIS IS: a re-implementation, in Python against a real sqlite3, of the SQL
and the ordering that lib/services/db_service.dart uses for beginImport,
validateImport, commitImport and abortImport. It exists because there is no Dart
SDK on this box (#311), so the logic cannot be exercised any other way here.

WHAT THIS IS NOT: a test of the shipped code. It is a SECOND IMPLEMENTATION and
it CAN drift from the Dart. The Dart is authoritative. If you change the staging
SQL, the validation gate, or the swap order in db_service.dart, change it here in
the same commit or delete this file. A model check that has silently diverged is
worse than no model check at all.

Run: python3 tools/import_gate_model_test.py
"""

import sqlite3
import sys

# --- mirrored from db_service.dart -----------------------------------------

IMPORT_SUFFIX = '_import'

FEED_TABLES = ['stops', 'routes', 'trips', 'calendar', 'calendar_dates',
               'stop_times']

FEED_TABLE_DDL = {
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
    # No primary key: it indexed ~3.7M rows on columns nothing reads. See the
    # matching comment in db_service.dart for the trade-off this accepts.
    'stop_times': '''
      trip_id        TEXT NOT NULL,
      stop_id        TEXT NOT NULL,
      departure_time TEXT NOT NULL,
      stop_sequence  INTEGER NOT NULL
    ''',
}

STOP_TIMES_INDEX_SQL = (
    'CREATE INDEX IF NOT EXISTS idx_stop_times_stop '
    'ON stop_times(stop_id, departure_time)'
)

JOIN_RATE_FLOOR = 0.5


def create_feed_table(table, suffix=''):
    return 'CREATE TABLE IF NOT EXISTS %s%s (%s)' % (
        table, suffix, FEED_TABLE_DDL[table])


class ImportValidationError(Exception):
    pass


def open_db():
    """The live schema, as onCreate builds it."""
    db = sqlite3.connect(':memory:')
    db.execute('CREATE TABLE metadata (key TEXT PRIMARY KEY, '
               'value TEXT NOT NULL)')
    db.execute('CREATE TABLE favourites (stop_code TEXT PRIMARY KEY, '
               "stop_name TEXT NOT NULL, added_at TEXT DEFAULT (datetime('now')))")
    for t in FEED_TABLES:
        db.execute(create_feed_table(t))
    db.execute(STOP_TIMES_INDEX_SQL)
    return db


def begin_import(db):
    for t in FEED_TABLES:
        db.execute('DROP TABLE IF EXISTS %s%s' % (t, IMPORT_SUFFIX))
        db.execute(create_feed_table(t, IMPORT_SUFFIX))
    db.commit()


def abort_import(db):
    for t in FEED_TABLES:
        db.execute('DROP TABLE IF EXISTS %s%s' % (t, IMPORT_SUFFIX))
    db.commit()


def insert_staging(db, table, rows):
    if not rows:
        return
    cols = list(rows[0].keys())
    sql = 'INSERT OR REPLACE INTO %s%s (%s) VALUES (%s)' % (
        table, IMPORT_SUFFIX, ','.join(cols), ','.join('?' * len(cols)))
    db.executemany(sql, [tuple(r[c] for c in cols) for r in rows])
    db.commit()


def validate_import(db):
    def count(table):
        return db.execute(
            'SELECT COUNT(*) FROM %s%s' % (table, IMPORT_SUFFIX)).fetchone()[0]

    orphan = db.execute('''
        SELECT COUNT(*) FROM trips%s
        WHERE service_id NOT IN (SELECT service_id FROM calendar%s)
          AND service_id NOT IN (SELECT service_id FROM calendar_dates%s)
    ''' % (IMPORT_SUFFIX, IMPORT_SUFFIX, IMPORT_SUFFIX)).fetchone()[0]

    report = {t: count(t) for t in FEED_TABLES}
    report['tripsWithoutService'] = orphan
    trips = report['trips']
    report['serviceJoinRate'] = 0.0 if trips == 0 else (trips - orphan) / trips

    def require(ok, message):
        if not ok:
            raise ImportValidationError(message)

    require(report['stops'] > 0, 'The schedule contained no stops.')
    require(report['routes'] > 0, 'The schedule contained no routes.')
    require(report['trips'] > 0, 'The schedule contained no trips.')
    require(report['stop_times'] > 0,
            'The schedule contained no departure times.')
    require(report['calendar'] > 0 or report['calendar_dates'] > 0,
            'The schedule contained no service calendar.')

    linked = db.execute('''
        SELECT 1 FROM stop_times%s st
        JOIN trips%s t ON st.trip_id = t.trip_id
        LIMIT 1
    ''' % (IMPORT_SUFFIX, IMPORT_SUFFIX)).fetchall()
    require(bool(linked),
            'Departure times in the schedule do not match any trip.')

    require(report['serviceJoinRate'] >= JOIN_RATE_FLOOR,
            'Only %.1f%% of trips in this schedule have a matching service '
            'calendar.' % (report['serviceJoinRate'] * 100))

    return report


def commit_import(db, gtfs_date):
    for t in FEED_TABLES:
        db.execute('DROP TABLE IF EXISTS %s' % t)
        db.execute('ALTER TABLE %s%s RENAME TO %s' % (t, IMPORT_SUFFIX, t))
    db.execute(STOP_TIMES_INDEX_SQL)
    db.execute('INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)',
               ('gtfs_date', gtfs_date))
    db.commit()


# --- fixtures ---------------------------------------------------------------

def good_feed(n_trips=10, orphan_trips=0):
    """A feed that should pass. `orphan_trips` of them reference no calendar."""
    stops = [{'stop_code': '5%03d' % i, 'stop_id': 'S%d' % i,
              'stop_name': 'Stop %d' % i} for i in range(3)]
    routes = [{'route_id': 'R1', 'route_short_name': '99'}]
    trips, stop_times = [], []
    for i in range(n_trips):
        svc = 'ORPHAN%d' % i if i < orphan_trips else 'WEEKDAY'
        trips.append({'trip_id': 'T%d' % i, 'route_id': 'R1',
                      'service_id': svc, 'headsign': 'Downtown'})
        stop_times.append({'trip_id': 'T%d' % i, 'stop_id': 'S0',
                           'departure_time': '%02d:00:00' % (6 + i % 12),
                           'stop_sequence': 1})
    calendar = [{'service_id': 'WEEKDAY', 'monday': 1, 'tuesday': 1,
                 'wednesday': 1, 'thursday': 1, 'friday': 1, 'saturday': 0,
                 'sunday': 0, 'start_date': '20260101',
                 'end_date': '20261231'}]
    return {'stops': stops, 'routes': routes, 'trips': trips,
            'calendar': calendar, 'calendar_dates': [],
            'stop_times': stop_times}


def load_staging(db, feed):
    for t in FEED_TABLES:
        insert_staging(db, t, feed.get(t, []))


def seed_live(db, date='2026-08-01'):
    """An existing, working schedule plus user data, as on a real phone."""
    db.execute("INSERT INTO stops VALUES ('OLD1','SOLD','Old Stop')")
    db.execute("INSERT INTO routes VALUES ('ROLD','OLD')")
    db.execute("INSERT INTO trips VALUES ('TOLD','ROLD','OLDSVC','Old')")
    db.execute("INSERT INTO calendar VALUES ('OLDSVC',1,1,1,1,1,0,0,"
               "'20260101','20261231')")
    db.execute("INSERT INTO stop_times VALUES ('TOLD','SOLD','08:00:00',1)")
    db.execute("INSERT INTO favourites (stop_code, stop_name) "
               "VALUES ('OLD1','Old Stop')")
    db.execute("INSERT INTO metadata VALUES ('gtfs_date', ?)", (date,))
    db.commit()


def live_snapshot(db):
    return {t: db.execute('SELECT COUNT(*) FROM %s' % t).fetchone()[0]
            for t in FEED_TABLES}


def staging_tables(db):
    return sorted(r[0] for r in db.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name LIKE '%\\_import' ESCAPE '\\'").fetchall())


def gtfs_date(db):
    row = db.execute(
        "SELECT value FROM metadata WHERE key='gtfs_date'").fetchone()
    return row[0] if row else None


# --- cases ------------------------------------------------------------------

CASES = []


def case(name):
    def wrap(fn):
        CASES.append((name, fn))
        return fn
    return wrap


@case('1. a healthy feed passes the gate and swaps in')
def _(db):
    seed_live(db)
    begin_import(db)
    load_staging(db, good_feed())
    report = validate_import(db)
    commit_import(db, '2026-08-28')
    assert report['serviceJoinRate'] == 1.0, report
    assert live_snapshot(db)['trips'] == 10
    assert gtfs_date(db) == '2026-08-28'


@case('2. the swap leaves no staging tables behind')
def _(db):
    begin_import(db)
    load_staging(db, good_feed())
    validate_import(db)
    commit_import(db, '2026-08-28')
    assert staging_tables(db) == [], staging_tables(db)


@case('3. favourites and the metadata table survive a swap untouched')
def _(db):
    seed_live(db)
    begin_import(db)
    load_staging(db, good_feed())
    validate_import(db)
    commit_import(db, '2026-08-28')
    favs = db.execute('SELECT stop_code FROM favourites').fetchall()
    assert favs == [('OLD1',)], favs


@case('4. a feed whose trips join no calendar at all is REJECTED')
def _(db):
    seed_live(db)
    begin_import(db)
    load_staging(db, good_feed(n_trips=10, orphan_trips=10))
    try:
        validate_import(db)
    except ImportValidationError as e:
        assert '0.0%' in str(e), str(e)
    else:
        raise AssertionError('total service-id mismatch was accepted')


@case('5. REJECTED import leaves the previous schedule fully intact')
def _(db):
    seed_live(db)
    before = live_snapshot(db)
    begin_import(db)
    load_staging(db, good_feed(n_trips=10, orphan_trips=10))
    try:
        validate_import(db)
    except ImportValidationError:
        abort_import(db)
    assert live_snapshot(db) == before, (live_snapshot(db), before)
    assert gtfs_date(db) == '2026-08-01', 'feed date must not advance'
    assert staging_tables(db) == []


@case('6. a few orphan trips are tolerated — this is a floor, not a totality')
def _(db):
    begin_import(db)
    load_staging(db, good_feed(n_trips=100, orphan_trips=3))
    report = validate_import(db)
    assert abs(report['serviceJoinRate'] - 0.97) < 1e-9, report


@case('7. exactly at the 50% floor the feed is accepted')
def _(db):
    begin_import(db)
    load_staging(db, good_feed(n_trips=10, orphan_trips=5))
    report = validate_import(db)
    assert report['serviceJoinRate'] == 0.5


@case('8. one trip below the floor and it is rejected')
def _(db):
    begin_import(db)
    load_staging(db, good_feed(n_trips=10, orphan_trips=6))
    try:
        validate_import(db)
    except ImportValidationError:
        return
    raise AssertionError('40% service match was accepted')


@case('9. trips reachable only via calendar_dates still count as joined')
def _(db):
    feed = good_feed(n_trips=4, orphan_trips=4)
    feed['calendar'] = []
    feed['calendar_dates'] = [
        {'service_id': 'ORPHAN%d' % i, 'date': '20260828', 'exception_type': 1}
        for i in range(4)]
    begin_import(db)
    load_staging(db, feed)
    report = validate_import(db)
    assert report['serviceJoinRate'] == 1.0, report


@case('10. an empty stops.txt is rejected')
def _(db):
    feed = good_feed()
    feed['stops'] = []
    begin_import(db)
    load_staging(db, feed)
    try:
        validate_import(db)
    except ImportValidationError as e:
        assert 'no stops' in str(e)
        return
    raise AssertionError('empty stops accepted')


@case('11. a feed with no calendar and no calendar_dates is rejected')
def _(db):
    feed = good_feed()
    feed['calendar'] = []
    begin_import(db)
    load_staging(db, feed)
    try:
        validate_import(db)
    except ImportValidationError as e:
        assert 'service calendar' in str(e)
        return
    raise AssertionError('feed with no calendar accepted')


@case('12. stop_times whose trip_ids match nothing is rejected')
def _(db):
    feed = good_feed()
    for st in feed['stop_times']:
        st['trip_id'] = 'DIFFERENT_FORMAT_' + st['trip_id']
    begin_import(db)
    load_staging(db, feed)
    try:
        validate_import(db)
    except ImportValidationError as e:
        assert 'do not match any trip' in str(e)
        return
    raise AssertionError('unjoinable stop_times accepted')


@case('13. an import interrupted mid-write leaves the live schedule working')
def _(db):
    seed_live(db)
    before = live_snapshot(db)
    begin_import(db)
    # Killed after stops and routes, before trips/stop_times — the exact shape
    # that used to leave the database mixed and unusable.
    feed = good_feed()
    insert_staging(db, 'stops', feed['stops'])
    insert_staging(db, 'routes', feed['routes'])
    assert live_snapshot(db) == before, 'live data was touched mid-import'
    assert gtfs_date(db) == '2026-08-01'


@case('14. staging left by a killed import is cleared by the next beginImport')
def _(db):
    begin_import(db)
    insert_staging(db, 'stops', good_feed()['stops'])
    assert db.execute('SELECT COUNT(*) FROM stops_import').fetchone()[0] == 3
    begin_import(db)          # a second attempt, as after an app restart
    assert db.execute('SELECT COUNT(*) FROM stops_import').fetchone()[0] == 0
    assert len(staging_tables(db)) == len(FEED_TABLES)


@case('15. the stop_times index exists under its canonical name after a swap')
def _(db):
    begin_import(db)
    load_staging(db, good_feed())
    validate_import(db)
    commit_import(db, '2026-08-28')
    idx = sorted(r[0] for r in db.execute(
        "SELECT name FROM sqlite_master WHERE type='index' "
        "AND tbl_name='stop_times'").fetchall())
    assert 'idx_stop_times_stop' in idx, idx
    # A stray staging-named index would be a duplicate doing the same work twice.
    assert not any(i.endswith('_import') for i in idx), idx


@case('16. the swapped-in table keeps the live column definition')
def _(db):
    begin_import(db)
    load_staging(db, good_feed())
    validate_import(db)
    commit_import(db, '2026-08-28')
    cols = [(r[1], r[2]) for r in db.execute('PRAGMA table_info(stops)')]
    assert cols == [('stop_code', 'TEXT'), ('stop_id', 'TEXT'),
                    ('stop_name', 'TEXT')], cols


@case('17. the feed date never advances without the data that goes with it')
def _(db):
    seed_live(db)
    begin_import(db)
    feed = good_feed()
    feed['stops'] = []
    load_staging(db, feed)
    try:
        validate_import(db)
    except ImportValidationError:
        abort_import(db)
    assert gtfs_date(db) == '2026-08-01'
    # And the converse: a successful import moves both together.
    begin_import(db)
    load_staging(db, good_feed())
    validate_import(db)
    commit_import(db, '2026-08-28')
    assert gtfs_date(db) == '2026-08-28'
    assert live_snapshot(db)['stops'] == 3


@case('18. an entirely empty archive is rejected rather than swapped in')
def _(db):
    seed_live(db)
    before = live_snapshot(db)
    begin_import(db)
    try:
        validate_import(db)
    except ImportValidationError:
        abort_import(db)
        assert live_snapshot(db) == before
        return
    raise AssertionError('an empty feed was accepted')


@case('19. a second import over an already-swapped database still works')
def _(db):
    begin_import(db)
    load_staging(db, good_feed(n_trips=5))
    validate_import(db)
    commit_import(db, '2026-08-21')
    begin_import(db)
    load_staging(db, good_feed(n_trips=12))
    validate_import(db)
    commit_import(db, '2026-08-28')
    assert live_snapshot(db)['trips'] == 12
    assert gtfs_date(db) == '2026-08-28'
    assert staging_tables(db) == []


@case('20. stop_times carries exactly one index — the one queries use')
def _(db):
    begin_import(db)
    load_staging(db, good_feed())
    validate_import(db)
    commit_import(db, '2026-08-28')
    idx = sorted(r[0] for r in db.execute(
        "SELECT name FROM sqlite_master WHERE type='index' "
        "AND tbl_name='stop_times'").fetchall())
    # An implicit sqlite_autoindex_* here would mean the primary key came back,
    # and with it a second index over every row in the feed.
    assert idx == ['idx_stop_times_stop'], idx


@case('21. duplicate rows are no longer silently collapsed')
def _(db):
    # Documents the accepted trade-off rather than approving of it: without the
    # primary key a malformed feed's duplicate row survives to the live table
    # instead of being replaced on insert.
    begin_import(db)
    feed = good_feed(n_trips=1)
    feed['stop_times'].append(dict(feed['stop_times'][0]))
    load_staging(db, feed)
    validate_import(db)
    commit_import(db, '2026-08-28')
    assert live_snapshot(db)['stop_times'] == 2


@case('22. every feed table has a definition, and vice versa')
def _(db):
    assert sorted(FEED_TABLES) == sorted(FEED_TABLE_DDL), \
        'FEED_TABLES and FEED_TABLE_DDL disagree'
    assert 'favourites' not in FEED_TABLES
    assert 'metadata' not in FEED_TABLES


def main():
    passed = failed = 0
    for name, fn in CASES:
        db = open_db()
        try:
            fn(db)
        except Exception as e:
            failed += 1
            print('FAIL  %s\n        %s: %s' % (name, type(e).__name__, e))
        else:
            passed += 1
            print('ok    %s' % name)
        finally:
            db.close()
    print('\n%d passed, %d failed' % (passed, failed))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
