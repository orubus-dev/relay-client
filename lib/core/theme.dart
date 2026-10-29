import 'package:flutter/material.dart';

/// Accent presets — the app icon, splash and UI all follow the active accent.
class AccentPreset {
  final String id;
  final String label;
  final int value;
  const AccentPreset(this.id, this.label, this.value);

  Color get color => Color(value);
}

const List<AccentPreset> kAccents = [
  AccentPreset('liquid-azure', 'Liquid Azure', 0xFF2563EB),
  AccentPreset('emerald-frost', 'Emerald Frost', 0xFF059669),
  AccentPreset('neon-violet', 'Neon Violet', 0xFF7C3AED),
  AccentPreset('rose-gold', 'Rose Gold', 0xFFE11D48),
  AccentPreset('midnight', 'Midnight', 0xFF334155),
  AccentPreset('amber-glow', 'Amber Glow', 0xFFD97706),
];

class ThemeModeOption {
  final String id;
  final String label;
  const ThemeModeOption(this.id, this.label);
}

const kThemeModes = [
  ThemeModeOption('system', 'System'),
  ThemeModeOption('light', 'Light'),
  ThemeModeOption('dark', 'Dark'),
  ThemeModeOption('pure-black', 'Pure Black (OLED)'),
];

/// Builds the Material 3 themes. Dark mode is genuinely dark — surfaces are
/// slate/near-black, never the white sheets the web app used to leak.
class RelayTheme {
  static ThemeData light(Color accent) => _base(accent, Brightness.light);

  static ThemeData dark(Color accent, {bool pureBlack = false}) =>
      _base(accent, Brightness.dark, pureBlack: pureBlack);

  static ThemeData _base(Color accent, Brightness brightness, {bool pureBlack = false}) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(primary: accent, secondary: accent);

    final surface = isDark ? (pureBlack ? Colors.black : const Color(0xFF0B1220)) : const Color(0xFFF8FAFC);
    final surfaceContainer = isDark
        ? (pureBlack ? const Color(0xFF0A0A0A) : const Color(0xFF101A2C))
        : Colors.white;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme.copyWith(surface: surface, surfaceContainerHighest: surfaceContainer),
      scaffoldBackgroundColor: surface,
      appBarTheme: AppBarTheme(
        backgroundColor: surface.withOpacity(isDark ? 0.85 : 0.9),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: isDark ? Colors.white : const Color(0xFF0F172A),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? Colors.black.withOpacity(0.72) : Colors.black.withOpacity(0.55),
        indicatorColor: accent.withOpacity(0.25),
        surfaceTintColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? IconThemeData(color: accent) : const IconThemeData(color: Colors.white70)),
        labelTextStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? Colors.white.withOpacity(0.07) : const Color(0xFFF1F5F9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: isDark ? Colors.white12 : const Color(0xFFE2E8F0)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: isDark ? Colors.white12 : const Color(0xFFE2E8F0)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: accent, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      dividerTheme: DividerThemeData(color: isDark ? Colors.white10 : const Color(0xFFE2E8F0)),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? const Color(0xFF1E293B) : const Color(0xFF0F172A),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
      ),
    );
  }
}
