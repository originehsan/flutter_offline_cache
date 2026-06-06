import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/crypto_screen.dart';

void main() {
  runApp(const ProviderScope(child: CryptoApp()));
}

class CryptoApp extends StatelessWidget {
  const CryptoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_offline_cache',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light().copyWith(
        scaffoldBackgroundColor: const Color(0xFFF6F8FA),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF1D4ED8),
          surface: Color(0xFFFFFFFF),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFFFFF),
          foregroundColor: Color(0xFF1F2328),
          elevation: 0,
        ),
      ),
      home: const CryptoScreen(),
    );
  }
}