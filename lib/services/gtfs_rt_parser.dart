import 'dart:convert';
import 'dart:typed_data';

// Minimal GTFS-RT protobuf parser.
// Only extracts the fields needed for next-bus display — no generated code required.
// Proto reference: https://gtfs.org/realtime/proto/

class GtfsRtArrival {
  final String tripId;
  final String routeId;
  final String stopId;
  final int arrivalTimestamp; // unix seconds (predicted)
  final int delaySeconds;

  const GtfsRtArrival({
    required this.tripId,
    required this.routeId,
    required this.stopId,
    required this.arrivalTimestamp,
    required this.delaySeconds,
  });
}

class GtfsRtParser {
  static List<GtfsRtArrival> parse(Uint8List bytes) {
    final r = _Pb(bytes);
    final tripUpdates = <_TripUpdate>[];

    while (r.hasMore) {
      final tag = r.varint();
      final f = tag >> 3;
      final w = tag & 7;
      if (f == 2 && w == 2) {
        _parseEntity(r.bytes(), tripUpdates);
      } else {
        r.skip(w);
      }
    }

    final result = <GtfsRtArrival>[];
    for (final tu in tripUpdates) {
      for (final s in tu.stops) {
        result.add(GtfsRtArrival(
          tripId:           tu.tripId,
          routeId:          tu.routeId,
          stopId:           s.stopId,
          arrivalTimestamp: s.time,
          delaySeconds:     s.delay,
        ));
      }
    }
    return result;
  }

  // FeedEntity: field 3 = TripUpdate. Field 4 (VehiclePosition) is skipped:
  // TransLink's trip-updates feed carries none, so the old "has GPS" check
  // could never be true and every realtime row showed as Approx (#321 C).
  static void _parseEntity(Uint8List b, List<_TripUpdate> tus) {
    final r = _Pb(b);
    while (r.hasMore) {
      final tag = r.varint();
      final f = tag >> 3; final w = tag & 7;
      if (f == 3 && w == 2) {
        tus.add(_parseTripUpdate(r.bytes()));
      } else {
        r.skip(w);
      }
    }
  }

  // TripUpdate: field 1 = TripDescriptor, field 2 = StopTimeUpdate (repeated)
  static _TripUpdate _parseTripUpdate(Uint8List b) {
    final r = _Pb(b);
    var tripId = ''; var routeId = '';
    final stops = <_Stop>[];
    while (r.hasMore) {
      final tag = r.varint();
      final f = tag >> 3; final w = tag & 7;
      if (f == 1 && w == 2) {
        (tripId, routeId) = _parseTripDescriptor(r.bytes());
      } else if (f == 2 && w == 2) {
        final s = _parseStopTimeUpdate(r.bytes());
        if (s != null) stops.add(s);
      } else {
        r.skip(w);
      }
    }
    return _TripUpdate(tripId, routeId, stops);
  }

  // TripDescriptor: field 1 = trip_id, field 5 = route_id
  static (String, String) _parseTripDescriptor(Uint8List b) {
    final r = _Pb(b);
    var tripId = ''; var routeId = '';
    while (r.hasMore) {
      final tag = r.varint();
      final f = tag >> 3; final w = tag & 7;
      if (f == 1 && w == 2)      { tripId  = r.str(); }
      else if (f == 5 && w == 2) { routeId = r.str(); }
      else                       { r.skip(w); }
    }
    return (tripId, routeId);
  }

  // StopTimeUpdate: field 2 = arrival (StopTimeEvent), field 4 = stop_id
  static _Stop? _parseStopTimeUpdate(Uint8List b) {
    final r = _Pb(b);
    var stopId = ''; var time = 0; var delay = 0;
    while (r.hasMore) {
      final tag = r.varint();
      final f = tag >> 3; final w = tag & 7;
      if (f == 2 && w == 2)      { (time, delay) = _parseStopTimeEvent(r.bytes()); }
      else if (f == 4 && w == 2) { stopId = r.str(); }
      else                       { r.skip(w); }
    }
    if (stopId.isEmpty || time == 0) return null;
    return _Stop(stopId, time, delay);
  }

  // StopTimeEvent: field 1 = delay (int32), field 2 = time (int64 unix seconds)
  static (int, int) _parseStopTimeEvent(Uint8List b) {
    final r = _Pb(b);
    var delay = 0; var time = 0;
    while (r.hasMore) {
      final tag = r.varint();
      final f = tag >> 3; final w = tag & 7;
      if (f == 1 && w == 0)      { delay = r.varint().toSigned(32); }
      else if (f == 2 && w == 0) { time  = r.varint(); }
      else                       { r.skip(w); }
    }
    return (time, delay);
  }
}

// ---------------------------------------------------------------------------
// Internal data classes

class _TripUpdate {
  final String tripId, routeId;
  final List<_Stop> stops;
  const _TripUpdate(this.tripId, this.routeId, this.stops);
}

class _Stop {
  final String stopId;
  final int time, delay;
  const _Stop(this.stopId, this.time, this.delay);
}

// ---------------------------------------------------------------------------
// Minimal protobuf binary reader

class _Pb {
  final Uint8List _b;
  int _i = 0;
  _Pb(this._b);

  bool get hasMore => _i < _b.length;

  int varint() {
    int v = 0, s = 0;
    while (_i < _b.length) {
      final b = _b[_i++];
      v |= (b & 0x7F) << s;
      if ((b & 0x80) == 0) break;
      s += 7;
    }
    return v;
  }

  Uint8List bytes() {
    final len = varint();
    final d = Uint8List.sublistView(_b, _i, _i + len);
    _i += len;
    return d;
  }

  String str() => utf8.decode(bytes());

  void skip(int w) {
    switch (w) {
      case 0: while (_i < _b.length && (_b[_i++] & 0x80) != 0) {} break;
      case 1: _i += 8; break;
      case 2: _i += varint(); break;
      case 5: _i += 4; break;
    }
  }
}
