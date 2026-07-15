import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../services/db_service.dart';
import 'arrivals_screen.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => FavoritesScreenState();
}

class FavoritesScreenState extends State<FavoritesScreen> {
  List<Map<String, dynamic>> _favourites = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void refresh() => _load();

  Future<void> _load() async {
    final favs = await DbService.getFavourites();
    if (mounted) setState(() => _favourites = favs);
  }

  Future<void> _remove(String stopCode) async {
    setState(() => _favourites.removeWhere((f) => f['stop_code'] == stopCode));
    await DbService.removeFavourite(stopCode);
  }

  Future<void> _rename(String stopCode, String currentName) async {
    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D27),
        title: const Text('Rename stop', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white38),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF60A5FA)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save', style: TextStyle(color: Color(0xFF60A5FA))),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != currentName) {
      await DbService.updateFavouriteName(stopCode, newName);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1117),
      appBar: AppBar(
        title: const Text('Saved Stops'),
        backgroundColor: const Color(0xFF1A1D27),
        foregroundColor: Colors.white,
      ),
      body: _favourites.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.star_border, color: Colors.white24, size: 64),
                  SizedBox(height: 16),
                  Text('No saved stops yet',
                      style: TextStyle(color: Colors.white54)),
                  SizedBox(height: 8),
                  Text(
                      'Tap the star on any arrivals screen to save a stop',
                      style:
                          TextStyle(color: Colors.white38, fontSize: 12),
                      textAlign: TextAlign.center),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: _favourites.length,
                    itemBuilder: (context, i) {
                final stop = _favourites[i];
                final stopCode = stop['stop_code'] as String;
                final stopName = stop['stop_name'] as String;
                return Slidable(
                  key: Key(stopCode),
                  endActionPane: ActionPane(
                    motion: const ScrollMotion(),
                    extentRatio: 0.28,
                    children: [
                      SlidableAction(
                        onPressed: (_) => _remove(stopCode),
                        backgroundColor: Colors.red.shade900,
                        foregroundColor: Colors.white70,
                        icon: Icons.delete_outline,
                        label: 'Remove',
                      ),
                    ],
                  ),
                  child: ListTile(
                    leading:
                        const Icon(Icons.star, color: Color(0xFF60A5FA)),
                    title: Text(stopCode,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold)),
                    subtitle: Text(stopName,
                        style:
                            const TextStyle(color: Colors.white54)),
                    trailing: const Icon(Icons.chevron_right,
                        color: Colors.white24),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ArrivalsScreen(
                            stopCode: stopCode, stopName: stopName),
                      ),
                    ),
                    onLongPress: () => _rename(stopCode, stopName),
                  ),
                );
                    },
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Hold to rename  ·  Swipe to reveal remove',
                    style: TextStyle(color: Colors.white24, fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
    );
  }
}
