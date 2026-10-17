#!/usr/bin/env python3
"""GTFS-RT parser skip model check (#321 D).

WHAT THIS IS: a Python re-implementation of lib/services/gtfs_rt_parser.dart —
the _Pb reader and the five nested parse loops — run against a feed built here
field by field, so the expected answer is known exactly. The feed carries every
field TransLink actually sends that the parser does NOT read (entity id,
is_deleted, start_date, schedule_relationship, direction_id, stop_sequence,
departure, the vehicle descriptor, a negative delay), because skipping is where
the 10-17 bug lived: `_i += varint()` read _i before varint() advanced it, so
every skipped length-delimited field landed short and the parse drifted.

WHAT THIS IS NOT: a test of the shipped code. It is a second implementation and
it CAN drift from the Dart. The Dart is authoritative. If you change the reader
or the parse loops, change them here in the same commit or delete this file.

    python3 tools/gtfs_rt_skip_model_test.py               # built feed
    python3 tools/gtfs_rt_skip_model_test.py feed.pb       # + a real feed
    python3 tools/gtfs_rt_skip_model_test.py --verify-red  # every break fails

A real feed has no known answer, so for one the check is only "parses without
error and finds a plausible number of trips" — the built feed is the real test.
"""

import os
import sys

BREAK = os.environ.get("BREAK", "")
BREAKS = ["compound-skip", "skip-fixed64-short", "no-negative-delay"]

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


# ── model: _Pb ──────────────────────────────────────────────────────────────

class Pb:
    def __init__(self, b):
        self.b, self.i = b, 0

    def has_more(self):
        return self.i < len(self.b)

    def varint(self):
        v = s = 0
        while self.i < len(self.b):
            x = self.b[self.i]; self.i += 1
            v |= (x & 0x7F) << s
            if not x & 0x80:
                break
            s += 7
        return v

    def bytes(self):
        n = self.varint()
        if self.i + n > len(self.b):  # Uint8List.sublistView throws RangeError
            raise IndexError(f"RangeError (end): {self.i + n} > {len(self.b)}")
        d = self.b[self.i:self.i + n]; self.i += n
        return d

    def str(self):
        return self.bytes().decode()

    def skip(self, w):
        if w == 0:
            while self.i < len(self.b):
                x = self.b[self.i]; self.i += 1
                if not x & 0x80:
                    break
        elif w == 1:
            self.i += 4 if BREAK == "skip-fixed64-short" else 8
        elif w == 2:
            if BREAK == "compound-skip":
                start = self.i            # the old Dart: _i read first
                self.i = start + self.varint()
            else:
                n = self.varint(); self.i += n
        elif w == 5:
            self.i += 4


# ── model: GtfsRtParser ─────────────────────────────────────────────────────

def loop(b, handlers):
    r = Pb(b)
    while r.has_more():
        t = r.varint(); f, w = t >> 3, t & 7
        h = handlers.get((f, w))
        if h:
            h(r)
        else:
            r.skip(w)

def parse(feed):
    out = []
    def ste(b):
        ev = {"delay": 0, "time": 0}
        def delay(r):
            v = r.varint()
            if BREAK != "no-negative-delay":
                v = v & 0xFFFFFFFF
                v = v - (1 << 32) if v & 0x80000000 else v   # toSigned(32)
            ev["delay"] = v
        loop(b, {(1, 0): delay, (2, 0): lambda r: ev.__setitem__("time", r.varint())})
        return ev["time"], ev["delay"]
    def stu(b, stops):
        s = {"stop": "", "time": 0, "delay": 0}
        def arr(r):
            s["time"], s["delay"] = ste(r.bytes())
        loop(b, {(2, 2): arr, (4, 2): lambda r: s.__setitem__("stop", r.str())})
        if s["stop"] and s["time"]:
            stops.append((s["stop"], s["time"], s["delay"]))
    def td(b, trip):
        loop(b, {(1, 2): lambda r: trip.__setitem__("trip", r.str()),
                 (5, 2): lambda r: trip.__setitem__("route", r.str())})
    def tu(b):
        trip = {"trip": "", "route": ""}; stops = []
        loop(b, {(1, 2): lambda r: td(r.bytes(), trip),
                 (2, 2): lambda r: stu(r.bytes(), stops)})
        for stop, time, delay in stops:
            out.append((trip["trip"], trip["route"], stop, time, delay))
    loop(feed, {(2, 2): lambda r: loop(r.bytes(), {(3, 2): lambda q: tu(q.bytes())})})
    return out


# ── a feed built field by field ─────────────────────────────────────────────

def vi(n):
    n &= (1 << 64) - 1                      # negative int32 -> 10-byte varint
    out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)

def fld(f, w, payload):
    tag = vi(f << 3 | w)
    if w == 0: return tag + vi(payload)
    if w == 2: return tag + vi(len(payload)) + payload
    return tag + payload                     # w 1 / 5: payload is raw bytes

def s(x): return x.encode()

def stop_time_update(seq, stop, time, delay):
    event = fld(1, 0, delay) + fld(2, 0, time) + fld(3, 0, 0)    # + uncertainty
    return (fld(1, 0, seq) + fld(2, 2, event) + fld(3, 2, event)  # arrival, departure
            + fld(4, 2, s(stop)) + fld(5, 0, 0))

def trip_update(trip, route, stops, long_vehicle=False):
    desc = (fld(1, 2, s(trip)) + fld(3, 2, s("20261017")) + fld(4, 0, 0)
            + (fld(5, 2, s(route)) if route else b"") + fld(6, 0, 1))
    # A fixed64 FIRST, whose back half reads as a StopTimeUpdate tag if only
    # four bytes are skipped (zeros would re-sync harmlessly and prove nothing).
    body = fld(9, 1, b"\x00\x00\x00\x00\x12\x40\x00\x00") + fld(1, 2, desc)
    for st in stops:
        body += fld(2, 2, stop_time_update(*st))
    label = "x" * (200 if long_vehicle else 6)   # 2-byte length prefix
    body += fld(3, 2, fld(1, 2, s("V1")) + fld(2, 2, s(label)))
    body += fld(4, 0, 1760700000) + fld(10, 5, b"\x00" * 4)
    return body

def entity(eid, tu):
    return fld(1, 2, s(eid)) + fld(2, 0, 0) + fld(3, 2, tu)

T = 1760700000
TRIPS = [
    ("15440505", "6612", [(1, "1001", T + 60, 0), (2, "1002", T + 120, -45)]),
    ("15440506", "",     [(1, "1003", T + 300, 90)]),
    ("15440507", "6613", [(1, "1001", T + 600, -300)], True),
]
header = fld(1, 2, s("2.0")) + fld(2, 0, 0) + fld(3, 0, T)
feed = fld(1, 2, header)
for i, t in enumerate(TRIPS):
    feed += fld(2, 2, entity(str(9000 + i), trip_update(*t)))

WANT = [(trip, route, stop, time, delay)
        for trip, route, stops, *_ in TRIPS for _, stop, time, delay in stops]


# ── checks ──────────────────────────────────────────────────────────────────

print("built feed")
try:
    got = parse(feed)
except IndexError as e:
    got = f"crashed: {e}"
check("every stop of every trip, exactly, in order", got, WANT)
check("negative delay survives (int32 sign)",
      [r[4] for r in got] if isinstance(got, list) else got, [0, -45, 90, -300])
check("a trip with no route_id still parses (route empty)",
      [r[1] for r in got if r[0] == "15440506"] if isinstance(got, list) else got, [""])

for path in [a for a in sys.argv[1:] if not a.startswith("--")]:
    print(f"real feed: {path}")
    raw = open(path, "rb").read()
    try:
        rows = parse(raw); err = None
    except IndexError as e:
        rows, err = [], str(e)
    check("parses without error", err, None)
    trips = len({r[0] for r in rows})
    check(f"finds trips ({trips})", trips > 0, True)

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
