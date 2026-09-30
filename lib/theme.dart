import 'package:flutter/material.dart';

/// Yaad design tokens — the "professional UI designer" bar (§9).
/// 8pt spacing grid, one identity color (deep teal + warm accent),
/// first-class dark mode, Material 3 throughout.
class YaadTheme {
  /// Accent choices. Teal is free; the rest are Pro power-tools.
  static const accents = <String, Color>{
    'teal': Color(0xFF0F766E), // deep teal — the Yaad identity
    'amber': Color(0xFFB45309), // warm accent
    'violet': Color(0xFF6D28D9),
    'rose': Color(0xFFBE123C),
  };

  static Color seedFor(String accent) =>
      accents[accent] ?? accents['teal']!;

  static ThemeData light(String accent) => ThemeData(
        colorSchemeSeed: seedFor(accent),
        useMaterial3: true,
        brightness: Brightness.light,
      );

  static ThemeData dark(String accent) => ThemeData(
        colorSchemeSeed: seedFor(accent),
        useMaterial3: true,
        brightness: Brightness.dark,
      );
}

/// 8pt spacing grid.
class Gap {
  static const double x1 = 8;
  static const double x2 = 16;
  static const double x3 = 24;
  static const double x4 = 32;
  static const double x5 = 40;
  static const double x6 = 48;
}

/// Corner radii used across cards and sheets.
class Radius {
  static const double card = 20;
  static const double tile = 16;
  static const double chip = 12;
}
