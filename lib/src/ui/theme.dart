import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config.dart';

/// WCAG AA contrast for body text.
const double _minTextContrast = 4.5;

/// WCAG AA contrast for large or bold text, which is what buttons use.
const double _minLargeTextContrast = 3;

/// Contrast ratio between two opaque colours (WCAG 2.1).
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The colours of one appearance mode.
///
/// Every hand-drawn surface in the UI reads these through
/// [AppPaletteContext.palette] instead of hardcoding colours, so switching
/// between dark and light repaints the whole window.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.background,
    required this.sidebar,
    required this.surface,
    required this.surfaceHigh,
    required this.accent,
    required this.accentSoft,
    required this.text,
    required this.textDim,
    required this.warning,
    required this.tileLetter,
    required this.previewLetter,
    required this.scrim,
    required this.onScrim,
    required this.onAccent,
    required this.shadow,
    required this.shadowAlpha,
    required this.shadowHoverAlpha,
  });

  /// Page behind the grid.
  final Color background;

  /// Sidebar and detail panel.
  final Color sidebar;

  /// Inputs, dialogs and the cover placeholder.
  final Color surface;

  /// Chips, popup menus and the selected sidebar row.
  final Color surfaceHigh;

  /// Primary action colour: buttons, the selected tile border, switches.
  final Color accent;

  /// Muted accent, used for text and icons sitting on [background].
  final Color accentSoft;

  final Color text;
  final Color textDim;

  /// Failure and warning text.
  final Color warning;

  /// Big initial on a cover tile that has no artwork.
  final Color tileLetter;

  /// The same initial, larger, in the detail panel preview.
  final Color previewLetter;

  /// Hover gradient over a cover: top, middle, bottom.
  final List<Color> scrim;

  /// Icons drawn on top of [scrim] (the tile menu button).
  final Color onScrim;

  /// Text on top of [accent] (filled buttons). Derived from the accent, so a
  /// pale choice like Adwaita's yellow gets dark labels instead of white ones.
  final Color onAccent;

  final Color shadow;
  final double shadowAlpha;
  final double shadowHoverAlpha;

  /// Drop shadow under a cover tile.
  BoxShadow coverShadow({required bool hovered}) => BoxShadow(
    color: shadow.withValues(alpha: hovered ? shadowHoverAlpha : shadowAlpha),
    blurRadius: hovered ? 22 : 12,
    offset: const Offset(0, 8),
  );

  /// The palette the app shipped with; unchanged.
  static const AppPalette dark = AppPalette(
    background: Color(0xFF0E0E13),
    sidebar: Color(0xFF14141B),
    surface: Color(0xFF1A1A23),
    surfaceHigh: Color(0xFF23232E),
    accent: Color(0xFF8A6BFF),
    accentSoft: Color(0xFFB9A5FF),
    text: Color(0xFFEDEDF2),
    textDim: Color(0xFF9A9AAB),
    warning: Colors.orangeAccent,
    tileLetter: Color(0x66FFFFFF),
    previewLetter: Color(0x55FFFFFF),
    scrim: [Color(0xCC000000), Color(0x22000000), Color(0xE6000000)],
    onScrim: Colors.white,
    onAccent: Colors.white,
    shadow: Colors.black,
    shadowAlpha: 0.25,
    shadowHoverAlpha: 0.45,
  );

  /// Light counterpart: same structure, contrast checked against its own
  /// surfaces (body text and dim text are at least 5:1 on [background]).
  static const AppPalette light = AppPalette(
    background: Color(0xFFF4F4F8),
    sidebar: Color(0xFFEAEAF1),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFDFDFEA),
    accent: Color(0xFF5B3FD6),
    accentSoft: Color(0xFF4A2FBE),
    text: Color(0xFF16161C),
    textDim: Color(0xFF5C5C70),
    warning: Color(0xFF9A4A00),
    tileLetter: Color(0x80000000),
    previewLetter: Color(0x73000000),
    // Covers are photographs: the hover scrim stays dark in both modes so the
    // Play button is legible whatever artwork is underneath.
    scrim: [Color(0xB3000000), Color(0x1A000000), Color(0xCC000000)],
    onScrim: Colors.white,
    onAccent: Colors.white,
    shadow: Colors.black,
    shadowAlpha: 0.10,
    shadowHoverAlpha: 0.20,
  );

  /// `mode + accent -> palette`.
  ///
  /// The shipped accent returns the palette above untouched, byte for byte.
  /// Any other accent keeps the structure and derives the two colours that
  /// depend on it: [accentSoft] (blended towards the mode's text colour until
  /// it reads on the background) and [onAccent] (white, or dark when the
  /// accent is too pale for white to read).
  static AppPalette forMode(Brightness brightness, Color accent) {
    final base = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;
    if (accent == base.accent) return base;
    final towards = brightness == Brightness.dark ? Colors.white : Colors.black;
    return base.copyWith(
      accent: accent,
      accentSoft: _readableOn(
        accent,
        towards,
        base.background,
        brightness == Brightness.dark ? 0.4 : 0.25,
      ),
      onAccent: _onAccent(accent),
    );
  }

  /// [accent] blended [blend] of the way towards [towards], then further in 5%
  /// steps while it still fails [_minTextContrast] on [background]. Contrast is
  /// monotonic in the blend, so this stops at the first readable value.
  static Color _readableOn(
    Color accent,
    Color towards,
    Color background,
    double blend,
  ) {
    var factor = blend;
    var candidate = Color.lerp(accent, towards, factor)!;
    while (factor < 1 && _contrast(candidate, background) < _minTextContrast) {
      factor = math.min(1, factor + 0.05);
      candidate = Color.lerp(accent, towards, factor)!;
    }
    return candidate;
  }

  static Color _onAccent(Color accent) =>
      _contrast(Colors.white, accent) >= _minLargeTextContrast ? Colors.white : Colors.black;

  @override
  AppPalette copyWith({
    Color? background,
    Color? sidebar,
    Color? surface,
    Color? surfaceHigh,
    Color? accent,
    Color? accentSoft,
    Color? text,
    Color? textDim,
    Color? warning,
    Color? tileLetter,
    Color? previewLetter,
    List<Color>? scrim,
    Color? onScrim,
    Color? onAccent,
    Color? shadow,
    double? shadowAlpha,
    double? shadowHoverAlpha,
  }) => AppPalette(
    background: background ?? this.background,
    sidebar: sidebar ?? this.sidebar,
    surface: surface ?? this.surface,
    surfaceHigh: surfaceHigh ?? this.surfaceHigh,
    accent: accent ?? this.accent,
    accentSoft: accentSoft ?? this.accentSoft,
    text: text ?? this.text,
    textDim: textDim ?? this.textDim,
    warning: warning ?? this.warning,
    tileLetter: tileLetter ?? this.tileLetter,
    previewLetter: previewLetter ?? this.previewLetter,
    scrim: scrim ?? this.scrim,
    onScrim: onScrim ?? this.onScrim,
    onAccent: onAccent ?? this.onAccent,
    shadow: shadow ?? this.shadow,
    shadowAlpha: shadowAlpha ?? this.shadowAlpha,
    shadowHoverAlpha: shadowHoverAlpha ?? this.shadowHoverAlpha,
  );

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      background: Color.lerp(background, other.background, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceHigh: Color.lerp(surfaceHigh, other.surfaceHigh, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      text: Color.lerp(text, other.text, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      tileLetter: Color.lerp(tileLetter, other.tileLetter, t)!,
      previewLetter: Color.lerp(previewLetter, other.previewLetter, t)!,
      scrim: [
        for (var i = 0; i < scrim.length; i++)
          Color.lerp(scrim[i], other.scrim[i], t)!,
      ],
      onScrim: Color.lerp(onScrim, other.onScrim, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      shadowAlpha: shadowAlpha + (other.shadowAlpha - shadowAlpha) * t,
      shadowHoverAlpha: shadowHoverAlpha + (other.shadowHoverAlpha - shadowHoverAlpha) * t,
    );
  }
}

/// `context.palette` — the colours of the appearance mode in effect.
extension AppPaletteContext on BuildContext {
  AppPalette get palette => Theme.of(this).extension<AppPalette>() ?? AppPalette.dark;
}

/// Flutter's [ThemeMode] for the persisted appearance choice.
ThemeMode materialThemeMode(AppThemeMode mode) => switch (mode) {
  AppThemeMode.system => ThemeMode.system,
  AppThemeMode.dark => ThemeMode.dark,
  AppThemeMode.light => ThemeMode.light,
};

/// Theme data for both appearance modes.
///
/// Built once per `(mode, accent)` and shared: `MaterialApp` is rebuilt on
/// every controller notification now, and building [ThemeData] each time would
/// be wasted work.
class AppTheme {
  /// Dark, cover-forward theme in the spirit of Cartridges / Playnite.
  static final ThemeData dark = themeFor(Brightness.dark, AppPalette.dark.accent);

  /// Light counterpart of [dark].
  static final ThemeData light = themeFor(Brightness.light, AppPalette.light.accent);

  static final Map<(Brightness, Color), ThemeData> _themes = {};

  /// `mode + accent -> theme`, memoized.
  static ThemeData themeFor(Brightness brightness, Color accent) =>
      _themes.putIfAbsent(
        (brightness, accent),
        () => _build(AppPalette.forMode(brightness, accent), brightness),
      );

  static ThemeData _build(AppPalette palette, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: palette.accent,
      brightness: brightness,
    ).copyWith(
      surface: palette.background,
      primary: palette.accent,
      secondary: palette.accentSoft,
      onSurface: palette.text,
    );
    final typography = brightness == Brightness.dark
        ? Typography.whiteMountainView
        : Typography.blackMountainView;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.background,
      splashFactory: InkSparkle.splashFactory,
      extensions: [palette],
      textTheme: typography.apply(bodyColor: palette.text, displayColor: palette.text),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 500),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.surfaceHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surface,
        hintStyle: TextStyle(color: palette.textDim),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.accent,
          foregroundColor: palette.onAccent,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: palette.accentSoft),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? Colors.white : palette.textDim,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? palette.accent : palette.surfaceHigh,
        ),
      ),
    );
  }
}
