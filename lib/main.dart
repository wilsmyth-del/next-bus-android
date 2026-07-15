import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const NextBusApp());
}

class NextBusApp extends StatelessWidget {
  const NextBusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Next Bus',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF60A5FA),
          surface: Color(0xFF0F1117),
        ),
        scaffoldBackgroundColor: const Color(0xFF0F1117),
      ),
      home: const HomeScreen(),
    );
  }
}
