#!/usr/bin/env python3
"""Feed-date candidate model check (#321).

WHAT THIS IS: a Python re-implementation of `_candidates()` in
lib/services/gtfs_service.dart — the order of dates the app asks TransLink
about when looking for a newer schedule.

WHY IT EXISTS: the old order tried four recent **Thursdays** first, on the
belief that TransLink publishes weekly on a Thursday. Measured against the live
server on 2026-09-28, that is false — every Thursday checked is a 404 and every
Friday a 200. The daily fallback had been carrying the feature the whole time,
so nothing ever looked broken. A wrong assumption that a fallback conceals is
exactly the kind that survives for months, and the only thing that finds it is
a check that states the assumption out loud.

WHAT THIS IS NOT: a test of the shipped code. It is a second implementation and
it CAN drift from the Dart. The Dart is authoritative. If you change the scan,
change this in the same commit or delete it.

    python3 tools/feed_candidates_model_test.py
"""

from datetime import date, timedelta

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

DAILY_SCAN_DAYS = 14
LONG_STOP_WEEKS = 3
FRIDAY = 5          # DateTime.friday
THURSDAY = 4


def dart_date(y, m, d):
    """DateTime(y, m, d) with an out-of-range day, as Dart normalises it.

    Dart rolls the calendar fields over, so day 0 is the last day of the
    previous month and day -5 is five days before that. Equivalent to the
    first of the month plus (d - 1) days, which is what this does — and which
    is also why the Dart uses the constructor rather than Duration arithmetic:
    a Duration is absolute and a DST change makes it land on the wrong date.
    """
    return date(y, m, 1) + timedelta(days=d - 1)


def candidates(today, daily_days=None):
    """The current scan: newest-first daily, then a weekday long-stop.

    `daily_days` is injectable only so the dedup guard can be tested; the Dart
    has it as a constant.
    """
    daily_days = DAILY_SCAN_DAYS if daily_days is None else daily_days
    seen, out = set(), []

    def push(d):
        if d not in seen:
            seen.add(d)
            out.append(d)

    for i in range(daily_days):
        push(dart_date(today.year, today.month, today.day - i))

    days_since = (today.isoweekday() - FRIDAY) % 7
    for w in range(2, 2 + LONG_STOP_WEEKS):
        push(dart_date(today.year, today.month, today.day - (days_since + w * 7)))
    return out


def old_candidates(today):
    """The scan as it shipped: four Thursdays first, then 14 days."""
    seen, out = set(), []

    def push(d):
        if d not in seen:
            seen.add(d)
            out.append(d)

    days_since_thu = (today.isoweekday() - THURSDAY) % 7
    for i in range(4):
        push(today - timedelta(days=days_since_thu + i * 7))
    for i in range(DAILY_SCAN_DAYS):
        push(today - timedelta(days=i))
    return out


# Measured against gtfs-static.translink.ca on 2026-09-28. Fridays only.
PUBLISHED = {date(2026, 8, 28), date(2026, 9, 4), date(2026, 9, 11),
             date(2026, 9, 18), date(2026, 9, 25)}


def requests_until_hit(order):
    for n, d in enumerate(order, start=1):
        if d in PUBLISHED:
            return n
    return None


# ── the cases ─────────────────────────────────────────────────────────────────

TODAY = date(2026, 9, 28)   # the Monday this was found

print("1. Today's real case: the feed published Friday 2026-09-25")
new = candidates(TODAY)
check("the scan finds it", requests_until_hit(new), 4)
check("on the 4th date tried", new[3], date(2026, 9, 25))
check("having tried only newer days first", new[:3],
      [date(2026, 9, 28), date(2026, 9, 27), date(2026, 9, 26)])

print("2. What the old order did with the same day")
old = old_candidates(TODAY)
check("it also found it eventually", requests_until_hit(old), 8)
check("after four Thursdays that cannot exist",
      old[:4], [date(2026, 9, 24), date(2026, 9, 17),
                date(2026, 9, 10), date(2026, 9, 3)])
check("none of which is a published date",
      [d for d in old[:4] if d in PUBLISHED], [])
# Four wasted round trips on every check, every time, for the life of the app.
check("the new order halves the requests", requests_until_hit(new) < requests_until_hit(old), True)

print("3. It cannot be wrong about the publication day, from any starting day")
# PUBLISHED above is what the live server actually served, and it necessarily
# stops at the day it was measured. Asserting against it from a later weekday
# models a feed eight or nine days old, which a weekly cadence never produces —
# so this case uses a synthetic world that keeps publishing instead. (The first
# version of this check asserted against PUBLISHED and failed on Sat and Sun
# for exactly that reason; the code was right and the world was wrong.)
def weekly_fridays(around, weeks=10):
    """A world where a feed publishes every Friday, without fail."""
    start = around - timedelta(days=weeks * 7)
    start += timedelta(days=(FRIDAY - start.isoweekday()) % 7)
    return {start + timedelta(days=7 * i) for i in range(weeks * 2)}

for offset in range(7):
    d = TODAY + timedelta(days=offset)
    world = weekly_fridays(d)
    newest = max(p for p in world if p <= d)
    # Eight, not seven: a weekly feed can be up to seven days old, so in the
    # worst case the newest one sits at index 7.
    check(f"{d.strftime('%a')} finds a feed {(d - newest).days}d old within 8 tries",
          newest in candidates(d)[:8], True)

print("3b. And an abnormally old feed is still reached by the long-stop")
# Nothing published for three weeks. The daily scan finds nothing at all, which
# is the only situation where the weekday guess is load-bearing — and where
# being wrong costs requests rather than correctness.
stale = date(2026, 9, 4)
order = candidates(TODAY)
check("a 24-day-old feed is still in the list", stale in order, True)
check("but only after the whole daily scan has missed",
      order.index(stale) >= DAILY_SCAN_DAYS, True)

print("4. Ordering and duplicates")
order = candidates(TODAY)
daily = order[:DAILY_SCAN_DAYS]
check("the daily scan is strictly newest-first",
      all(daily[i] > daily[i + 1] for i in range(len(daily) - 1)), True)
check("no date is asked for twice", len(order), len(set(order)))
# Being honest about what that just proved: nothing. With the shipped constants
# the long-stop starts at least 14 days back and the daily scan ends at 13, so
# the two windows cannot overlap and the dedup guard is unreachable. The check
# above passes whether the guard exists or not — found by deleting the guard on
# purpose and watching all 31 cases still pass. The guard is kept because it is
# free and because widening the daily scan would make it load-bearing again,
# which is the case actually worth testing:
wide = candidates(TODAY, daily_days=21)
check("a widened daily scan would overlap the long-stop",
      any((TODAY - d).days >= 14 for d in
          [dart_date(TODAY.year, TODAY.month, TODAY.day - i) for i in range(21)]), True)
check("and the guard still yields each date once",
      len(wide), len(set(wide)))
check("reach is at least 28 days", (TODAY - min(order)).days >= 28, True)
# The long-stop counts back from Friday, one day later in the week than the
# Thursday it replaced, so matching the old week count would have silently cut
# the reach by a day on every weekday. This is the check that caught it.
for offset in range(7):
    d = TODAY + timedelta(days=offset)
    check(f"{d.strftime('%a')}: reach is not worse than the old scan",
          (d - min(candidates(d))).days >= (d - min(old_candidates(d))).days, True)

print("5. Calendar arithmetic rolls back over month and year ends")
check("3 Jan scans into the previous December",
      dart_date(2026, 1, 3 - 5), date(2025, 12, 29))
jan = candidates(date(2026, 1, 3))
check("and the scan crosses the year cleanly",
      jan[:5], [date(2026, 1, 3), date(2026, 1, 2), date(2026, 1, 1),
                date(2025, 12, 31), date(2025, 12, 30)])
check("1 Mar 2028 scans back into a leap February",
      dart_date(2028, 3, 1 - 1), date(2028, 2, 29))

print("6. A DST change must not skip or repeat a date")
# Honest limit: Python's `date` has no clocks and no DST, so this CANNOT
# reproduce the Dart hazard it guards against. It pins the property the Dart
# must hold — consecutive calendar days across the boundary — and nothing more.
# The Dart's protection is using the DateTime(y, m, d - n) constructor instead
# of subtract(Duration(days: n)); that choice is unverifiable from the NUC.
# Vancouver falls back on 2026-11-01. Duration-based arithmetic lands at 23:00
# the previous day across that boundary and names the wrong date; the calendar
# constructor is unaffected. The property to hold is simply that the scan
# produces consecutive calendar days.
nov = candidates(date(2026, 11, 3))
days = nov[:DAILY_SCAN_DAYS]
check("the days either side of the change are consecutive",
      all((days[i] - days[i + 1]).days == 1 for i in range(len(days) - 1)), True)
check("and 2026-11-01 is present exactly once",
      days.count(date(2026, 11, 1)), 1)

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
