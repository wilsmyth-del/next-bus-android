#!/usr/bin/env python3
"""Download-gate model check (#321 slice B2).

WHAT THIS IS: a Python re-implementation of the pure decision logic slice B2
added — ConnectivityGate.classify/needsConfirmation from
lib/services/connectivity_gate.dart, GtfsService.checkForUpdate's three-way
outcome from lib/services/gtfs_service.dart, and _formatUpdatedAt from
lib/screens/settings_screen.dart. Run on the NUC, which has no Dart SDK (#311).

WHAT THIS IS NOT: a test of the shipped code. It is a second implementation and
it CAN drift from the Dart. The Dart is authoritative. If you change the
classification, the update check or the stamp formatting, change it here in the
same commit or delete this file — a model check that has silently diverged is
worse than no model check at all.

    python3 tools/download_gate_model_test.py
"""

from datetime import datetime, timedelta

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

# ConnectivityResult values as of connectivity_plus 7.3.1.
WIFI, MOBILE, NONE = 'wifi', 'mobile', 'none'
ETHERNET, VPN, BLUETOOTH, OTHER, SATELLITE = (
    'ethernet', 'vpn', 'bluetooth', 'other', 'satellite')

def classify(results):
    if not results:
        return 'unknown'
    if WIFI in results:
        return 'wifi'
    if MOBILE in results:
        return 'cellular'
    if len(results) == 1 and results[0] == NONE:
        return 'none'
    return 'unknown'

def needs_confirmation(kind):
    return kind != 'wifi'

def check_for_update(feed_date, stored_date):
    """GtfsService.checkForUpdate — feed_date None means findLatestFeed failed."""
    if feed_date is None:
        return ('noFeed', None)
    if stored_date == feed_date:
        return ('current', feed_date)
    return ('available', feed_date)

def format_updated_at(iso, now):
    if iso is None:
        return 'unknown (before this version)'
    try:
        when = datetime.fromisoformat(iso)
    except ValueError:
        return 'unknown'
    age = now - when
    mins, hours, days = age.total_seconds() / 60, age.total_seconds() / 3600, age.days
    if mins < 1:
        return 'just now'
    if hours < 1:
        return f'{int(mins)} min ago'
    if hours < 24:
        return f'{int(hours)}h ago'
    if days == 1:
        return 'yesterday'
    if days < 30:
        return f'{days} days ago'
    return when.strftime('%Y-%m-%d')

# ── the checks ────────────────────────────────────────────────────────────────

print("1. Wi-Fi is the only free pass (Wil, 2026-09-20)")
check("wifi alone",            classify([WIFI]), 'wifi')
check("mobile alone",          classify([MOBILE]), 'cellular')
check("nothing reported",      classify([]), 'unknown')
check("none alone",            classify([NONE]), 'none')
check("ethernet",              classify([ETHERNET]), 'unknown')
check("vpn alone",             classify([VPN]), 'unknown')
check("bluetooth",             classify([BLUETOOTH]), 'unknown')
check("other",                 classify([OTHER]), 'unknown')
check("satellite (added 7.1)", classify([SATELLITE]), 'unknown')

print("2. Android can report several at once — Wi-Fi wins, because it is used")
check("wifi + mobile", classify([MOBILE, WIFI]), 'wifi')
check("wifi + vpn",    classify([WIFI, VPN]), 'wifi')
check("mobile + vpn",  classify([MOBILE, VPN]), 'cellular')
check("vpn + ethernet (neither recognised)", classify([VPN, ETHERNET]), 'unknown')

print("3. Only Wi-Fi skips the dialog")
for kind, want in [('wifi', False), ('cellular', True),
                   ('none', True), ('unknown', True)]:
    check(f"{kind} -> confirm={want}", needs_confirmation(kind), want)

print("4. An unknown enum value cannot become 'free data'")
# The one that matters: upstream adds a value we have never heard of.
check("a future interface confirms rather than downloads",
      needs_confirmation(classify(['starlink_v2'])), True)

print("5. checkForUpdate distinguishes the three real outcomes")
check("no feed found",     check_for_update(None, '2026-09-10'), ('noFeed', None))
check("feed matches store", check_for_update('2026-09-10', '2026-09-10'),
      ('current', '2026-09-10'))
check("feed is newer",      check_for_update('2026-09-17', '2026-09-10'),
      ('available', '2026-09-17'))
check("nothing stored yet", check_for_update('2026-09-17', None),
      ('available', '2026-09-17'))

print("6. The entrance inconsistency is gone — one answer, not two")
# Before B2: Settings compared dates and short-circuited; the home path did not
# and would re-download a feed it already had. Both now read the same result.
feed, stored = '2026-09-10', '2026-09-10'
settings_would_download = check_for_update(feed, stored)[0] == 'available'
home_would_download = check_for_update(feed, stored)[0] == 'available'
check("neither entrance downloads an identical feed",
      (settings_would_download, home_would_download), (False, False))

print("7. The update stamp reads in the right tense")
now = datetime(2026, 9, 20, 12, 0, 0)
check("no stamp at all (pre-B2 database)",
      format_updated_at(None, now), 'unknown (before this version)')
check("unparseable stamp", format_updated_at('not-a-date', now), 'unknown')
check("30 seconds",  format_updated_at((now - timedelta(seconds=30)).isoformat(), now), 'just now')
check("20 minutes",  format_updated_at((now - timedelta(minutes=20)).isoformat(), now), '20 min ago')
check("5 hours",     format_updated_at((now - timedelta(hours=5)).isoformat(), now), '5h ago')
check("yesterday",   format_updated_at((now - timedelta(days=1)).isoformat(), now), 'yesterday')
check("12 days",     format_updated_at((now - timedelta(days=12)).isoformat(), now), '12 days ago')
check("older than a month falls back to a date",
      format_updated_at((now - timedelta(days=45)).isoformat(), now), '2026-08-06')

print("8. A stale feed date and a failing download are told apart")
# The point of the second stamp: the feed date can sit still for legitimate
# reasons, so it cannot answer "has this phone been able to update?".
check("current schedule, updated recently",
      format_updated_at((now - timedelta(hours=2)).isoformat(), now), '2h ago')
check("same feed date, but nothing has landed in six weeks",
      format_updated_at((now - timedelta(days=42)).isoformat(), now), '2026-08-09')

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
