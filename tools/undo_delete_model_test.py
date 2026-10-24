#!/usr/bin/env python3
"""Undo-on-delete model check (#321).

WHAT THIS IS: a Python re-implementation of the favourites Undo — the batch
HomeScreen keeps while the Undo bar is up (_deleteFavourite, _showUndo,
_undoDeletes), the SnackBar close reasons that end or keep that batch, and
DbService.restoreFavourites against a model of the favourites table ordered
the way getFavourites orders it. Run on the NUC, which has no Dart SDK (#311).

The case it exists for is 10-11: Wil deleted two real favourites in a row while
clearing dummies. A bar per delete replaces the previous bar, and with it the
only way back for the first stop.

WHAT THIS IS NOT: a test of the shipped code. It is a second implementation and
it CAN drift from the Dart. The Dart is authoritative. If you change the delete,
the bar or the restore, change them here in the same commit or delete this file.

    python3 tools/undo_delete_model_test.py
    python3 tools/undo_delete_model_test.py --verify-red   # every break fails
"""

import os
import sys

BREAK = os.environ.get("BREAK", "")
BREAKS = ["hide-ends-batch", "timeout-keeps-batch", "restore-drops-order",
          "restore-replaces", "bar-persists"]

passed = failed = 0

def check(label, got, want):
    global passed, failed
    if got == want:
        passed += 1
        if not BREAK:
            print(f"  ok   {label}")
    else:
        failed += 1
        print(f"  FAIL {label}: got {got!r}, want {want!r}")


# ── model: the favourites table (DbService) ─────────────────────────────────

class Db:
    def __init__(self, rows):
        self.rows = {r["stop_code"]: dict(r) for r in rows}
        self.clock = 100

    def get_favourites(self):
        # ORDER BY sort_order IS NULL, sort_order, added_at DESC
        return sorted((dict(r) for r in self.rows.values()),
                      key=lambda r: (r["sort_order"] is None,
                                     r["sort_order"] or 0, -r["added_at"]))

    def remove(self, code):
        return 1 if self.rows.pop(code, None) else 0

    def add(self, code, name):              # addFavourite: a new star goes on top
        if code in self.rows:
            self.rows[code]["stop_name"] = name
            return
        orders = [r["sort_order"] for r in self.rows.values()
                  if r["sort_order"] is not None]
        self.clock += 1
        self.rows[code] = {"stop_code": code, "stop_name": name,
                           "added_at": self.clock,
                           "sort_order": (min(orders) if orders else 0) - 1}

    def restore(self, rows):
        n = 0
        for r in rows:
            r = dict(r)
            if BREAK == "restore-drops-order":
                r["sort_order"] = None
            if r["stop_code"] in self.rows and BREAK != "restore-replaces":
                continue                    # ConflictAlgorithm.ignore
            self.rows[r["stop_code"]] = r
            n += 1
        return n


# ── model: HomeScreen's batch and the Undo bar ──────────────────────────────

class Home:
    def __init__(self, db):
        self.db, self.batch, self.bar = db, [], None
        self.favs = db.get_favourites()

    def codes(self):
        return [f["stop_code"] for f in self.favs]

    def _close_bar(self, reason):
        if self.bar is None:
            return
        self.bar = None
        ends = reason not in ("hide", "action")
        if BREAK == "hide-ends-batch":
            ends = reason != "action"
        if BREAK == "timeout-keeps-batch":
            ends = False
        if ends:
            self.batch.clear()

    def delete(self, code):
        i = next(k for k, f in enumerate(self.favs) if f["stop_code"] == code)
        removed = self.favs.pop(i)
        if self.db.remove(code) == 0:
            self.favs.insert(i, removed)
            return
        self.batch.append(removed)
        self._close_bar("hide")             # hideCurrentSnackBar
        n = len(self.batch)
        self.bar = f"Deleted {self.batch[0]['stop_code']}" if n == 1 else f"Deleted {n} stops"

    def timeout(self):
        # Only because the bar sets persist: false. Current Flutter keeps a bar
        # that has an action up forever by default and ignores `duration` —
        # which is what the first device build did (10-24).
        if BREAK != "bar-persists":
            self._close_bar("timeout")

    def close_with_x(self):                 # showCloseIcon
        self._close_bar("dismiss")

    def swipe_bar_away(self):
        self._close_bar("swipe")

    def undo(self):
        if self.bar is None:
            return None                     # no bar, no button to press
        self._close_bar("action")
        rows, self.batch = list(self.batch), []
        restored = self.db.restore(rows)
        self.favs = self.db.get_favourites()
        return restored


# ── fixtures ────────────────────────────────────────────────────────────────

def fresh():
    # Already hand-ordered (dense 0..n), as after any drag.
    return Home(Db([
        {"stop_code": "50001", "stop_name": "Home",  "added_at": 1, "sort_order": 0},
        {"stop_code": "50002", "stop_name": "Work",  "added_at": 2, "sort_order": 1},
        {"stop_code": "50003", "stop_name": "Gym",   "added_at": 3, "sort_order": 2},
        {"stop_code": "50004", "stop_name": "Mum's", "added_at": 4, "sort_order": 3},
    ]))

ORIGINAL = ["50001", "50002", "50003", "50004"]


# ── checks ──────────────────────────────────────────────────────────────────

print("one delete")
h = fresh()
h.delete("50003")
check("bar names the stop", h.bar, "Deleted 50003")
check("gone from the list at once", h.codes(), ["50001", "50002", "50004"])
check("gone from the db at once (an app kill keeps the delete)",
      "50003" in h.db.rows, False)
check("Undo restores one", h.undo(), 1)
check("back in its own place, not on top", h.codes(), ORIGINAL)
check("the bar is gone after Undo", h.bar, None)

print("two in a row (10-11)")
h = fresh()
h.delete("50001")
h.delete("50004")
check("one bar counts both", h.bar, "Deleted 2 stops")
check("Undo restores both", h.undo(), 2)
check("both back where they were", h.codes(), ORIGINAL)

print("the bar ends the batch")
h = fresh()
h.delete("50001")
h.timeout()
h.delete("50002")
check("after a timeout the next bar counts only the new delete", h.bar, "Deleted 50002")
check("Undo then restores only that one", h.undo(), 1)
check("the timed-out delete stands", h.codes(), ["50002", "50003", "50004"])
h = fresh()
h.delete("50003")
h.swipe_bar_away()
check("swiping the bar away also makes the delete final", h.undo(), None)
check("…and the stop stays deleted", "50003" in h.codes(), False)
h = fresh()
h.delete("50003")
h.timeout()
check("the bar really does time out (persist: false)", h.bar, None)
h = fresh()
h.delete("50003")
h.close_with_x()
check("the close icon makes the delete final", h.undo(), None)

print("starred again before Undo")
h = fresh()
h.delete("50002")
h.db.add("50002", "Work (new name)")        # starred from the search results
h.favs = h.db.get_favourites()
check("Undo restores nothing", h.undo(), 0)
check("no duplicate", h.codes().count("50002"), 1)
check("the newer star is left alone", h.db.rows["50002"]["stop_name"], "Work (new name)")

print(f"\n{passed} passed, {failed} failed" + (f"  [BREAK={BREAK}]" if BREAK else ""))

if BREAK == "" and "--verify-red" in sys.argv:
    import subprocess
    silent = []
    for b in BREAKS:
        r = subprocess.run([sys.executable, __file__], env={**os.environ, "BREAK": b},
                           capture_output=True, text=True)
        status = "red" if r.returncode else "STILL GREEN"
        print(f"  break {b:20} {status}")
        if not r.returncode:
            silent.append(b)
    if silent:
        print(f"\nChecks that cannot fail prove nothing: {silent}")
        sys.exit(1)
    print(f"\nall {len(BREAKS)} breaks went red")

sys.exit(1 if failed else 0)
