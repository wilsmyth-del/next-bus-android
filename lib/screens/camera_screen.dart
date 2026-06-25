import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../nav_shell.dart';
import '../services/db_service.dart';
import 'arrivals_screen.dart';

class CameraScreen extends StatefulWidget {
  final bool isLanding;
  const CameraScreen({super.key, this.isLanding = false});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  bool _scanning = false;
  String? _status;

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _status = null;
    });

    try {
      final photo = await ImagePicker().pickImage(source: ImageSource.camera);
      if (photo == null) {
        setState(() => _scanning = false);
        return;
      }

      setState(() => _status = 'Reading stop number…');

      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final inputImage = InputImage.fromFilePath(photo.path);
      final recognized = await recognizer.processImage(inputImage);
      await recognizer.close();

      final candidates = RegExp(r'\b(\d{3,5})\b')
          .allMatches(recognized.text)
          .map((m) => m.group(1)!)
          .toSet()
          .toList();

      // Only keep numbers that exist as real stop codes in the DB
      final verified = <Map<String, dynamic>>[];
      for (final code in candidates) {
        final stop = await DbService.lookupStop(code);
        if (stop != null) verified.add(stop);
      }

      if (!mounted) return;

      if (verified.isEmpty) {
        setState(() {
          _scanning = false;
          _status = 'No stop number found — try again';
        });
        return;
      }

      if (verified.length == 1) {
        await _goToStop(
          verified.first['stop_code'] as String,
          verified.first['stop_name'] as String,
        );
      } else {
        final pick = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (ctx) => SimpleDialog(
            backgroundColor: const Color(0xFF1A1D27),
            title: const Text('Which stop?',
                style: TextStyle(color: Colors.white)),
            children: verified
                .map((s) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, s),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s['stop_code'] as String,
                              style: const TextStyle(
                                  color: Color(0xFF60A5FA), fontSize: 18)),
                          Text(s['stop_name'] as String,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                        ],
                      ),
                    ))
                .toList(),
          ),
        );
        if (pick != null) {
          await _goToStop(
            pick['stop_code'] as String,
            pick['stop_name'] as String,
          );
        } else {
          setState(() => _scanning = false);
        }
      }
    } catch (e) {
      if (mounted) setState(() {
        _scanning = false;
        _status = 'Error: $e';
      });
    }
  }

  Future<void> _goToStop(String stopCode, String stopName) async {
    if (!mounted) return;
    setState(() => _scanning = false);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ArrivalsScreen(stopCode: stopCode, stopName: stopName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1117),
      appBar: AppBar(
        title: const Text('Scan Stop'),
        backgroundColor: const Color(0xFF1A1D27),
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: _scanning
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(color: Color(0xFF60A5FA)),
                  if (_status != null) ...[
                    const SizedBox(height: 16),
                    Text(_status!,
                        style: const TextStyle(color: Colors.white54)),
                  ],
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.camera_alt_outlined,
                      color: Color(0xFF60A5FA), size: 64),
                  const SizedBox(height: 24),
                  const Text('Point camera at a bus stop number',
                      style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 32),
                  ElevatedButton.icon(
                    onPressed: _scan,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Scan Stop'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF60A5FA),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 16),
                    ),
                  ),
                  if (_status != null) ...[
                    const SizedBox(height: 24),
                    Text(_status!,
                        style:
                            const TextStyle(color: Colors.orangeAccent)),
                  ],
                  if (widget.isLanding) ...[
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const NavShell()),
                      ),
                      child: const Text('Search manually',
                          style: TextStyle(color: Colors.white54)),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
