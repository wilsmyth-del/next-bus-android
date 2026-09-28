#!/usr/bin/env python3
"""Profile export/import model check (#321 slice G, half 2).

WHAT THIS IS: a Python re-implementation of lib/services/profile_io.dart
(encode/decode of the portable profile file) and of DbService.importProfile's
merge and replace semantics, run against real sqlite3 so it can be exercised on
the NUC, which has no Dart SDK (#311).

WHAT IT IS FOR: this is the first code in the app that reads a file the user
chose, from outside the app, possibly written by somebody else or by a later
version. Everything in here assumes the file is hostile or broken until proved
otherwise. The specific failure being designed against is slice C's: `_getFeed()`
collapsed four different faults into one bare null and the UI rendered all four
as a shrug, which ran for weeks. Every refusal here has to name itself.

WHAT THIS IS NOT: a test of the shipped code. It is a second implementation and
it CAN drift from the Dart. The Dart is authoritative. If you change the format,
the validation or the merge rule, change this in the same commit or delete it.

    python3 tools/profile_io_model_test.py
"""

import json
import sqlite3

passed = failed = 0


def check(label, got, want):
    global passed, failed
    if got == want:
        passed += 1
        print(f"  ok   {label}")
    else:
        failed += 1
        print(f"  FAIL {label}\n       got  {got}\n       want {want}")


# ── the model: the file format ────────────────────────────────────────────────

FORMAT_VERSION = 1
FIELDS = ['stop_code', 'stop_name', 'added_at', 'sort_order', 'colour']

(NOT_JSON, NOT_AN_OBJECT, MISSING_VERSION, FUTURE_VERSION,
 MISSING_FAVOURITES, NO_USABLE_ROWS) = (
    'notJson', 'notAnObject', 'missingVersion', 'futureVersion',
    'missingFavourites', 'noUsableRows')

MESSAGES = {
    NOT_JSON: "That file isn't a Next Bus profile — it couldn't be read as JSON.",
    NOT_AN_OBJECT: "That file is JSON, but not a profile file.",
    MISSING_VERSION: "That file has no format version, so it isn't a Next Bus profile.",
    FUTURE_VERSION: "That profile was made by a newer version of Next Bus. Update the app and try again.",
    MISSING_FAVOURITES: "That profile has no favourites list in it.",
    NO_USABLE_ROWS: "That profile has a favourites list, but no stop in it could be read.",
}


def encode(favourites, now='2026-09-28T06:50:00.000'):
    return json.dumps({
        'app': 'next_bus',
        'format_version': FORMAT_VERSION,
        'exported_at': now,
        'favourites': [
            {'stop_code': str(r['stop_code']),
             'stop_name': str(r['stop_name']),
             'added_at': r.get('added_at'),
             'sort_order': r.get('sort_order'),
             'colour': r.get('colour')}
            for r in favourites
        ],
    }, indent=2)


def decode(raw):
    """Returns (rows, error, skipped). Mirrors ProfileIo.decode."""
    try:
        parsed = json.loads(raw)
    except Exception:
        return [], NOT_JSON, 0
    if not isinstance(parsed, dict):
        return [], NOT_AN_OBJECT, 0

    version = parsed.get('format_version')
    if not isinstance(version, int) or isinstance(version, bool):
        return [], MISSING_VERSION, 0
    if version > FORMAT_VERSION:
        return [], FUTURE_VERSION, 0

    lst = parsed.get('favourites')
    if not isinstance(lst, list):
        return [], MISSING_FAVOURITES, 0

    rows, skipped, seen = [], 0, set()
    for entry in lst:
        if not isinstance(entry, dict):
            skipped += 1
            continue
        code, name = entry.get('stop_code'), entry.get('stop_name')
        if not isinstance(code, str) or not code.strip() \
           or not isinstance(name, str) or not name.strip():
            skipped += 1
            continue
        if code.strip() in seen:
            skipped += 1
            continue
        seen.add(code.strip())
        order = entry.get('sort_order')
        rows.append({
            'stop_code': code.strip(),
            'stop_name': name.strip(),
            'added_at': entry['added_at'] if isinstance(entry.get('added_at'), str) else None,
            'sort_order': order if isinstance(order, int) and not isinstance(order, bool) else None,
            'colour': entry['colour'] if isinstance(entry.get('colour'), str) else None,
        })
    if not rows:
        return [], NO_USABLE_ROWS, 0
    return rows, None, skipped


# ── the model: the database side ──────────────────────────────────────────────

ORDER_BY = 'sort_order IS NULL, sort_order, added_at DESC'


def build_db(rows):
    db = sqlite3.connect(':memory:')
    db.row_factory = sqlite3.Row
    db.execute("""CREATE TABLE favourites (
                    stop_code TEXT PRIMARY KEY,
                    stop_name TEXT NOT NULL,
                    added_at  TEXT DEFAULT (datetime('now')),
                    sort_order INTEGER)""")
    for code, name, added, order in rows:
        db.execute("INSERT INTO favourites VALUES (?,?,?,?)",
                   (code, name, added, order))
    db.commit()
    return db


def import_profile(db, rows, replace):
    added = skipped = removed = 0
    if replace:
        removed = db.execute("SELECT COUNT(*) AS c FROM favourites").fetchone()['c']
        db.execute("DELETE FROM favourites")
        for i, r in enumerate(rows):
            _insert(db, r, i)
            added += 1
    else:
        have = {r['stop_code'] for r in db.execute("SELECT stop_code FROM favourites")}
        top = db.execute("SELECT MAX(sort_order) AS m FROM favourites").fetchone()['m']
        nxt = (top if top is not None else -1) + 1
        for r in rows:
            if r['stop_code'] in have:
                skipped += 1
                continue
            _insert(db, r, nxt)
            nxt += 1
            added += 1
    db.commit()
    return {'added': added, 'skipped': skipped, 'removed': removed}


def _insert(db, row, order):
    if isinstance(row.get('added_at'), str):
        db.execute("INSERT INTO favourites (stop_code, stop_name, sort_order, added_at)"
                   " VALUES (?,?,?,?)",
                   (row['stop_code'], row['stop_name'], order, row['added_at']))
    else:
        db.execute("INSERT INTO favourites (stop_code, stop_name, sort_order)"
                   " VALUES (?,?,?)", (row['stop_code'], row['stop_name'], order))


def listing(db):
    return [r['stop_code'] for r in db.execute(f"SELECT * FROM favourites ORDER BY {ORDER_BY}")]


# ── the cases ─────────────────────────────────────────────────────────────────

MINE = [('50001', 'Broadway @ Main', '2026-01-01 00:00:00', 0),
        ('50002', 'Granville @ 4th', '2026-01-02 00:00:00', 1),
        ('50003', 'Cambie @ 12th',   '2026-01-03 00:00:00', 2)]

THEIRS = [{'stop_code': '50003', 'stop_name': 'Cambie (their name)', 'sort_order': 0},
          {'stop_code': '60001', 'stop_name': 'Hastings @ Main',     'sort_order': 1},
          {'stop_code': '60002', 'stop_name': 'Commercial @ 1st',    'sort_order': 2}]

print("1. The file says what it is")
doc = json.loads(encode([dict(zip(FIELDS[:4], r)) for r in MINE]))
check("it declares the app", doc['app'], 'next_bus')
check("and the format version", doc['format_version'], 1)
check("every favourite carries every field",
      sorted(doc['favourites'][0].keys()), sorted(FIELDS))
check("colour is present and null — reserved for #331",
      doc['favourites'][0]['colour'], None)
check("the hand-set order is preserved in the file",
      [f['stop_code'] for f in doc['favourites']], ['50001', '50002', '50003'])

print("2. A round trip loses nothing")
rows, err, skipped = decode(encode([dict(zip(FIELDS[:4], r)) for r in MINE]))
check("no error", err, None)
check("nothing skipped", skipped, 0)
check("all three came back", [r['stop_code'] for r in rows],
      ['50001', '50002', '50003'])
check("with their positions", [r['sort_order'] for r in rows], [0, 1, 2])

print("3. Every refusal names itself — no bare nulls (the slice C lesson)")
check("a photo is not a profile", decode('\xff\xd8\xff\xe0not json')[1], NOT_JSON)
check("a bare array is not a profile", decode('[1,2,3]')[1], NOT_AN_OBJECT)
check("no version is a refusal",
      decode('{"favourites":[]}')[1], MISSING_VERSION)
check("a version from the future is a refusal",
      decode('{"format_version":2,"favourites":[]}')[1], FUTURE_VERSION)
check("no favourites key is a refusal",
      decode('{"format_version":1}')[1], MISSING_FAVOURITES)
check("an empty list is a refusal",
      decode('{"format_version":1,"favourites":[]}')[1], NO_USABLE_ROWS)
check("every refusal has a distinct message",
      len(set(MESSAGES.values())), len(MESSAGES))
check("and none of them is empty",
      all(m.strip() for m in MESSAGES.values()), True)
# A version STRING is not a version. "1" would otherwise sail through as valid.
check("a stringified version is not a version",
      decode('{"format_version":"1","favourites":[]}')[1], MISSING_VERSION)
check("nor is a boolean", decode('{"format_version":true,"favourites":[]}')[1],
      MISSING_VERSION)

print("4. A partly broken file imports as far as it can, and says how far")
raw = json.dumps({'format_version': 1, 'favourites': [
    {'stop_code': '70001', 'stop_name': 'Good stop'},
    {'stop_code': '', 'stop_name': 'No code'},
    {'stop_code': '70002', 'stop_name': '   '},
    {'stop_name': 'Missing code entirely'},
    'not even an object',
    {'stop_code': '70001', 'stop_name': 'Duplicate of the first'},
    {'stop_code': ' 70003 ', 'stop_name': ' Padded  ', 'unknown_field': 'ignored'},
]})
rows, err, skipped = decode(raw)
check("it does not refuse the whole file", err, None)
check("two rows survived", [r['stop_code'] for r in rows], ['70001', '70003'])
check("five were dropped, and the count is reported", skipped, 5)
check("whitespace is trimmed", rows[1]['stop_name'], 'Padded')
check("an unknown field is ignored, not fatal", 'unknown_field' in rows[1], False)
check("a duplicate keeps the FIRST mention", rows[0]['stop_name'], 'Good stop')
check("a missing sort_order becomes null", rows[0]['sort_order'], None)

print("5. An older file still reads")
check("version 1 is accepted",
      decode('{"format_version":1,"favourites":[{"stop_code":"1","stop_name":"a"}]}')[1],
      None)

print("6. Merge: additive, and it never moves what you arranged")
db = build_db(MINE)
out = import_profile(db, THEIRS, replace=False)
check("two added", out['added'], 2)
check("one skipped — already saved", out['skipped'], 1)
check("nothing removed", out['removed'], 0)
check("the new stops land at the BOTTOM, in file order",
      listing(db), ['50001', '50002', '50003', '60001', '60002'])
check("and the stop they also had keeps MY name",
      db.execute("SELECT stop_name FROM favourites WHERE stop_code='50003'").fetchone()[0],
      'Cambie @ 12th')
check("and MY position", db.execute(
    "SELECT sort_order FROM favourites WHERE stop_code='50003'").fetchone()[0], 2)

print("7. Replace: the file becomes the list")
db = build_db(MINE)
out = import_profile(db, THEIRS, replace=True)
check("three removed", out['removed'], 3)
check("three added", out['added'], 3)
check("none skipped", out['skipped'], 0)
check("the file's order is the new order",
      listing(db), ['50003', '60001', '60002'])
check("and their name wins, because nothing of mine survived",
      db.execute("SELECT stop_name FROM favourites WHERE stop_code='50003'").fetchone()[0],
      'Cambie (their name)')

print("8. Importing your own export is a no-op on merge")
# The case a person will actually hit: export, reinstall, import.
db = build_db(MINE)
rows, err, _ = decode(encode([dict(zip(FIELDS[:4], r)) for r in MINE]))
out = import_profile(db, rows, replace=False)
check("nothing added", out['added'], 0)
check("all three recognised as already here", out['skipped'], 3)
check("and the order is untouched", listing(db), ['50001', '50002', '50003'])

print("9. Importing into an empty phone — the restore path")
db = build_db([])
rows, _, _ = decode(encode([dict(zip(FIELDS[:4], r)) for r in MINE]))
out = import_profile(db, rows, replace=False)
check("everything arrives", out['added'], 3)
check("in the order it was exported", listing(db), ['50001', '50002', '50003'])
check("starting from position 0",
      [r['sort_order'] for r in db.execute("SELECT * FROM favourites ORDER BY sort_order")],
      [0, 1, 2])

print("10. A pre-slice-F row with no position does not break the merge")
db = build_db([('50001', 'Old row', '2026-01-01 00:00:00', None)])
out = import_profile(db, THEIRS, replace=False)
check("the import still works", out['added'], 3)
check("and no row is lost", len(listing(db)), 4)

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
