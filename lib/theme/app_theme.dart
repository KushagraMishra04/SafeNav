import 'package:flutter/material.dart';

/// Shared SafeNav palette. Blue is the brand colour; green/amber/red are
/// reserved for route-safety status and emergency states.
class AppColors {
  static const blue = Color(0xFF1769C2);
  static const blueDark = Color(0xFF0D3B70);
  static const blueLight = Color(0xFFEAF3FF);
  // Keep the old names as aliases so existing screens continue to compile.
  static const purple = blue;
  static const purpleLight = blueLight;
  static const green = Color(0xFF218653);
  static const greenLight = Color(0xFFE8F6EE);
  static const red = Color(0xFFD92D32);
  static const redLight = Color(0xFFFFEEEE);
  static const orange = Color(0xFFE69A20);
  static const orangeLight = Color(0xFFFFF4DF);
  static const navy = Color(0xFF142B45);
  static const background = Color(0xFFF6F8FB);
  static const cardBorder = Color(0xFFDCE4EE);
  static const muted = Color(0xFF65758B);
}

class AppTheme {
  static ThemeData get theme {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.blue,
      primary: AppColors.blue,
      secondary: AppColors.green,
      surface: Colors.white,
      error: AppColors.red,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.background,
      fontFamily: 'Roboto',
      colorScheme: scheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.navy,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.navy,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.blue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          elevation: 0,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 15, horizontal: 14),
        labelStyle: const TextStyle(color: AppColors.muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.blue, width: 1.5),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
      ),
    );
  }
}

class StepCard extends StatelessWidget {
  final Widget child;
  final Color? borderColor;
  final EdgeInsetsGeometry padding;
  const StepCard({super.key, required this.child, this.borderColor,
    this.padding = const EdgeInsets.all(18)});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: borderColor ?? AppColors.cardBorder),
    ),
    child: child,
  );
}

class StepBadge extends StatelessWidget {
  final String text;
  final Color color;
  const StepBadge({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: color.withOpacity(0.10), borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
  );
}
