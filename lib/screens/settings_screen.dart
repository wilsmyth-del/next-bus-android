import 'package:flutter/material.dart';
import '../services/api_key_service.dart';
import '../services/translink_service.dart';
import '../services/db_service.dart';

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
  bool _testing = false;
  String? _testResult;
  final _diagStopController = TextEditingController();
  bool _diagnosing = false;
  String? _diagResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _diagStopController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final key = await ApiKeyService.getKey();
    final liteMode = await ApiKeyService.getLiteMode();
    if (mounted) {
      setState(() {
        _controller.text = key ?? '';
        _hasKey = key != null;
        _liteMode = liteMode;
        _loading = false;
      });
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

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final result = await TranslinkService.testConnection();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  Future<void> _diagnoseSchedule() async {
    final stopCode = _diagStopController.text.trim();
    if (stopCode.isEmpty) return;
    setState(() {
      _diagnosing = true;
      _diagResult = null;
    });
    final result = await DbService.diagnoseSchedule(stopCode);
    if (!mounted) return;
    setState(() {
      _diagnosing = false;
      _diagResult = result;
    });
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
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _testing ? null : _testConnection,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    minimumSize: const Size(double.infinity, 0),
                  ),
                  child: _testing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF60A5FA)),
                        )
                      : const Text('Test Connection'),
                ),
                if (_testResult != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _testResult!,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 24),
                const Text(
                  'Schedule diagnostic',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _diagStopController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Stop code to inspect',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: const Color(0xFF1A1D27),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _diagnosing ? null : _diagnoseSchedule,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    minimumSize: const Size(double.infinity, 0),
                  ),
                  child: _diagnosing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF60A5FA)),
                        )
                      : const Text('Inspect Schedule Query'),
                ),
                if (_diagResult != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    _diagResult!,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
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
