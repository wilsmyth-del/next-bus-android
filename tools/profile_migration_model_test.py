#!/usr/bin/env python3
"""Profile-store migration model check (#321 slice G, half 1).

WHAT THIS IS: a Python re-implementation of what slice G added to
lib/services/db_service.dart — opening next_bus_profile.db, copying the
favourites out of next_bus.db exactly once, verifying the copy by counting the
destination, and falling back to the old table whenever that verification has
not succeeded. Run against real sqlite3 so it can be exercised on the NUC,
which has no Dart SDK (#311).

The thing worth checking here is not the happy path. It is that a migration
which goes wrong leaves the user exactly where they started — favourites still
readable from the original table — rather than showing an empty list. Slice G
exists because data vanished silently; a migration that could do the same thing
would be the same bug wearing a new hat.

WHAT THIS IS NOT: a test of the shipped code. It is a second implementation and
it CAN drift from the Dart. The Dart is authoritative. If you change the
migration, the fallback or the meta keys, change it here in the same commit or
delete this file — a model check that has silently diverged is worse than no
model check at all.

    python3 tools/profile_migration_model_test.py
"""

import os
import sqlite3
import tempfile

passed = failed = 0

def check(label, got, want):
    global passed, failed
    if got == want:
        passed += 1
        print(f"  ok   {label}")
    else:
        failed += 1
        print(f"  FAIL {label}\n       got  {got}\n       want {want}")

# ── the model ─────────────────────────────────────────────────────────────────

ORDER_BY = 'sort_order IS NULL, sort_order, added_at DESC'

MIGRATED_KEY = 'favourites_migrated_at'
MIGRATED_COUNT_KEY = 'favourites_migrated_count'
MIGRATION_ERROR_KEY = 'favourites_migration_error'

FAVOURITES_DDL = """stop_code TEXT PRIMARY KEY,
                    stop_name TEXT NOT NULL,
                    added_at  TEXT DEFAULT (datetime('now')),
                    sort_order INTEGER"""


def _connect(path):
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    return db


def build_legacy(path, rows):
    """A v5 next_bus.db: favourites next to (notionally) the whole schedule."""
    db = _connect(path)
    db.execute(f"CREATE TABLE favourites ({FAVOURITES_DDL})")
    db.execute("CREATE TABLE stop_times (trip_id TEXT, stop_id TEXT)")
    for code, name, added, order_ in rows:
        db.execute(
            "INSERT INTO favourites (stop_code, stop_name, added_at, sort_order)"
            " VALUES (?,?,?,?)", (code, name, added, order_))
    db.commit()
    return db


def open_profile(path):
    """next_bus_profile.db at version 1 — onCreate only, there is no v0."""
    fresh = not os.path.exists(path)
    db = _connect(path)
    if fresh:
        db.execute(f"CREATE TABLE favourites ({FAVOURITES_DDL})")
        db.execute("CREATE TABLE profile_meta (key TEXT PRIMARY KEY,"
                   " value TEXT NOT NULL)")
        db.execute("INSERT INTO profile_meta VALUES ('profile_format_version','1')")
        db.commit()
    return db


def meta(db, key):
    row = db.execute("SELECT value FROM profile_meta WHERE key = ?", (key,)).fetchone()
    return row['value'] if row else None


def set_meta(db, key, value):
    db.execute("INSERT OR REPLACE INTO profile_meta VALUES (?,?)", (key, str(value)))


def adopt_legacy(profile, legacy_path, sabotage=None):
    """_adoptLegacyFavourites. Returns True when the profile store is
    authoritative — i.e. the copy was made AND counted back."""
    try:
        if meta(profile, MIGRATED_KEY) is not None:
            return True

        if not os.path.exists(legacy_path):
            set_meta(profile, MIGRATED_KEY, '2026-09-22T00:00:00')
            set_meta(profile, MIGRATED_COUNT_KEY, 0)
            profile.commit()
            return True

        legacy = _connect(legacy_path)
        rows = legacy.execute(
            f"SELECT * FROM favourites ORDER BY {ORDER_BY}").fetchall()

        if sabotage == 'preload':
            # A previous attempt left something behind: the destination count
            # will overshoot the source.
            profile.execute("INSERT INTO favourites (stop_code, stop_name)"
                            " VALUES ('9999','ghost')")

        to_copy = rows[:-1] if sabotage == 'skip_one' else rows
        for row in to_copy:
            profile.execute(
                "INSERT OR REPLACE INTO favourites"
                " (stop_code, stop_name, added_at, sort_order) VALUES (?,?,?,?)",
                (row['stop_code'], row['stop_name'], row['added_at'],
                 row['sort_order']))
        copied = profile.execute("SELECT COUNT(*) AS c FROM favourites").fetchone()['c']
        if copied != len(rows):
            raise RuntimeError(
                f"profile migration copied {copied} of {len(rows)} favourites")
        set_meta(profile, MIGRATED_KEY, '2026-09-22T00:00:00')
        set_meta(profile, MIGRATED_COUNT_KEY, len(rows))
        profile.commit()
        return True
    except Exception as e:                       # noqa: BLE001 - mirrors the catch
        profile.rollback()
        set_meta(profile, MIGRATION_ERROR_KEY, e)
        profile.commit()
        return False


def fav_db(profile, legacy, in_profile):
    """_favDb: the caller never learns which database answered."""
    return profile if in_profile else legacy


def get_favourites(db):
    return [r['stop_code'] for r in
            db.execute(f"SELECT * FROM favourites ORDER BY {ORDER_BY}")]


# ── the cases ─────────────────────────────────────────────────────────────────

TMP = tempfile.mkdtemp(prefix='next_bus_g_')

def paths(tag):
    return (os.path.join(TMP, f'{tag}_next_bus.db'),
            os.path.join(TMP, f'{tag}_profile.db'))

# Four favourites in a hand-set order, one of them never positioned — the row
# slice F's ORDER BY deliberately sorts last rather than first.
ROWS = [('50001', 'Broadway @ Main',  '2026-01-01 00:00:00', 0),
        ('50002', 'Granville @ 4th',  '2026-01-02 00:00:00', 1),
        ('50003', 'Cambie @ 12th',    '2026-01-03 00:00:00', 2),
        ('50004', 'Oak @ King Ed',    '2026-01-04 00:00:00', None)]

print("1. The upgrade path: an existing user with favourites")
lp, pp = paths('upgrade')
legacy = build_legacy(lp, ROWS)
profile = open_profile(pp)
ok = adopt_legacy(profile, lp)
check("the migration reports success", ok, True)
check("every favourite arrived", len(get_favourites(profile)), 4)
check("in exactly the order the list showed",
      get_favourites(profile), ['50001', '50002', '50003', '50004'])
# The ORDER BY on the copy itself is not load-bearing and this file should not
# pretend otherwise: the destination re-sorts on every read, so a copy made in
# any order reads back the same. What has to survive is the sort_order VALUES,
# which is what the next check actually pins down. (Found 2026-09-22 by
# breaking the copy's ORDER BY on purpose and watching all 31 cases still pass.)
check("sort_order values survived verbatim",
      [(r['stop_code'], r['sort_order']) for r in
       profile.execute("SELECT * FROM favourites ORDER BY stop_code")],
      [('50001', 0), ('50002', 1), ('50003', 2), ('50004', None)])
check("the count is recorded, not just the flag",
      meta(profile, MIGRATED_COUNT_KEY), '4')
check("no error was recorded", meta(profile, MIGRATION_ERROR_KEY), None)
check("the store declares its format version",
      meta(profile, 'profile_format_version'), '1')

print("2. The old table is left alone")
# Not an oversight. A release that moves data and destroys the only other copy
# in the same breath has no way back, and cannot be tested on every device
# before it ships.
check("legacy favourites still present", len(get_favourites(legacy)), 4)
check("an unpositioned row kept its NULL", profile.execute(
    "SELECT sort_order FROM favourites WHERE stop_code='50004'").fetchone()[0], None)
check("added_at survived the copy verbatim", profile.execute(
    "SELECT added_at FROM favourites WHERE stop_code='50002'").fetchone()[0],
    '2026-01-02 00:00:00')

print("3. It happens exactly once")
before = meta(profile, MIGRATED_KEY)
profile.execute("DELETE FROM favourites WHERE stop_code='50001'")   # user unstars
profile.commit()
ok2 = adopt_legacy(profile, lp)
check("a second launch still reports the store authoritative", ok2, True)
check("and does not re-copy the row the user removed",
      get_favourites(profile), ['50002', '50003', '50004'])
check("the flag was not rewritten", meta(profile, MIGRATED_KEY), before)

print("4. A fresh install, or a restore that brought only the profile store")
lp2, pp2 = paths('fresh')
profile2 = open_profile(pp2)
check("no legacy database exists", os.path.exists(lp2), False)
ok3 = adopt_legacy(profile2, lp2)
check("the store is authoritative from birth", ok3, True)
check("and says it copied nothing", meta(profile2, MIGRATED_COUNT_KEY), '0')
check("starting empty", get_favourites(profile2), [])

print("5. A short copy must not be adopted")
lp3, pp3 = paths('short')
legacy3 = build_legacy(lp3, ROWS)
profile3 = open_profile(pp3)
ok4 = adopt_legacy(profile3, lp3, sabotage='skip_one')
check("the migration reports failure", ok4, False)
check("the flag is NOT set", meta(profile3, MIGRATED_KEY), None)
check("the partial copy was rolled back", get_favourites(profile3), [])
check("and the reason was written down",
      meta(profile3, MIGRATION_ERROR_KEY) is not None, True)

print("6. ...and the user still has every favourite")
# This is the case the whole design is for.
answering = fav_db(profile3, legacy3, ok4)
check("reads fall back to the original table",
      get_favourites(answering), ['50001', '50002', '50003', '50004'])
check("which is the same list as before the upgrade",
      get_favourites(answering), get_favourites(legacy3))

print("7. Leftovers from a failed attempt are caught, not absorbed")
lp4, pp4 = paths('preload')
legacy4 = build_legacy(lp4, ROWS)
profile4 = open_profile(pp4)
ok5 = adopt_legacy(profile4, lp4, sabotage='preload')
check("an overshooting count fails too", ok5, False)
check("nothing was adopted", meta(profile4, MIGRATED_KEY), None)
check("the ghost row went with the rollback", get_favourites(profile4), [])
check("and reads still come from the old table",
      get_favourites(fav_db(profile4, legacy4, ok5)), ['50001', '50002', '50003', '50004'])

print("8. A write made while unmigrated is not stranded")
# The fallback is a real database, not a read-only view: stars added during a
# failed-migration launch land in the old table and are picked up by the next
# successful attempt.
legacy4.execute("INSERT INTO favourites (stop_code, stop_name, added_at, sort_order)"
                " VALUES ('50005','Main @ Terminal','2026-01-05 00:00:00',-1)")
legacy4.commit()
profile5 = open_profile(pp4)          # same file, still unmigrated
ok6 = adopt_legacy(profile5, lp4)     # no sabotage this time
check("the retry succeeds", ok6, True)
check("and carries the newer star, still on top",
      get_favourites(profile5), ['50005', '50001', '50002', '50003', '50004'])
check("the recorded count includes it", meta(profile5, MIGRATED_COUNT_KEY), '5')

print("9. An empty legacy table is a real answer, not a failure")
lp6, pp6 = paths('empty')
build_legacy(lp6, [])
profile6 = open_profile(pp6)
ok7 = adopt_legacy(profile6, lp6)
check("migrating nothing succeeds", ok7, True)
check("and is recorded as zero", meta(profile6, MIGRATED_COUNT_KEY), '0')

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
