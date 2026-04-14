import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ── Palette tokens ──────────────────────────────────────────────
const kDeepNavy = Color(0xFF000D1A);
const kPrimaryNavy = Color(0xFF001F3F);
const kDarkSurface = Color(0xFF0D1B2A);
const kCardDark = Color(0xFF122030);
const kElectricTeal = Color(0xFF00E5FF);
const kVibrantTeal = Color(0xFF00B4CC);
const kLightSurface = Color(0xFFF0F4F8);

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: kPrimaryNavy,
      brightness: Brightness.dark,
      primary: kElectricTeal,
      primaryContainer: kPrimaryNavy,
      secondary: kVibrantTeal,
      secondaryContainer: kElectricTeal.withValues(alpha: 0.12),
      surface: kDarkSurface,
      surfaceContainerHighest: kCardDark,
      onPrimary: kDeepNavy,
      onSurface: Colors.white,
    ),
    scaffoldBackgroundColor: kDarkSurface,
  );

  return base.copyWith(
    textTheme: GoogleFonts.interTextTheme(base.textTheme).copyWith(
      displayLarge: GoogleFonts.plusJakartaSans(
        textStyle: base.textTheme.displayLarge,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.0,
        color: Colors.white,
      ),
      displayMedium: GoogleFonts.plusJakartaSans(
        textStyle: base.textTheme.displayMedium,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
        color: Colors.white,
      ),
      headlineLarge: GoogleFonts.plusJakartaSans(
        textStyle: base.textTheme.headlineLarge,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: Colors.white,
      ),
      headlineMedium: GoogleFonts.plusJakartaSans(
        textStyle: base.textTheme.headlineMedium,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: Colors.white,
      ),
      titleLarge: GoogleFonts.plusJakartaSans(
        textStyle: base.textTheme.titleLarge,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
      titleMedium: GoogleFonts.plusJakartaSans(
        textStyle: base.textTheme.titleMedium,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
      titleSmall: GoogleFonts.plusJakartaSans(
        textStyle: base.textTheme.titleSmall,
        fontWeight: FontWeight.w600,
        color: Colors.white.withValues(alpha: 0.9),
      ),
      bodyLarge: GoogleFonts.inter(
        textStyle: base.textTheme.bodyLarge,
        color: Colors.white.withValues(alpha: 0.85),
      ),
      bodyMedium: GoogleFonts.inter(
        textStyle: base.textTheme.bodyMedium,
        color: Colors.white.withValues(alpha: 0.7),
      ),
      bodySmall: GoogleFonts.inter(
        textStyle: base.textTheme.bodySmall,
        color: Colors.white.withValues(alpha: 0.5),
      ),
      labelLarge: GoogleFonts.inter(
        textStyle: base.textTheme.labelLarge,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
      labelMedium: GoogleFonts.inter(
        textStyle: base.textTheme.labelMedium,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
      labelSmall: GoogleFonts.inter(
        textStyle: base.textTheme.labelSmall,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: Colors.white.withValues(alpha: 0.8),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.plusJakartaSans(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.3,
      ),
      iconTheme: const IconThemeData(color: Colors.white),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide.none,
      backgroundColor: kElectricTeal.withValues(alpha: 0.10),
      selectedColor: kElectricTeal.withValues(alpha: 0.22),
      labelStyle: GoogleFonts.inter(
        fontWeight: FontWeight.w600,
        fontSize: 12,
        color: Colors.white,
      ),
      shape: const StadiumBorder(),
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: kCardDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kElectricTeal,
        foregroundColor: kDeepNavy,
        textStyle: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kElectricTeal,
        side: BorderSide(color: kElectricTeal.withValues(alpha: 0.4)),
        textStyle: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: Colors.white,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: Colors.white.withValues(alpha: 0.08),
    ),
    listTileTheme: ListTileThemeData(
      textColor: Colors.white,
      subtitleTextStyle: GoogleFonts.inter(
        color: Colors.white.withValues(alpha: 0.6),
        fontSize: 13,
      ),
      iconColor: kElectricTeal,
    ),
    expansionTileTheme: ExpansionTileThemeData(
      textColor: Colors.white,
      collapsedTextColor: Colors.white.withValues(alpha: 0.85),
      iconColor: kElectricTeal,
      collapsedIconColor: Colors.white.withValues(alpha: 0.5),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: kElectricTeal,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: kCardDark,
      contentTextStyle: GoogleFonts.inter(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
