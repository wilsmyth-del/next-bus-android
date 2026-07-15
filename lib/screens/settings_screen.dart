import 'package:flutter/material.dart';
import '../services/api_key_service.dart';
import '../services/translink_service.dart';
import '../services/db_service.dart';
import '../services/gtfs_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _controller = TextEditingController();
  bool _loading = true;
  bool _saved = false;
  bool _hasKey = false;
  bool _liteMode = false;
  bool _refreshingGtfs = false;
  String? _gtfsDate;

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
    if (mounted) {
      setState(() {
        _controller.text = key ?? '';
        _hasKey = key != null;
        _liteMode = liteMode;
        _gtfsDate = gtfsDate;
        _loading = false;
      });
    }
  }

  Future<void> _refreshGtfs() async {
    setState(() => _refreshingGtfs = true);
    try {
      final feed = await GtfsService.findLatestFeed();
      if (feed == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No GTFS feed found')),
          );
        }
        return;
      }
      if (_gtfsDate == feed.date) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Already up to date (${feed.date})')),
          );
        }
        return;
      }
      await GtfsService.downloadAndBuild(
        feed: feed,
        onStatus: (_) {},
      );
      if (mounted) {
        setState(() => _gtfsDate = feed.date);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Updated to ${feed.date}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshingGtfs = false);
    }
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
        backgroundColor: const Color(0xFF1A1D27),
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF60A5FA)))
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
                    color: const Color(0xFF1A1D27),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SwitchListTile(
                    title: const Text('Lite mode', style: TextStyle(color: Colors.white)),
                    subtitle: const Text(
                      'Block GTFS downloads and live arrivals on mobile data',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    value: _liteMode,
                    activeColor: const Color(0xFF60A5FA),
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
                    fillColor: const Color(0xFF1A1D27),
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
                    backgroundColor: const Color(0xFF60A5FA),
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
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF60A5FA)),
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
                    color: const Color(0xFF1A1D27),
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
            backgroundColor: const Color(0xFF60A5FA),
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
