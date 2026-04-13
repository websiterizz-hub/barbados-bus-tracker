import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

ThemeData buildAppTheme() {
  const seed = Color(0xFF0B7A75);
  const canvas = Color(0xFFF3EEDF);
  const ink = Color(0xFF132221);

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      surface: Colors.white,
      secondary: const Color(0xFFE4A83B),
      tertiary: const Color(0xFF355C7D),
    ),
    scaffoldBackgroundColor: canvas,
  );

  return base.copyWith(
    textTheme: GoogleFonts.spaceGroteskTextTheme(
      base.textTheme,
    ).apply(bodyColor: ink, displayColor: ink),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: ink,
      elevation: 0,
      titleTextStyle: GoogleFonts.spaceGrotesk(
        color: ink,
        fontSize: 24,
        fontWeight: FontWeight.w700,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide.none,
      backgroundColor: const Color(0xFFE9F6F5),
      selectedColor: const Color(0xFFD7F0ED),
      labelStyle: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600),
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
      ),
    ),
  );
}
