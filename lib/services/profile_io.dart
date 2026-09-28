import 'dart:convert';

/// Reading and writing the portable profile file (#321 slice G, half 2).
///
/// The file exists for two jobs that pull in different directions: carrying a
/// profile to a new phone, and handing a few stops to somebody else. Half 1
/// already covers the first case for the common path — Android's Auto Backup
/// restores favourites and the API key on reinstall — so this file is the
/// answer for everything Auto Backup cannot reach: a different Google account,
/// a phone with backup switched off, or another person entirely.
///
/// **The API key is never written here (Wil, 2026-09-28).** An export is made
/// to be shared, and a key in a shared file is a key handed away. An opt-in
/// checkbox was considered and rejected: it is ticked once and regretted later,
/// and the failure is quiet — somebody else's traffic against your quota. The
/// key travels by Auto Backup, inside one Google account, which is where it
/// belongs. Nothing stops a later `format_version` adding it if a real need
/// turns up.
library;

/// Bumped only when a reader must behave differently, not when a field is
/// added. Readers ignore fields they do not know, so additions are free.
const int kProfileFormatVersion = 1;

/// Every key this version writes for a favourite.
///
/// `colour` is written as null and read back but not yet used — reserved for
/// [#331] (colour tags), deliberately, because settling the format now costs
/// ten minutes and settling it later costs a version bump plus a migration on
/// every install that has already exported. Same call as slice F going before
/// G so the profile carried `sort_order` from version one.
const List<String> kFavouriteFields = [
  'stop_code',
  'stop_name',
  'added_at',
  'sort_order',
  'colour',
];

/// Why a file could not be read.
///
/// Deliberately not a bare null. `_getFeed()` collapsed *no key*, *rejected
/// key*, *rate limited* and *service down* into one null, and the app then
/// rendered all four as a grey label that told nobody anything — a fault that
/// ran for weeks (#321 slice C). A file the user picked themselves, from
/// outside the app, has at least as many ways to be wrong, and every one of
/// them has to be sayable on screen.
enum ProfileReadError {
  notJson,
  notAnObject,
  missingVersion,
  futureVersion,
  missingFavourites,
  noUsableRows,
}

class ProfileReadResult {
  final List<Map<String, dynamic>> favourites;
  final ProfileReadError? error;

  /// Rows present in the file that were dropped for being unusable. A file can
  /// import successfully and still have lost something; saying so is the point.
  final int skippedRows;

  const ProfileReadResult.ok(this.favourites, {this.skippedRows = 0})
      : error = null;
  const ProfileReadResult.failed(this.error)
      : favourites = const [],
        skippedRows = 0;

  bool get isOk => error == null;
}

class ProfileIo {
  /// The exported document. Pretty-printed on purpose: this is a file a person
  /// may open, and two spaces cost nothing against a list of stops.
  static String encode(
    List<Map<String, dynamic>> favourites, {
    DateTime? now,
  }) {
    final doc = {
      'app': 'next_bus',
      'format_version': kProfileFormatVersion,
      'exported_at': (now ?? DateTime.now()).toIso8601String(),
      'favourites': [
        for (final row in favourites)
          {
            'stop_code': '${row['stop_code']}',
            'stop_name': '${row['stop_name']}',
            'added_at': row['added_at'],
            'sort_order': row['sort_order'],
            'colour': row['colour'],
          }
      ],
    };
    return const JsonEncoder.withIndent('  ').convert(doc);
  }

  /// Parse a file the user chose. Assumes nothing.
  ///
  /// A row survives only with a non-empty `stop_code` and `stop_name`;
  /// everything else is optional and anything unrecognised is ignored, so a
  /// file written by a later version still imports as far as it can rather
  /// than being refused outright.
  static ProfileReadResult decode(String raw) {
    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      return const ProfileReadResult.failed(ProfileReadError.notJson);
    }
    if (parsed is! Map) {
      return const ProfileReadResult.failed(ProfileReadError.notAnObject);
    }

    final version = parsed['format_version'];
    if (version is! int) {
      return const ProfileReadResult.failed(ProfileReadError.missingVersion);
    }
    if (version > kProfileFormatVersion) {
      return const ProfileReadResult.failed(ProfileReadError.futureVersion);
    }

    final list = parsed['favourites'];
    if (list is! List) {
      return const ProfileReadResult.failed(ProfileReadError.missingFavourites);
    }

    final rows = <Map<String, dynamic>>[];
    var skipped = 0;
    final seen = <String>{};
    for (final entry in list) {
      if (entry is! Map) {
        skipped++;
        continue;
      }
      final code = entry['stop_code'];
      final name = entry['stop_name'];
      if (code is! String || code.trim().isEmpty ||
          name is! String || name.trim().isEmpty) {
        skipped++;
        continue;
      }
      // A file listing the same stop twice is not an error, but it must not
      // become two rows against a primary key. First mention wins, matching
      // the merge rule below.
      if (!seen.add(code.trim())) {
        skipped++;
        continue;
      }
      final order = entry['sort_order'];
      rows.add({
        'stop_code': code.trim(),
        'stop_name': name.trim(),
        'added_at': entry['added_at'] is String ? entry['added_at'] : null,
        'sort_order': order is int ? order : null,
        'colour': entry['colour'] is String ? entry['colour'] : null,
      });
    }

    if (rows.isEmpty) {
      return const ProfileReadResult.failed(ProfileReadError.noUsableRows);
    }
    return ProfileReadResult.ok(rows, skippedRows: skipped);
  }

  /// What to tell the user. Every branch says something specific — a file that
  /// cannot be read must never produce a shrug.
  static String describe(ProfileReadError error) {
    switch (error) {
      case ProfileReadError.notJson:
        return "That file isn't a Next Bus profile — it couldn't be read as JSON.";
      case ProfileReadError.notAnObject:
        return "That file is JSON, but not a profile file.";
      case ProfileReadError.missingVersion:
        return "That file has no format version, so it isn't a Next Bus profile.";
      case ProfileReadError.futureVersion:
        return "That profile was made by a newer version of Next Bus. Update the app and try again.";
      case ProfileReadError.missingFavourites:
        return "That profile has no favourites list in it.";
      case ProfileReadError.noUsableRows:
        return "That profile has a favourites list, but no stop in it could be read.";
    }
  }

  /// The filename an export is offered under. Dated, because the first thing
  /// anyone wants to know about a backup file is how old it is.
  static String fileNameFor(DateTime when) {
    final y = when.year.toString().padLeft(4, '0');
    final m = when.month.toString().padLeft(2, '0');
    final d = when.day.toString().padLeft(2, '0');
    return 'next_bus_favourites_$y-$m-$d.json';
  }
}
