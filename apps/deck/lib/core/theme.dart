import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';

/// BambuDeck dark palette - tokens ported from the BambuHelper dashboard
/// look: near-black ground, subtle card surfaces, green running accent,
/// fixed warning/pause/error colors (per PRD NFR-9, those stay fixed).
abstract final class DeckColors {
  static const bg = Color(0xFF0E1216);
  static const surface = Color(0xFF161B21);
  static const card = Color(0xFF1A2027);
  static const border = Color(0xFF262E37);
  static const textPrimary = Color(0xFFE6E9EE);
  static const textSecondary = Color(0xFF8B94A3);

  static const running = Color(0xFF4ADE80);
  static const finish = Color(0xFF34D399);
  static const prepare = Color(0xFF38BDF8);
  static const idle = Color(0xFF94A3B8);
  static const pause = Color(0xFFFBBF24);
  static const failed = Color(0xFFEF4444);
  static const error = Color(0xFFEF4444);
  static const warning = Color(0xFFF59E0B);

  // Temp gauge hues (nozzle / bed / chamber).
  static const nozzle = Color(0xFFF97316);
  static const bed = Color(0xFF38BDF8);
  static const chamber = Color(0xFFA78BFA);
}

/// Status -> color mapping shared by badges, cards and edge glow.
Color stateColor(GcodeState s) => switch (s) {
      GcodeState.running => DeckColors.running,
      GcodeState.pause => DeckColors.pause,
      GcodeState.prepare => DeckColors.prepare,
      GcodeState.finish => DeckColors.finish,
      GcodeState.failed => DeckColors.failed,
      GcodeState.idle => DeckColors.idle,
      _ => DeckColors.idle,
    };

ThemeData buildDeckTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: DeckColors.running,
      onPrimary: Color(0xFF062012),
      secondary: DeckColors.prepare,
      surface: DeckColors.surface,
      error: DeckColors.error,
    ),
    scaffoldBackgroundColor: DeckColors.bg,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: DeckColors.textPrimary,
      displayColor: DeckColors.textPrimary,
    ),
    cardTheme: CardThemeData(
      color: DeckColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: DeckColors.border),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: DeckColors.textPrimary,
        side: const BorderSide(color: DeckColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DeckColors.bg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: DeckColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: DeckColors.border),
      ),
      labelStyle: const TextStyle(color: DeckColors.textSecondary),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: DeckColors.card,
      contentTextStyle: TextStyle(color: DeckColors.textPrimary),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
