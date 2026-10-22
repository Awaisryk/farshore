import 'package:flutter/material.dart';
import 'app_theme.dart';

ThemeData buildShoreTheme(ShoreTheme theme) {
  final c = ShoreColors.forTheme(theme);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: c.accent,
        brightness: theme.isDark ? Brightness.dark : Brightness.light,
        surface: c.canvas,
      ).copyWith(
        primary: c.accent,
        onPrimary: theme.isDark ? c.sidebar : c.surface,
        primaryContainer: c.selection,
        onPrimaryContainer: c.ink,
        onSurface: c.ink,
        onSurfaceVariant: c.muted,
        surfaceContainerLow: c.surface,
        surfaceContainerHigh: c.soft,
        outline: c.muted,
        outlineVariant: c.line,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.canvas,
    fontFamily: '.AppleSystemUIFont',
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.compact,
    textTheme: ThemeData(
      brightness: scheme.brightness,
    ).textTheme.apply(bodyColor: c.ink, displayColor: c.ink),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      decoration: BoxDecoration(
        color: c.ink,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: TextStyle(color: c.canvas, fontSize: 11),
    ),
    dividerColor: c.line,
  );
}
