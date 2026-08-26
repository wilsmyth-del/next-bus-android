#!/usr/bin/env python3
"""Service-day model check for getScheduledArrivals (#321 slice A0).

WHAT THIS IS: a Python re-implementation of the SQL and the minutes-away
arithmetic in lib/services/db_service.dart, run against real sqlite3 so the
GTFS service-day model can be exercised on the NUC, which has no Dart SDK
(#311). Build and real testing happen on the laptop; this is what can be
checked on this side of that pipeline.

WHAT THIS IS NOT: a test of the shipped code. It is a second implementation
and it CAN drift from the Dart. The Dart is authoritative. If you change the
query or the arithmetic in db_service.dart, change it here in the same commit
or delete this file — a model check that has silently diverged is worse than
no model check at all.

    python3 tools/service_day_model_test.py
"""

import sqlite3, datetime

PAD = ("(CASE WHEN length(st.departure_time) = 7 THEN '0' || st.departure_time "
       "ELSE st.departure_time END)")
DAYS = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday']
HORIZON = 6*3600
MAX_SERVICE_DAY = 30*3600

def gtfs_time(secs):
    return "%02d:%02d:%02d" % (secs//3600, (secs%3600)//60, secs%60)

def collect(db, stop_id, service_day, offset, win_from, win_to, now_secs, include_past, into):
    from_s = max(0, win_from + offset)
    to_s = win_to + offset
    if from_s > MAX_SERVICE_DAY or to_s < 0:
        return False                      # skipped, no query issued
    date_str = service_day.strftime("%Y%m%d")
    dow = DAYS[service_day.weekday()]
    rows = db.execute(f"""
      SELECT st.trip_id, st.departure_time, r.route_short_name, t.headsign
      FROM stop_times st
      JOIN trips t ON st.trip_id = t.trip_id
      JOIN routes r ON t.route_id = r.route_id
      WHERE st.stop_id = ?
        AND {PAD} >= ?
        AND {PAD} <= ?
        AND (
          t.service_id IN (SELECT service_id FROM calendar
                           WHERE {dow} = 1 AND start_date <= ? AND end_date >= ?)
          OR t.service_id IN (SELECT service_id FROM calendar_dates
                              WHERE date = ? AND exception_type = 1)
        )
        AND t.service_id NOT IN (SELECT service_id FROM calendar_dates
                                 WHERE date = ? AND exception_type = 2)
      ORDER BY {PAD}
      LIMIT 30
    """, (stop_id, gtfs_time(from_s), gtfs_time(to_s),
          date_str, date_str, date_str, date_str)).fetchall()
    for trip_id, raw, route, headsign in rows:
        parts = raw.strip().split(':')
        h = int(parts[0]); m = int(parts[1]) if len(parts)>1 else 0
        s = int(parts[2]) if len(parts)>2 else 0
        disp = "%02d:%02d" % (h % 24, m)
        dep = h*3600 + m*60 + s
        mins = (dep - offset - now_secs)//60
        if not include_past and mins < 0: continue
        into.append({'trip_id':trip_id,'route':route,'headsign':headsign,
                     'arrival_time':disp,'minutes_away':mins,
                     'departure_secs':dep - offset})
    return True

def _within(db, stop_code, now, win_from, win_to, include_past=False):
    r = db.execute("SELECT stop_id FROM stops WHERE stop_code=? LIMIT 1",(stop_code,)).fetchone()
    if not r: return [], []
    stop_id = r[0]
    now_secs = now.hour*3600 + now.minute*60 + now.second
    today = datetime.date(now.year, now.month, now.day)
    out, queried = [], []
    for delta in (-1, 0, 1):
        day = today + datetime.timedelta(days=delta)
        off = -delta * 86400
        if collect(db, stop_id, day, off, win_from, win_to, now_secs, include_past, out):
            queried.append(off)
    out.sort(key=lambda x: x['departure_secs'])
    return out, queried

def scheduled_arrivals(db, stop_code, now):
    now_secs = now.hour*3600 + now.minute*60 + now.second
    out, queried = _within(db, stop_code, now, now_secs, now_secs + HORIZON)
    return out[:30], queried

def next_departure(db, stop_code, now, within=24*3600):
    now_secs = now.hour*3600 + now.minute*60 + now.second
    out, _ = _within(db, stop_code, now, now_secs, now_secs + within)
    return out[0] if out else None

def build():
    db = sqlite3.connect(":memory:")
    db.executescript("""
      CREATE TABLE stops(stop_code TEXT PRIMARY KEY, stop_id TEXT, stop_name TEXT DEFAULT "");
      CREATE TABLE routes(route_id TEXT PRIMARY KEY, route_short_name TEXT DEFAULT '');
      CREATE TABLE trips(trip_id TEXT PRIMARY KEY, route_id TEXT, service_id TEXT, headsign TEXT DEFAULT '');
      CREATE TABLE calendar(service_id TEXT PRIMARY KEY, monday INT DEFAULT 0, tuesday INT DEFAULT 0,
        wednesday INT DEFAULT 0, thursday INT DEFAULT 0, friday INT DEFAULT 0, saturday INT DEFAULT 0,
        sunday INT DEFAULT 0, start_date TEXT DEFAULT '', end_date TEXT DEFAULT '');
      CREATE TABLE calendar_dates(service_id TEXT, date TEXT, exception_type INT, PRIMARY KEY(service_id,date));
      CREATE TABLE stop_times(trip_id TEXT, stop_id TEXT, departure_time TEXT, stop_sequence INT,
        PRIMARY KEY(trip_id, stop_sequence));
      INSERT INTO stops VALUES('61234','S1','Main & 1st');
      INSERT INTO routes VALUES('R1','99'),('R2','014'),('R3','N19');
      -- WEEKDAY runs Mon-Fri, SUNDAY runs Sun only. Window covers Aug 2026.
      INSERT INTO calendar VALUES('WEEKDAY',1,1,1,1,1,0,0,'20260101','20261231');
      INSERT INTO calendar VALUES('SUNDAY', 0,0,0,0,0,0,1,'20260101','20261231');
    """)
    def trip(tid, rid, sid, head, time):
        db.execute("INSERT INTO trips VALUES(?,?,?,?)",(tid,rid,sid,head))
        db.execute("INSERT INTO stop_times VALUES(?,?,?,1)",(tid,'S1',time))
    return db, trip


import datetime

# 2026-08-25 is a Tuesday; 2026-08-24 Monday; 2026-08-23 Sunday.
TUE = lambda h,m: datetime.datetime(2026,8,25,h,m,0)
passed=failed=0
def check(name, got, want):
    global passed, failed
    if got == want: passed+=1; print(f"  PASS  {name}")
    else: failed+=1; print(f"  FAIL  {name}\n         got  {got}\n         want {want}")

print("1. After-midnight trip from YESTERDAY's service day now appears")
db,trip = build()
trip('t1','R3','WEEKDAY','Downtown','24:30:00')   # Mon service day -> 00:30 Tue
res,_ = scheduled_arrivals(db,'61234',TUE(0,15))
check("00:15 Tue sees Monday's 24:30 as 15m away",
      [(r['route'],r['arrival_time'],r['minutes_away']) for r in res],
      [('N19','00:30',15)])

print("2. The ~1470-minute render is gone (horizon excludes tomorrow's)")
db,trip = build()
trip('t1','R3','WEEKDAY','Downtown','24:30:00')   # Tue service day -> 00:30 WED
res,_ = scheduled_arrivals(db,'61234',TUE(0,31))  # Monday's 24:30 already past
check("00:31 Tue: nothing, not a 1439m phantom", res, [])

print("3. No phantom buses when the calendar matches nothing")
db,trip = build()
trip('s1','R1','SUNDAY','Sunday only','14:00:00')
res,_ = scheduled_arrivals(db,'61234',TUE(13,0))
check("Tuesday query never returns Sunday service", res, [])

print("4. Unpadded GTFS times still ordered and compared correctly")
db,trip = build()
trip('t1','R1','WEEKDAY','Early','7:15:00')
trip('t2','R2','WEEKDAY','Later','10:05:00')
res,_ = scheduled_arrivals(db,'61234',TUE(6,0))
check("06:00 sees 7:15 before 10:05",
      [(r['arrival_time'],r['minutes_away']) for r in res],
      [('07:15',75),('10:05',245)])

print("5. Two service days MERGE and re-sort by time, not by day")
db,trip = build()
trip('a','R3','WEEKDAY','Night owl','24:40:00')   # Mon -> 00:40 Tue
trip('b','R1','WEEKDAY','First bus','05:05:00')   # Tue morning
res,_ = scheduled_arrivals(db,'61234',TUE(0,20))
check("00:20: 00:40 (yesterday) sorts ahead of 05:05 (today)",
      [(r['arrival_time'],r['minutes_away']) for r in res],
      [('00:40',20),('05:05',285)])

print("6. calendar_dates removal (exception_type=2) still honoured")
db,trip = build()
trip('t1','R1','WEEKDAY','Holiday cancelled','14:00:00')
db.execute("INSERT INTO calendar_dates VALUES('WEEKDAY','20260825',2)")
res,_ = scheduled_arrivals(db,'61234',TUE(13,0))
check("service removed for today -> empty", res, [])

print("7. calendar_dates addition (exception_type=1) still honoured")
db,trip = build()
trip('t1','R1','SUNDAY','Special','14:00:00')
db.execute("INSERT INTO calendar_dates VALUES('SUNDAY','20260825',1)")
res,_ = scheduled_arrivals(db,'61234',TUE(13,0))
check("Sunday service added to Tuesday -> shows",
      [(r['arrival_time'],r['minutes_away']) for r in res], [('14:00',60)])

print("8. Yesterday's service day is skipped once the window passes 30:00")
db,trip = build()
trip('t1','R1','WEEKDAY','Afternoon','14:00:00')
res,q = scheduled_arrivals(db,'61234',TUE(13,0))
check("13:00 -> only today queried (offset list)", q, [0])
res,q = scheduled_arrivals(db,'61234',TUE(5,0))
check("05:00 -> both service days queried", q, [86400,0])

print("9. Horizon boundary is inclusive at exactly +6h, exclusive past it")
db,trip = build()
trip('t1','R1','WEEKDAY','On the line','19:00:00')
trip('t2','R2','WEEKDAY','Just past','19:00:01')
res,_ = scheduled_arrivals(db,'61234',TUE(13,0))
check("only the trip at exactly +6h survives",
      [(r['route'],r['minutes_away']) for r in res], [('99',360)])

print("10. Past departures are still dropped")
db,trip = build()
trip('t1','R1','WEEKDAY','Gone','12:59:00')
trip('t2','R2','WEEKDAY','Due','13:01:00')
res,_ = scheduled_arrivals(db,'61234',TUE(13,0))
check("only the future one", [(r['arrival_time'],r['minutes_away']) for r in res],
      [('13:01',1)])

print("11. Seconds no longer under-report (was h*3600+m*60 vs a now with seconds)")
db,trip = build()
trip('t1','R1','WEEKDAY','Due','13:02:30')
res,_ = scheduled_arrivals(db,'61234',datetime.datetime(2026,8,25,13,0,45))
check("13:00:45 -> 13:02:30 is 1m, not truncated wrong",
      [r['minutes_away'] for r in res], [1])

print("12. Unknown stop code returns empty, no crash")
db,trip = build()
res,_ = scheduled_arrivals(db,'99999',TUE(13,0))
check("unknown stop", res, [])

print("13. 25:xx (deep post-midnight) from yesterday resolves correctly")
db,trip = build()
trip('t1','R3','WEEKDAY','Last one','25:10:00')   # Mon -> 01:10 Tue
res,_ = scheduled_arrivals(db,'61234',TUE(1,0))
check("01:00 Tue sees Monday's 25:10 as 10m",
      [(r['arrival_time'],r['minutes_away']) for r in res], [('01:10',10)])

print("14. TOMORROW's service day is reachable when the horizon crosses midnight")
db,trip = build()
trip('t1','R1','WEEKDAY','First bus','05:14:00')   # Wed service day
res,_ = scheduled_arrivals(db,'61234',TUE(23,50))
check("23:50 Tue sees Wednesday's 05:14 at 324m",
      [(r['arrival_time'],r['minutes_away']) for r in res], [('05:14',324)])

print("15. ...and is NOT queried during the day, when it cannot contribute")
db,trip = build()
trip('t1','R1','WEEKDAY','Afternoon','14:00:00')
res,q = scheduled_arrivals(db,'61234',TUE(13,0))
check("13:00 -> today only", q, [0])
res,q = scheduled_arrivals(db,'61234',TUE(23,50))
check("23:50 -> today and tomorrow", q, [0,-86400])

print("16. getNextDeparture names the first bus back after a dead night")
db,trip = build()
# Infrequent suburban stop: last bus 00:40, nothing again until 07:30.
trip('t1','R3','WEEKDAY','Last one','24:40:00')    # Mon -> 00:40 Tue
trip('t2','R1','WEEKDAY','First bus','07:30:00')   # Tue morning, 6.5h out
res,_ = scheduled_arrivals(db,'61234',TUE(1,0))
check("01:00 -> nothing inside the 6h horizon", res, [])
nxt = next_departure(db,'61234',TUE(1,0))
check("...but next departure is 07:30, 390m out",
      (nxt['arrival_time'], nxt['minutes_away']), ('07:30',390))

print("17. getNextDeparture returns None when there is genuinely no data")
db,trip = build()                                   # no trips at all
res,_ = scheduled_arrivals(db,'61234',TUE(2,0))
nxt = next_departure(db,'61234',TUE(2,0))
check("empty schedule -> empty arrivals AND no next bus", (res, nxt), ([], None))

print("18. Late-night: next departure crosses into tomorrow's service day")
db,trip = build()
trip('t1','R1','WEEKDAY','First bus','06:00:00')
nxt = next_departure(db,'61234',TUE(23,55))
check("23:55 Tue -> Wednesday 06:00, 365m out",
      (nxt['arrival_time'], nxt['minutes_away']), ('06:00',365))

def arrivals_around(db, stop_code, now, target_secs, before=1, after=2):
    now_secs = now.hour*3600 + now.minute*60 + now.second
    rows,_ = _within(db, stop_code, now,
                     target_secs - 3*3600, target_secs + 6*3600, include_past=True)
    if not rows: return []
    times=[]
    for r in rows:
        t=r['departure_secs']
        if not times or times[-1]!=t: times.append(t)
    pivot = next((i for i,t in enumerate(times) if t > target_secs), None)
    first_after = len(times) if pivot is None else pivot
    lo=max(0, first_after-before); hi=min(len(times), first_after+after)
    chosen=set(times[lo:hi])
    return [r for r in rows if r['departure_secs'] in chosen]

HHMM = lambda h,m: h*3600+m*60

print("19. Time mode: 1 distinct time before the target, 2 after")
db,trip = build()
for i,t in enumerate(['13:30:00','13:45:00','14:10:00','14:25:00','14:50:00']):
    trip(f't{i}','R1','WEEKDAY','Downtown',t)
res = arrivals_around(db,'61234',TUE(12,0),HHMM(14,0))
check("noon planning for 14:00",
      [r['arrival_time'] for r in res], ['13:45','14:10','14:25'])

print("20. A chosen time brings ALL its routes (times, not trips)")
db,trip = build()
trip('a','R1','WEEKDAY','Downtown','13:45:00')
trip('b','R1','WEEKDAY','Downtown','14:00:00')
trip('c','R2','WEEKDAY','Metrotown','14:00:00')   # same time, different route
trip('d','R3','WEEKDAY','Night','14:20:00')
res = arrivals_around(db,'61234',TUE(12,0),HHMM(13,50))
check("14:00 contributes two rows, still 3 distinct times",
      [(r['route'],r['arrival_time']) for r in res],
      [('99','13:45'),('99','14:00'),('014','14:00'),('N19','14:20')])

print("21. First service of the day: no 'before' exists, two rows not broken")
db,trip = build()
trip('a','R1','WEEKDAY','First','05:00:00')
trip('b','R1','WEEKDAY','Second','05:30:00')
trip('c','R1','WEEKDAY','Third','06:00:00')
res = arrivals_around(db,'61234',TUE(4,0),HHMM(4,30))
check("target before first bus -> 2 rows, no crash",
      [r['arrival_time'] for r in res], ['05:00','05:30'])

print("22. The 'before' row can already have departed, and says so")
db,trip = build()
trip('a','R1','WEEKDAY','Missed','13:52:00')
trip('b','R1','WEEKDAY','Catchable','14:05:00')
trip('c','R1','WEEKDAY','Later','14:30:00')
res = arrivals_around(db,'61234',TUE(13,55),HHMM(14,0))
check("at 13:55, the 13:52 row carries negative minutes_away",
      [(r['arrival_time'], r['minutes_away'] < 0) for r in res],
      [('13:52',True),('14:05',False),('14:30',False)])

print("23. Planning past the last bus falls back, does not go blank")
db,trip = build()
trip('a','R1','WEEKDAY','Last','22:40:00')
trip('b','R1','WEEKDAY','Second last','22:10:00')
res = arrivals_around(db,'61234',TUE(12,0),HHMM(23,30))
# One row, not two: "1 before" is still 1 when the target sits past the last bus.
# Planning at noon for 23:30 correctly answers "the closest is 22:40".
check("target after last bus -> the one before it, alone",
      [r['arrival_time'] for r in res], ['22:40'])

print("24. Time mode spans midnight via the next service day")
db,trip = build()
trip('a','R3','WEEKDAY','Night','23:50:00')
trip('b','R3','WEEKDAY','Late night','24:20:00')   # Tue service day -> 00:20 Wed
res = arrivals_around(db,'61234',TUE(20,0),HHMM(23,55))
check("planning 23:55 sees the 24:20 as 00:20",
      [r['arrival_time'] for r in res], ['23:50','00:20'])

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
