import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/api_key_service.dart';
import '../services/connectivity_gate.dart';
import '../services/translink_service.dart';
import '../services/db_service.dart';
import '../services/gtfs_service.dart';
import '../services/profile_io.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

// Hoisted out of the widget tree rather than repeated as literals, which is
// what the rest of the app already does (home_screen.dart:20-22). Ten copies of
// a hex value is ten places to miss when one changes.
//
// File-level rather than static on the State class: _Step at the bottom of this
// file is a separate widget and uses the accent too, so a private static would
// be out of scope exactly where it is needed.
const Color _surface = Color(0xFF1A1D27);
const Color _accent = Color(0xFF60A5FA);

class _SettingsScreenState extends State<SettingsScreen> {
  final _controller = TextEditingController();
  bool _loading = true;
  bool _saved = false;
  bool _hasKey = false;
  bool _liteMode = false;
  bool _refreshingGtfs = false;
  String? _gtfsDate;
  String? _gtfsUpdatedAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final key = await ApiKeyService.getKey();
    final liteMode = await ApiKeyService.getLiteMode();
    final gtfsDate = await DbService.getGtfsDate();
    final gtfsUpdatedAt = await DbService.getGtfsUpdatedAt();
    if (mounted) {
      setState(() {
        _controller.text = key ?? '';
        _hasKey = key != null;
        _liteMode = liteMode;
        _gtfsDate = gtfsDate;
        _gtfsUpdatedAt = gtfsUpdatedAt;
        _loading = false;
      });
    }
  }

  /// The only path in the app that downloads a schedule (#321 slice B2).
  ///
  /// Order matters: find the feed, decide whether it is even news, and only then
  /// ask about data. Asking "download 15 MB over mobile?" before knowing there is
  /// anything to download would be a dialog that sometimes means nothing.
  Future<void> _refreshGtfs() async {
    setState(() => _refreshingGtfs = true);
    try {
      final check = await GtfsService.checkForUpdate();

      if (check.status == UpdateStatus.noFeed) {
        _say('No schedule feed found — check your connection and try again');
        return;
      }
      if (check.status == UpdateStatus.current) {
        _say('Already up to date (${check.feed!.date})');
        return;
      }

      final feed = check.feed!;
      final kind = await ConnectivityGate.current();
      // Guarded because the gate is an await away from a dialog: leave Settings
      // while the connectivity check is in flight and showDialog would be
      // handed a dead context. Not hypothetical on the slow path this sits on.
      if (!mounted) return;
      if (ConnectivityGate.needsConfirmation(kind)) {
        final proceed = await _confirmMeteredDownload(kind);
        if (proceed != true) return;
      }

      await GtfsService.downloadAndBuild(feed: feed, onStatus: (_) {});
      final updatedAt = await DbService.getGtfsUpdatedAt();
      if (mounted) {
        setState(() {
          _gtfsDate = feed.date;
          _gtfsUpdatedAt = updatedAt;
        });
        _say('Updated to ${feed.date}');
      }
    } catch (e) {
      _say('Update failed: $e');
    } finally {
      if (mounted) setState(() => _refreshingGtfs = false);
    }
  }

  /// Reads the update stamp in the tense a person would use.
  ///
  /// "Unknown" is the honest answer for a database that predates slice B2: the
  /// stamp is only written by [DbService.commitImport], so a schedule imported
  /// before this release genuinely has no recorded date and saying "never" would
  /// be a lie about a download that did happen.
  static String _formatUpdatedAt(String? iso) {
    if (iso == null) return 'unknown (before this version)';
    final when = DateTime.tryParse(iso);
    if (when == null) return 'unknown';
    final age = DateTime.now().difference(when);
    if (age.inMinutes < 1) return 'just now';
    if (age.inHours < 1) return '${age.inMinutes} min ago';
    if (age.inHours < 24) return '${age.inHours}h ago';
    if (age.inDays == 1) return 'yesterday';
    if (age.inDays < 30) return '${age.inDays} days ago';
    return '${when.year}-${when.month.toString().padLeft(2, '0')}-'
        '${when.day.toString().padLeft(2, '0')}';
  }

  // ---------------------------------------------------------------------------
  // Profile export / import — slice G half 2
  //
  // Half 1 already carries favourites and the API key through a reinstall via
  // Auto Backup, so this is for everything that cannot reach: a different
  // Google account, a phone with backup off, or handing a few stops to someone
  // else. The key is deliberately NOT in the file (Wil, 2026-09-28) — an export
  // is made to be shared.
  // ---------------------------------------------------------------------------

  bool _busyProfile = false;

  Future<void> _exportProfile() async {
    setState(() => _busyProfile = true);
    try {
      final favourites = await DbService.getFavourites();
      if (favourites.isEmpty) {
        _say('Nothing to export yet — star a stop first.');
        return;
      }
      final now = DateTime.now();
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${ProfileIo.fileNameFor(now)}');
      await file.writeAsString(ProfileIo.encode(favourites, now: now));

      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'application/json')],
        fileNameOverrides: [ProfileIo.fileNameFor(now)],
        subject: 'Next Bus favourites',
        text: '${favourites.length} saved stops from Next Bus.',
      ));
    } catch (e) {
      _say('Export failed: $e');
    } finally {
      if (mounted) setState(() => _busyProfile = false);
    }
  }

  Future<void> _importProfile() async {
    setState(() => _busyProfile = true);
    try {
      final picked = await openFile(acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Next Bus profile',
          extensions: ['json'],
          // Android filters ACTION_OPEN_DOCUMENT by MIME type, not extension,
          // so an extensions-only group offers the user nothing to pick.
          mimeTypes: ['application/json'],
        ),
      ]);
      if (picked == null) return; // cancelled — say nothing, nothing happened

      final result = ProfileIo.decode(await picked.readAsString());
      if (!result.isOk) {
        _say(ProfileIo.describe(result.error!));
        return;
      }
      if (!mounted) return;

      final replace = await _confirmImportMode(result);
      if (replace == null) return; // cancelled at the dialog
      if (!mounted) return;

      final outcome =
          await DbService.importProfile(result.favourites, replace: replace);
      _say(_describeOutcome(outcome, result.skippedRows));
    } catch (e) {
      _say('Import failed: $e');
    } finally {
      if (mounted) setState(() => _busyProfile = false);
    }
  }

  /// true = replace, false = merge, null = cancelled.
  ///
  /// Asked rather than assumed, because the file serves two jobs that want
  /// opposite answers: restoring your own phone wants replace, and a file a
  /// friend sent you must not silently delete your stops. Merge is the default
  /// and the only non-destructive choice, so a mis-tap costs nothing.
  Future<bool?> _confirmImportMode(ProfileReadResult result) {
    final n = result.favourites.length;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _surface,
        title: const Text('Import profile',
            style: TextStyle(color: Colors.white)),
        content: Text(
          '$n saved ${n == 1 ? 'stop' : 'stops'} in this file.'
          '${result.skippedRows > 0 ? '\n\n${result.skippedRows} entries in the file could not be read and will be ignored.' : ''}'
          '\n\nMerge keeps everything you already have. '
          'Replace deletes your current favourites first.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Replace mine',
                style: TextStyle(color: Colors.redAccent)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            style: FilledButton.styleFrom(
                backgroundColor: _accent, foregroundColor: Colors.black),
            child: const Text('Merge'),
          ),
        ],
      ),
    );
  }

  /// Counts, in a sentence. An import that quietly drops half a file while
  /// reporting success is the failure this whole slice is written against.
  static String _describeOutcome(ProfileImportOutcome o, int unreadable) {
    final parts = <String>[];
    if (o.removed > 0) parts.add('${o.removed} replaced');
    parts.add('${o.added} added');
    if (o.skipped > 0) parts.add('${o.skipped} already saved');
    if (unreadable > 0) parts.add('$unreadable unreadable');
    return 'Imported: ${parts.join(', ')}.';
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Names the cost before spending it. The size and the duration are both in
  /// the body because either one alone understates it — 15 MB sounds cheap, and
  /// "a few minutes" sounds like a spinner rather than an app that is unusable
  /// while it runs.
  Future<bool?> _confirmMeteredDownload(NetworkKind kind) {
    final line = kind == NetworkKind.cellular
        ? 'You are on mobile data.'
        : 'This device is not on Wi-Fi.';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: const Text('Download schedule data?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          '$line\n\n'
          'The transit schedule is about 15 MB and takes a few minutes. '
          'Next Bus cannot look up stops while it downloads.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download',
                style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    await ApiKeyService.setKey(_controller.text);
    TranslinkService.clearCache();
    if (!mounted) return;
    setState(() {
      _saved = true;
      _hasKey = _controller.text.trim().isNotEmpty;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('API key saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _surface,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _accent))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Data usage',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: _surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SwitchListTile(
                    title: const Text('Lite mode', style: TextStyle(color: Colors.white)),
                    subtitle: const Text(
                      'Block GTFS downloads and live arrivals on mobile data',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    value: _liteMode,
                    activeThumbColor: _accent,
                    onChanged: (val) async {
                      await ApiKeyService.setLiteMode(val);
                      TranslinkService.clearCache();
                      if (mounted) setState(() => _liteMode = val);
                    },
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'TransLink API Key',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Live arrivals come directly from TransLink. Without a key, '
                  'the app still works using the static schedule.',
                  style: TextStyle(color: Colors.white54),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _hasKey ? const Color(0xFF1B3A2A) : const Color(0xFF3A1B1B),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _hasKey ? Icons.check_circle : Icons.error_outline,
                        size: 16,
                        color: _hasKey ? const Color(0xFF4ADE80) : Colors.orangeAccent,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _hasKey ? 'Key saved — live arrivals enabled' : 'No key saved — using static schedule',
                        style: TextStyle(
                          color: _hasKey ? const Color(0xFF4ADE80) : Colors.orangeAccent,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _controller,
                  onChanged: (_) => setState(() => _saved = false),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Paste your TransLink API key',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: _surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    minimumSize: const Size(double.infinity, 0),
                  ),
                  child: Text(_saved ? 'Saved' : 'Save'),
                ),
                const SizedBox(height: 32),
                const Text(
                  'Transit data',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  _gtfsDate != null
                      ? 'Current schedule data: $_gtfsDate'
                      : 'No schedule data downloaded yet',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
                if (_gtfsDate != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Last updated: ${_formatUpdatedAt(_gtfsUpdatedAt)}',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: (_refreshingGtfs || _liteMode) ? null : _refreshGtfs,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    minimumSize: const Size(double.infinity, 0),
                  ),
                  child: _refreshingGtfs
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
                        )
                      : const Text('Refresh Transit Data'),
                ),
                if (_liteMode) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Turn off Lite mode above to refresh schedule data',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 32),
                const Text(
                  'Your profile',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Save your stops to a file, or load them from one. Useful for '
                  'moving to a new phone, or sharing stops with someone else.',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Your API key is never included in this file.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _busyProfile ? null : _exportProfile,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    minimumSize: const Size(double.infinity, 0),
                  ),
                  child: const Text('Export favourites'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _busyProfile ? null : _importProfile,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    minimumSize: const Size(double.infinity, 0),
                  ),
                  child: const Text('Import favourites'),
                ),
                const SizedBox(height: 32),
                const Text(
                  'How to get a key',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                const _Step(number: '1', text: 'Go to developer.translink.ca'),
                const _Step(number: '2', text: 'Create a free account and sign in'),
                const _Step(number: '3', text: 'Register a new app to get an API key'),
                const _Step(number: '4', text: 'Paste the key above and tap Save'),
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Arrival data is provided by TransLink (developer.translink.ca). '
                    'This app is an independent project and is not affiliated with '
                    'or endorsed by TransLink.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
              ],
            ),
    );
  }
}

class _Step extends StatelessWidget {
  final String number;
  final String text;
  const _Step({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: _accent,
            child: Text(number, style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: const TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}
