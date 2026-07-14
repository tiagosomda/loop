import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Minimalistic sci-fi/space look: deep-space surfaces, cyan/violet accents,
/// Space Grotesk type. Material 3 does the heavy lifting.
class AppTheme {
  static const _cyan = Color(0xFF22D3EE);
  static const _violet = Color(0xFFA78BFA);

  static ThemeData dark() => _base(
    ColorScheme.fromSeed(
      seedColor: _cyan,
      brightness: Brightness.dark,
      surface: const Color(0xFF0B0F1A),
      primary: _cyan,
      secondary: _violet,
    ),
    scaffold: const Color(0xFF070A12),
    card: const Color(0xFF111828),
    outline: const Color(0xFF243044),
  );

  static ThemeData light() => _base(
    ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E7490),
      brightness: Brightness.light,
      surface: Colors.white,
      primary: const Color(0xFF0E7490),
      secondary: const Color(0xFF7C3AED),
    ),
    scaffold: const Color(0xFFF4F6FB),
    card: Colors.white,
    outline: const Color(0xFFD8DEE9),
  );

  // Shared corner radius so every surface reads from the same design grid.
  static const double radius = 12;

  static ThemeData _base(
    ColorScheme scheme, {
    required Color scaffold,
    required Color card,
    required Color outline,
  }) {
    final text = GoogleFonts.spaceGroteskTextTheme(
      ThemeData(brightness: scheme.brightness).textTheme,
    );
    final onSurface = scheme.onSurface;
    final mono = GoogleFonts.jetBrainsMono();
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffold,
      textTheme: text,
      canvasColor: card,
      appBarTheme: AppBarTheme(
        backgroundColor: scaffold,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
          color: scheme.primary,
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: outline),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      chipTheme: ChipThemeData(
        labelStyle: mono.copyWith(fontSize: 12, color: onSurface),
        side: BorderSide(color: outline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: outline),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        elevation: 8,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: outline),
        ),
        textStyle: text.bodyMedium,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: text.bodyMedium,
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(card),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
              side: BorderSide(color: outline),
            ),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: outline),
        ),
      ),
      dividerColor: outline,
    );
  }

  static Color statusColor(String status, ColorScheme scheme) {
    switch (status) {
      case 'open':
        return scheme.primary;
      case 'in-progress':
        return const Color(0xFFF59E0B);
      case 'needs-review':
        return scheme.secondary;
      case 'completed':
        return const Color(0xFF34D399);
      case 'closed':
      default:
        return scheme.onSurface.withValues(alpha: 0.45);
    }
  }
}
