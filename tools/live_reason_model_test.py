#!/usr/bin/env python3
"""Schedule-only reason model check (#321 slice C).

WHAT THIS IS: a Python re-implementation of what slice C added —
TranslinkService.classifyStatus, the way getArrivals turns a feed fetch or a
thrown exception into a LiveReason (and when it keeps the HTTP status), and
ArrivalsScreen.liveNotice plus the rule for when the notice line shows at all,
and the no-key notice's "don't show again" (#321, agreed 10-17), which must
hide that one notice and nothing else — in particular it must not switch Lite
on, or a key added later would silently go unused.
Run on the NUC, which has no Dart SDK (#311).

WHAT THIS IS NOT: a test of the shipped code. It is a second implementation and
it CAN drift from the Dart. The Dart is authoritative. If you change the
classification, the reason flow or the notice wording, change it here in the
same commit or delete this file — a model check that has silently diverged is
worse than no model check at all.

    python3 tools/live_reason_model_test.py

Pass BREAK=<name> to run against a deliberately broken model and confirm the
checks go red; every break listed in BREAKS must fail at least one check.
"""

import os
import sys

BREAK = os.environ.get("BREAK", "")
BREAKS = [
    "403-not-rejected", "5xx-boundary", "keep-200-status", "timeout-as-offline",
    "clientexc-as-error", "lite-shows", "time-mode-shows", "live-shows",
    "no-raw-code", "fixable-too-wide",
    "dismiss-ignored", "dismiss-hides-rejected", "dismiss-sets-lite",
]

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


# ── model: TranslinkService.classifyStatus ──────────────────────────────────

def classify_status(code):
    if code == 200:
        return None
    if code == 401 or (code == 403 and BREAK != "403-not-rejected"):
        return "rejected"
    if code == 429:
        return "rateLimited"
    hi = 600 if BREAK == "5xx-boundary" else 599
    if 500 <= code <= hi:
        return "serviceDown"
    return "error"


# ── model: getArrivals' reason flow ─────────────────────────────────────────
# A fetch is one of: ("lite",), ("nokey",), ("http", code, stop_found),
# ("raise", exception_name). Returns (mode, why, status).

EXC = {
    "TimeoutException": "timedOut",
    "SocketException": "offline",
    "ClientException": "offline",
}

def get_arrivals(fetch):
    if fetch[0] == "lite":
        return ("scheduled", "lite", None)
    if fetch[0] == "nokey":
        return ("scheduled", "noKey", None)
    if fetch[0] == "raise":
        name = fetch[1]
        if BREAK == "timeout-as-offline" and name == "TimeoutException":
            return ("scheduled", "offline", None)
        if BREAK == "clientexc-as-error" and name == "ClientException":
            return ("scheduled", "error", None)
        return ("scheduled", EXC.get(name, "error"), None)
    _, code, stop_found = fetch
    feed_why = classify_status(code)
    if feed_why is None and stop_found:
        return ("live", None, None)
    why = feed_why or "error"
    keep = BREAK == "keep-200-status" or feed_why is not None
    return ("scheduled", why, code if keep else None)


# ── model: ArrivalsScreen.liveNotice + _buildLiveNotice ─────────────────────

def live_notice(why, status, dismissed=False):
    code = "" if status is None or BREAK == "no-raw-code" else f" ({status})"
    if why is None or (why == "lite" and BREAK != "lite-shows"):
        return None
    hidden = ("noKey", "rejected") if BREAK == "dismiss-hides-rejected" else ("noKey",)
    if dismissed and why in hidden and BREAK != "dismiss-ignored":
        return None
    return {
        "lite": "Schedule only — lite mode",
        "noKey": "Schedule only — no API key set",
        "rejected": f"Schedule only — API key rejected{code}",
        "rateLimited": f"Schedule only — TransLink rate limit{code}, try again shortly",
        "serviceDown": f"Schedule only — TransLink live service is down{code}",
        "timedOut": "Schedule only — TransLink didn't answer in time",
        "offline": "Schedule only — no connection",
        "error": ("Schedule only — live data couldn't be read" if status is None
                  else f"Schedule only — unexpected response from TransLink{code}"),
    }[why]

def notice_shown(mode, why, status, planning=False, loading=False, error=False,
                 dismissed=False):
    if loading or error or (planning and BREAK != "time-mode-shows"):
        return None
    if mode != "scheduled" and BREAK != "live-shows":
        return None
    return live_notice(why, status, dismissed)

def fixable(why):
    if BREAK == "fixable-too-wide":
        return why in ("noKey", "rejected", "rateLimited")
    return why in ("noKey", "rejected")

def screen(fetch, **kw):
    mode, why, status = get_arrivals(fetch)
    return notice_shown(mode, why, status, **kw), fixable(why)


# ── model: the stored settings, and what a lookup does with them ────────────
# ApiKeyService's prefs: the key, lite_mode, no_key_notice_dismissed.

def fresh_install():
    return {"key": None, "lite": False, "dismissed": False}

def dismiss_no_key_notice(prefs):
    prefs["dismissed"] = True
    if BREAK == "dismiss-sets-lite":
        prefs["lite"] = True

def lookup(prefs, key_status=200):
    """The notice a Now lookup shows for these prefs, and the mode it ends in."""
    if prefs["lite"]:
        fetch = ("lite",)
    elif prefs["key"] is None:
        fetch = ("nokey",)
    else:
        fetch = ("http", key_status, True)
    mode, why, status = get_arrivals(fetch)
    return notice_shown(mode, why, status, dismissed=prefs["dismissed"]), mode


# ── checks ──────────────────────────────────────────────────────────────────

print("classifyStatus")
for code, want in [(200, None), (401, "rejected"), (403, "rejected"),
                   (429, "rateLimited"), (500, "serviceDown"), (503, "serviceDown"),
                   (599, "serviceDown"), (600, "error"), (404, "error"),
                   (302, "error"), (418, "error")]:
    check(f"{code} -> {want}", classify_status(code), want)

print("reason flow")
check("live feed, stop found -> live, no reason",
      get_arrivals(("http", 200, True)), ("live", None, None))
check("live feed, stop missing -> error with NO status (200 is not a reason)",
      get_arrivals(("http", 200, False)), ("scheduled", "error", None))
check("403 keeps its status", get_arrivals(("http", 403, True)),
      ("scheduled", "rejected", 403))
check("503 keeps its status", get_arrivals(("http", 503, True)),
      ("scheduled", "serviceDown", 503))
check("404 -> error with raw status", get_arrivals(("http", 404, True)),
      ("scheduled", "error", 404))
check("timeout -> timedOut, NOT offline (decision b)",
      get_arrivals(("raise", "TimeoutException")), ("scheduled", "timedOut", None))
check("socket -> offline", get_arrivals(("raise", "SocketException")),
      ("scheduled", "offline", None))
check("http ClientException -> offline",
      get_arrivals(("raise", "ClientException")), ("scheduled", "offline", None))
check("anything else thrown -> error",
      get_arrivals(("raise", "FormatException")), ("scheduled", "error", None))
check("no key", get_arrivals(("nokey",)), ("scheduled", "noKey", None))
check("lite", get_arrivals(("lite",)), ("scheduled", "lite", None))

print("notice line")
check("live: nothing shown", screen(("http", 200, True)), (None, False))
check("lite: nothing shown — the user's own choice",
      screen(("lite",)), (None, False))
check("no key: shown, with Settings",
      screen(("nokey",)), ("Schedule only — no API key set", True))
check("rejected: shown with code, with Settings", screen(("http", 401, True)),
      ("Schedule only — API key rejected (401)", True))
check("rate limited: code, no Settings", screen(("http", 429, True)),
      ("Schedule only — TransLink rate limit (429), try again shortly", False))
check("down: code, no Settings", screen(("http", 502, True)),
      ("Schedule only — TransLink live service is down (502)", False))
check("timed out differs from offline", screen(("raise", "TimeoutException")),
      ("Schedule only — TransLink didn't answer in time", False))
check("offline", screen(("raise", "SocketException")),
      ("Schedule only — no connection", False))
check("odd code reported raw, not guessed", screen(("http", 404, True)),
      ("Schedule only — unexpected response from TransLink (404)", False))
check("stop missing from a good feed: no fake 200", screen(("http", 200, False)),
      ("Schedule only — live data couldn't be read", False))
check("Time mode: never shown — schedule-only is the design there",
      screen(("nokey",), planning=True)[0], None)
check("live data never gets a notice, even if a reason leaks through",
      notice_shown("live", "offline", None), None)
check("hidden while loading", screen(("nokey",), loading=True)[0], None)
check("hidden behind an error screen", screen(("nokey",), error=True)[0], None)

print("don't show again")
p = fresh_install()
check("fresh install: the no-key notice shows",
      lookup(p), ("Schedule only — no API key set", "scheduled"))
dismiss_no_key_notice(p)
check("dismissed: gone on the next stop", lookup(p), (None, "scheduled"))
check("dismissing does NOT switch Lite on", p["lite"], False)
p["key"] = "k"
check("key added after dismissing: live straight away", lookup(p), (None, "live"))
check("dismissed, then the key is rejected: that notice still shows",
      lookup(p, key_status=403), ("Schedule only — API key rejected (403)", "scheduled"))
check("dismissed hides nothing else: offline still shows",
      notice_shown("scheduled", "offline", None, dismissed=True),
      "Schedule only — no connection")

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
