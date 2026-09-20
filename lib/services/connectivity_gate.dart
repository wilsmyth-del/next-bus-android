import 'package:connectivity_plus/connectivity_plus.dart';

/// What kind of connection a schedule download would use.
///
/// Deliberately coarser than [ConnectivityResult]: the only question this app
/// asks is "can we pull ~15 MB without asking first?", and the answer is yes on
/// Wi-Fi and no on everything else.
enum NetworkKind { wifi, cellular, none, unknown }

/// The Wi-Fi gate on GTFS downloads (#321 slice B2).
///
/// A schedule download is ~15 MB and blocks the app for minutes, so it is never
/// allowed to start over metered or unidentified connections without an
/// explicit confirmation that names the size.
class ConnectivityGate {
  static Future<NetworkKind> current() async {
    try {
      final results = await Connectivity()
          .checkConnectivity()
          .timeout(const Duration(seconds: 3));
      return classify(results);
    } catch (_) {
      // A platform channel that throws, or a plugin that hangs, must not be
      // able to wave a download through. Unknown needs confirmation, so the
      // failure mode here is one extra dialog — never a surprise 15 MB.
      return NetworkKind.unknown;
    }
  }

  /// Pure so the classification can be exercised without a device.
  ///
  /// Android can report several connections at once, so this is written as a
  /// priority order rather than a switch. Wi-Fi wins when present because that
  /// is the interface the download will actually use. `satellite` (added in
  /// connectivity_plus 7.1.0), `ethernet`, `vpn`, `bluetooth` and `other` all
  /// fall through to [NetworkKind.unknown] on purpose — an unrecognised
  /// interface is treated as one worth asking about, and a future enum value
  /// added upstream cannot silently become "free data".
  static NetworkKind classify(List<ConnectivityResult> results) {
    if (results.isEmpty) return NetworkKind.unknown;
    if (results.contains(ConnectivityResult.wifi)) return NetworkKind.wifi;
    if (results.contains(ConnectivityResult.mobile)) return NetworkKind.cellular;
    if (results.length == 1 && results.first == ConnectivityResult.none) {
      return NetworkKind.none;
    }
    return NetworkKind.unknown;
  }

  /// Wi-Fi is the only free pass (Wil, 2026-09-20).
  ///
  /// [NetworkKind.none] is included, which looks odd until you note the order
  /// of operations: the gate is only consulted *after* `findLatestFeed()` has
  /// already fetched something over the network. If a feed was found, a
  /// connection exists, so `none` means the plugin is wrong rather than that the
  /// phone is offline — and a wrong plugin is exactly when you want the dialog.
  static bool needsConfirmation(NetworkKind kind) => kind != NetworkKind.wifi;
}
