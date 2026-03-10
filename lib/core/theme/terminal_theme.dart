import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData get dark {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: Colors.teal,
      scaffoldBackgroundColor: const Color(0xFF121212),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1E1E1E),
        elevation: 0,
      ),
      cardTheme: const CardTheme(
        color: Color(0xFF1E1E1E),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF2C2C2C),
      ),
    );
  }

  static ThemeData get light {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorSchemeSeed: Colors.teal,
    );
  }

  /// High-contrast theme for accessibility: black background, white text,
  /// yellow accent, large minimum touch targets.
  static ThemeData get highContrast {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: Colors.yellow,
      scaffoldBackgroundColor: Colors.black,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: const CardTheme(color: Color(0xFF111111)),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF111111),
        border: OutlineInputBorder(),
      ),
      iconTheme: const IconThemeData(color: Colors.yellow),
      listTileTheme: const ListTileThemeData(
        iconColor: Colors.yellow,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: Colors.yellow,
        foregroundColor: Colors.black,
      ),
    );
  }
}
