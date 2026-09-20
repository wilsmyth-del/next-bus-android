#!/usr/bin/env python3
"""Favourites-ordering model check (#321 slice F).

WHAT THIS IS: a Python re-implementation of the three things slice F changed in
lib/services/db_service.dart and lib/screens/home_screen.dart — the v5
migration's seeding of sort_order, the read ordering, addFavourite's
position-preserving upsert — plus the onReorder index arithmetic from
home_screen. Run against real sqlite3 so the ordering can be exercised on the
NUC, which has no Dart SDK (#311).

WHAT THIS IS NOT: a test of the shipped code. It is a second implementation and
it CAN drift from the Dart. The Dart is authoritative. If you change the
ordering, the migration or the reorder handler, change it here in the same
commit or delete this file — a model check that has silently diverged is worse
than no model check at all.

    python3 tools/reorder_model_test.py
"""

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

# ── the model ─────────────────────────────────────────────────────────────────

ORDER_BY = 'sort_order IS NULL, sort_order, added_at DESC'

def build_v4():
    """A pre-slice-F database: favourites with no sort_order column."""
    db = sqlite3.connect(':memory:')
    db.row_factory = sqlite3.Row
    db.execute("""CREATE TABLE favourites (
                    stop_code TEXT PRIMARY KEY,
                    stop_name TEXT NOT NULL,
                    added_at  TEXT DEFAULT (datetime('now')))""")
    return db

def star_v4(db, code, added_at):
    db.execute("INSERT INTO favourites (stop_code, stop_name, added_at) VALUES (?,?,?)",
               (code, f"Stop {code}", added_at))

def migrate_to_v5(db):
    """onUpgrade's `if (oldV < 5)` block."""
    db.execute("ALTER TABLE favourites ADD COLUMN sort_order INTEGER")
    rows = db.execute("SELECT stop_code FROM favourites ORDER BY added_at DESC").fetchall()
    for i, r in enumerate(rows):
        db.execute("UPDATE favourites SET sort_order = ? WHERE stop_code = ?",
                   (i, r['stop_code']))

def get_favourites(db):
    """getFavourites() — returns stop codes, top first."""
    return [r['stop_code'] for r in
            db.execute(f"SELECT stop_code FROM favourites ORDER BY {ORDER_BY}")]

def add_favourite(db, code, name, added_at='2026-01-01 00:00:00'):
    """addFavourite() — update in place if present, else insert on top."""
    existing = db.execute("SELECT stop_code FROM favourites WHERE stop_code = ?",
                          (code,)).fetchone()
    if existing:
        db.execute("UPDATE favourites SET stop_name = ? WHERE stop_code = ?", (name, code))
        return
    m = db.execute("SELECT MIN(sort_order) AS m FROM favourites").fetchone()['m']
    db.execute("INSERT INTO favourites (stop_code, stop_name, added_at, sort_order) "
               "VALUES (?,?,?,?)", (code, name, added_at, (m if m is not None else 0) - 1))

def reorder_favourites(db, codes_top_first):
    """reorderFavourites() — dense renumber from 0. Returns rows updated."""
    updated = 0
    for i, code in enumerate(codes_top_first):
        cur = db.execute("UPDATE favourites SET sort_order = ? WHERE stop_code = ?",
                         (i, code))
        updated += cur.rowcount
    return updated

def on_reorder(order, old_index, new_index):
    """home_screen's _reorderFavourites list arithmetic, local list only."""
    if new_index > old_index:
        new_index -= 1
    if new_index == old_index:
        return list(order), False
    out = list(order)
    out.insert(new_index, out.pop(old_index))
    return out, True

# ── the checks ────────────────────────────────────────────────────────────────

print("1. The v5 migration moves nothing on screen")
db = build_v4()
star_v4(db, 'A', '2026-01-01 00:00:00')   # oldest
star_v4(db, 'B', '2026-01-02 00:00:00')
star_v4(db, 'C', '2026-01-03 00:00:00')   # newest -> displayed first pre-F
before = [r['stop_code'] for r in
          db.execute("SELECT stop_code FROM favourites ORDER BY added_at DESC")]
migrate_to_v5(db)
check("order identical across the upgrade", get_favourites(db), before)
check("and it is the newest-first order F inherited", before, ['C', 'B', 'A'])

print("2. A newly starred stop lands on top (Wil, 2026-09-20)")
add_favourite(db, 'D', 'Stop D')
check("new stop is first", get_favourites(db), ['D', 'C', 'B', 'A'])
add_favourite(db, 'E', 'Stop E')
check("and the next one above it", get_favourites(db), ['E', 'D', 'C', 'B', 'A'])

print("3. Re-starring a stop does not move it")
db = build_v4()
for i, c in enumerate('ABC'):
    star_v4(db, c, f'2026-01-0{i+1} 00:00:00')
migrate_to_v5(db)
reorder_favourites(db, ['B', 'A', 'C'])          # hand-ordered
add_favourite(db, 'A', 'Renamed A')              # the old replace-insert bug
check("A keeps its middle position", get_favourites(db), ['B', 'A', 'C'])
check("but the name is refreshed",
      db.execute("SELECT stop_name FROM favourites WHERE stop_code='A'").fetchone()[0],
      'Renamed A')

print("4. Reorder persists, densely, and survives a reload")
db = build_v4()
for i, c in enumerate('ABCD'):
    star_v4(db, c, f'2026-01-0{i+1} 00:00:00')
migrate_to_v5(db)                                 # D C B A
moved = reorder_favourites(db, ['A', 'B', 'C', 'D'])
check("every row reported as written", moved, 4)
check("reload returns the new order", get_favourites(db), ['A', 'B', 'C', 'D'])
check("and the values are dense from 0",
      [r['sort_order'] for r in
       db.execute(f"SELECT sort_order FROM favourites ORDER BY {ORDER_BY}")],
      [0, 1, 2, 3])

print("5. Reorder tidies the negatives new stars leave behind")
add_favourite(db, 'E', 'Stop E')
check("E sits at -1 before any drag",
      db.execute("SELECT sort_order FROM favourites WHERE stop_code='E'").fetchone()[0], -1)
reorder_favourites(db, get_favourites(db))
check("a drop renumbers from 0 with no negatives",
      [r['sort_order'] for r in
       db.execute(f"SELECT sort_order FROM favourites ORDER BY {ORDER_BY}")],
      [0, 1, 2, 3, 4])

print("6. A row that escaped the migration sorts last, not first")
db = build_v4()
for i, c in enumerate('AB'):
    star_v4(db, c, f'2026-01-0{i+1} 00:00:00')
migrate_to_v5(db)
db.execute("INSERT INTO favourites (stop_code, stop_name, added_at, sort_order) "
           "VALUES ('Z','Stop Z','2026-06-01 00:00:00',NULL)")
check("NULL sort_order goes to the bottom", get_favourites(db), ['B', 'A', 'Z'])

print("7. onReorder index arithmetic")
L = ['A', 'B', 'C', 'D']
check("drag top to bottom (0 -> 4)", on_reorder(L, 0, 4)[0], ['B', 'C', 'D', 'A'])
check("drag bottom to top (3 -> 0)", on_reorder(L, 3, 0)[0], ['D', 'A', 'B', 'C'])
check("drag down one (0 -> 2)", on_reorder(L, 0, 2)[0], ['B', 'A', 'C', 'D'])
check("drag up one (2 -> 1)", on_reorder(L, 2, 1)[0], ['A', 'C', 'B', 'D'])
check("a no-op drop is detected (1 -> 2)", on_reorder(L, 1, 2), (L, False))
check("a no-op drop the other way (1 -> 1)", on_reorder(L, 1, 1), (L, False))

print("8. The local move and the persisted order agree")
db = build_v4()
for i, c in enumerate('ABCD'):
    star_v4(db, c, f'2026-01-0{i+1} 00:00:00')
migrate_to_v5(db)                                 # D C B A
local, changed = on_reorder(get_favourites(db), 0, 4)   # D to the bottom
check("the drag changed something", changed, True)
reorder_favourites(db, local)
check("optimistic list matches what the DB returns", get_favourites(db), local)
check("which is the expected order", local, ['C', 'B', 'A', 'D'])

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
