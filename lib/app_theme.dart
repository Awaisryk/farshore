import 'package:flutter/material.dart';

/// Stable identifiers are persisted independently of display names or ordering.
enum ShoreTheme {
  shore('shore', 'Shore', 'Warm light with sea-glass green.', false),
  deepShore(
    'deep-shore',
    'Deep Shore',
    'Deep neutrals with soft sea glass.',
    true,
  ),
  frost('frost', 'Frost', 'Cool white with clear blue accents.', false),
  sand('sand', 'Sand', 'Warm ivory with amber accents.', false),
  midnight('midnight', 'Midnight', 'Deep navy with soft blue accents.', true),
  orchid('orchid', 'Orchid', 'Dark plum with lilac accents.', true);

  const ShoreTheme(this.id, this.label, this.description, this.isDark);
  final String id, label, description;
  final bool isDark;

  static ShoreTheme fromId(String? id) {
    for (final theme in values) {
      if (theme.id == id) return theme;
    }
    return shore;
  }
}

class ShoreColors {
  const ShoreColors(bool dark)
    : this.forTheme(dark ? ShoreTheme.deepShore : ShoreTheme.shore);
  const ShoreColors.forTheme(this.theme);
  final ShoreTheme theme;
  bool get dark => theme.isDark;
  _Palette get _palette => _palettes[theme]!;
  Color get canvas => _palette.canvas;
  Color get sidebar => _palette.sidebar;
  Color get surface => _palette.surface;
  Color get soft => _palette.soft;
  Color get line => _palette.line;
  Color get ink => _palette.ink;
  Color get muted => _palette.muted;
  Color get accent => _palette.accent;
  Color get selection => _palette.selection;

  static const _palettes = {
    ShoreTheme.shore: _Palette(
      canvas: Color(0xfffaf9f6),
      sidebar: Color(0xfff0f1ed),
      surface: Color(0xffffffff),
      soft: Color(0xfff0f2ee),
      line: Color(0xffe2e5de),
      ink: Color(0xff253a37),
      muted: Color(0xff586d63),
      accent: Color(0xff2e7462),
      selection: Color(0xffe0eee5),
    ),
    ShoreTheme.deepShore: _Palette(
      canvas: Color(0xff141b1c),
      sidebar: Color(0xff101718),
      surface: Color(0xff1c2526),
      soft: Color(0xff202b2c),
      line: Color(0xff2c3839),
      ink: Color(0xffe4ece8),
      muted: Color(0xff9cafaa),
      accent: Color(0xff9fd8c5),
      selection: Color(0xff28433b),
    ),
    ShoreTheme.frost: _Palette(
      canvas: Color(0xfff6f8fc),
      sidebar: Color(0xffedf1f8),
      surface: Color(0xffffffff),
      soft: Color(0xffeaf0f9),
      line: Color(0xffd8e1ee),
      ink: Color(0xff24364d),
      muted: Color(0xff536982),
      accent: Color(0xff2e65a7),
      selection: Color(0xffdce9f8),
    ),
    ShoreTheme.sand: _Palette(
      canvas: Color(0xfffaf7f0),
      sidebar: Color(0xfff1eadf),
      surface: Color(0xfffffdfa),
      soft: Color(0xfff2eadb),
      line: Color(0xffe2d7c7),
      ink: Color(0xff493c2c),
      muted: Color(0xff746047),
      accent: Color(0xff8b5a1c),
      selection: Color(0xfff0e2c9),
    ),
    ShoreTheme.midnight: _Palette(
      canvas: Color(0xff101725),
      sidebar: Color(0xff0c1220),
      surface: Color(0xff182338),
      soft: Color(0xff1c2c45),
      line: Color(0xff293b56),
      ink: Color(0xffe5edf8),
      muted: Color(0xffa0b3ce),
      accent: Color(0xff9abef2),
      selection: Color(0xff263e5e),
    ),
    ShoreTheme.orchid: _Palette(
      canvas: Color(0xff1e1722),
      sidebar: Color(0xff18111d),
      surface: Color(0xff2a2030),
      soft: Color(0xff35263d),
      line: Color(0xff493652),
      ink: Color(0xfff0e6f3),
      muted: Color(0xffc0a8c9),
      accent: Color(0xffdbafe9),
      selection: Color(0xff4a3157),
    ),
  };
}

class _Palette {
  const _Palette({
    required this.canvas,
    required this.sidebar,
    required this.surface,
    required this.soft,
    required this.line,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.selection,
  });
  final Color canvas,
      sidebar,
      surface,
      soft,
      line,
      ink,
      muted,
      accent,
      selection;
}
