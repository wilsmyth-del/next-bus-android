import 'package:flutter/material.dart';
import 'screens/search_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/settings_screen.dart';
import 'services/api_key_service.dart';

class NavShell extends StatefulWidget {
  const NavShell({super.key});

  @override
  State<NavShell> createState() => _NavShellState();
}

class _NavShellState extends State<NavShell> {
  int _currentIndex = 0;
  final GlobalKey<FavoritesScreenState> _favKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptForKey());
  }

  Future<void> _maybePromptForKey() async {
    final hasKey = await ApiKeyService.hasKey();
    if (hasKey || !mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D27),
        title: const Text('Live arrivals need a key', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Add a free TransLink API key in Settings to see live bus arrivals. '
          'Without one, the app still works using the static schedule.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _currentIndex = 2);
            },
            child: const Text('Set up now', style: TextStyle(color: Color(0xFF60A5FA))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          FavoritesScreen(key: _favKey),
          const SearchScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) {
          if (i == 0) _favKey.currentState?.refresh();
          setState(() => _currentIndex = i);
        },
        backgroundColor: const Color(0xFF1A1D27),
        selectedItemColor: const Color(0xFF60A5FA),
        unselectedItemColor: Colors.white54,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.star_outline), label: 'Favourites'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
      ),
    );
  }
}
