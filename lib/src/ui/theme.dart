import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config.dart';

/// WCAG AA contrast for body text.
const double _minTextContrast = 4.5;

/// Filled-button labels are small text, so hold them to the body-text floor.
const double _minButtonLabelContrast = 4.5;

/// The app's one typeface. Cantarell ships with the GNOME runtime, which is
/// what the flatpak and every GNOME desktop already has; the fallback keeps a
/// stripped-down host from dropping to a different face mid-window.
const String _font = 'Cantarell';
const List<String> _fontFallback = ['Noto Sans', 'sans-serif'];

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
    required this.line,
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

  /// Hairline borders between surfaces. Kept quiet: the cover wall carries
  /// the colour, the chrome only needs enough edge to read as separate.
  final Color line;

  /// Primary action colour: buttons, the selected tile ring, switches.
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

  /// Drop shadow under a cover tile. The wall rests matte; only a hovered or
  /// focused tile lifts, and even then the shadow stays short.
  BoxShadow coverShadow({required bool hovered}) => BoxShadow(
    color: shadow.withValues(alpha: hovered ? shadowHoverAlpha : shadowAlpha),
    blurRadius: hovered ? 24 : 8,
    offset: Offset(0, hovered ? 10 : 4),
  );

  /// Graphite and bronze. The covers are the only saturated thing on screen:
  /// the chrome is a neutral warm black, the accent a muted copper, and the
  /// hierarchy comes from type and spacing rather than glow.
  static const AppPalette dark = AppPalette(
    background: Color(0xFF0F1113),
    sidebar: Color(0xFF14171A),
    surface: Color(0xFF1A1D20),
    surfaceHigh: Color(0xFF24282C),
    line: Color(0xFF2B3035),
    accent: Color(0xFFB87433),
    accentSoft: Color(0xFFD4AC85),
    text: Color(0xFFECEDEA),
    textDim: Color(0xFF9BA1A6),
    warning: Color(0xFFE06C5A),
    tileLetter: Color(0x66FFFFFF),
    previewLetter: Color(0x55FFFFFF),
    scrim: [Color(0xCC000000), Color(0x14000000), Color(0xE6000000)],
    onScrim: Colors.white,
    onAccent: Colors.black,
    shadow: Colors.black,
    shadowAlpha: 0.22,
    shadowHoverAlpha: 0.48,
  );

  /// The same structure in warm paper, with contrast checked against its own
  /// surfaces.
  static const AppPalette light = AppPalette(
    background: Color(0xFFF4F2EE),
    sidebar: Color(0xFFECE8E1),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFE2DDD4),
    line: Color(0xFFD6D0C6),
    accent: Color(0xFFB87433),
    accentSoft: Color(0xFF8A5726),
    text: Color(0xFF1A1C1D),
    textDim: Color(0xFF5C6266),
    warning: Color(0xFFA83B2E),
    tileLetter: Color(0x80000000),
    previewLetter: Color(0x73000000),
    // Covers are photographs: the hover scrim stays dark in both modes so the
    // Play button is legible whatever artwork is underneath.
    scrim: [Color(0xB3000000), Color(0x14000000), Color(0xCC000000)],
    onScrim: Colors.white,
    onAccent: Colors.black,
    shadow: Colors.black,
    shadowAlpha: 0.08,
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
    final base = brightness == Brightness.dark
        ? AppPalette.dark
        : AppPalette.light;
    if (accent == base.accent) return base;
    final towards = brightness == Brightness.dark ? Colors.white : Colors.black;
    return base.copyWith(
      accent: accent,
      accentSoft: _readableOn(
        accent,
        towards,
        base.background,
        base.sidebar,
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
    Color sidebar,
    double blend,
  ) {
    var factor = blend;
    var candidate = Color.lerp(accent, towards, factor)!;
    while (factor < 1 &&
        (_contrast(candidate, background) < _minTextContrast ||
            _contrast(candidate, sidebar) < _minTextContrast)) {
      factor = math.min(1, factor + 0.05);
      candidate = Color.lerp(accent, towards, factor)!;
    }
    return candidate;
  }

  static Color _onAccent(Color accent) =>
      _contrast(Colors.white, accent) >= _minButtonLabelContrast
      ? Colors.white
      : Colors.black;

  @override
  AppPalette copyWith({
    Color? background,
    Color? sidebar,
    Color? surface,
    Color? surfaceHigh,
    Color? line,
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
    line: line ?? this.line,
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
      line: Color.lerp(line, other.line, t)!,
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
      shadowHoverAlpha:
          shadowHoverAlpha + (other.shadowHoverAlpha - shadowHoverAlpha) * t,
    );
  }
}

/// The radius scale. Small controls, panels and the window's largest dialog
/// sit on four steps, so a new surface picks a step instead of inventing a
/// value that almost matches its neighbours.
abstract final class AppRadius {
  static const Radius small = Radius.circular(6);
  static const Radius medium = Radius.circular(8);
  static const Radius large = Radius.circular(10);
  static const Radius xlarge = Radius.circular(14);

  static const BorderRadius smallAll = BorderRadius.all(small);
  static const BorderRadius mediumAll = BorderRadius.all(medium);
  static const BorderRadius largeAll = BorderRadius.all(large);
  static const BorderRadius xlargeAll = BorderRadius.all(xlarge);
}

/// `context.palette` — the colours of the appearance mode in effect.
extension AppPaletteContext on BuildContext {
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.dark;
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
  /// Dark, cover-forward theme: graphite chrome, bronze accent.
  static final ThemeData dark = themeFor(
    Brightness.dark,
    AppPalette.dark.accent,
  );

  /// Light counterpart of [dark].
  static final ThemeData light = themeFor(
    Brightness.light,
    AppPalette.light.accent,
  );

  static final Map<(Brightness, Color), ThemeData> _themes = {};

  /// `mode + accent -> theme`, memoized.
  static ThemeData themeFor(Brightness brightness, Color accent) =>
      _themes.putIfAbsent((
        brightness,
        accent,
      ), () => _build(AppPalette.forMode(brightness, accent), brightness));

  static ThemeData _build(AppPalette palette, Brightness brightness) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: brightness,
        ).copyWith(
          primary: palette.accent,
          onPrimary: palette.onAccent,
          secondary: palette.accentSoft,
          onSecondary: palette.onAccent,
          error: palette.warning,
          onError: Colors.white,
          surface: palette.background,
          onSurface: palette.text,
          onSurfaceVariant: palette.textDim,
          outline: palette.line,
          outlineVariant: palette.line,
          surfaceContainerHighest: palette.surfaceHigh,
          surfaceContainerHigh: palette.surface,
          surfaceContainer: palette.surface,
          surfaceContainerLow: palette.background,
          surfaceContainerLowest: palette.background,
        );
    final geometry = TextStyle(
      fontFamily: _font,
      fontFamilyFallback: _fontFallback,
    );
    final textTheme = TextTheme(
      displaySmall: geometry.copyWith(
        fontSize: 24,
        height: 1.2,
        fontWeight: FontWeight.w700,
      ),
      headlineSmall: geometry.copyWith(
        fontSize: 20,
        height: 1.25,
        fontWeight: FontWeight.w700,
      ),
      titleLarge: geometry.copyWith(
        fontSize: 17,
        height: 1.3,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: geometry.copyWith(
        fontSize: 14,
        height: 1.35,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: geometry.copyWith(
        fontSize: 12,
        height: 1.35,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: geometry.copyWith(fontSize: 14, height: 1.4),
      bodyMedium: geometry.copyWith(fontSize: 13, height: 1.4),
      bodySmall: geometry.copyWith(fontSize: 11.5, height: 1.35),
      labelLarge: geometry.copyWith(
        fontSize: 13,
        height: 1.2,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: geometry.copyWith(
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w500,
      ),
      labelSmall: geometry.copyWith(
        fontSize: 10.5,
        height: 1.2,
        fontWeight: FontWeight.w500,
      ),
    ).apply(bodyColor: palette.text, displayColor: palette.text);
    const radius = AppRadius.mediumAll;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: _font,
      fontFamilyFallback: _fontFallback,
      scaffoldBackgroundColor: palette.background,
      canvasColor: palette.background,
      splashFactory: InkRipple.splashFactory,
      focusColor: palette.accentSoft.withValues(alpha: 0.22),
      visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      extensions: [palette],
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(color: palette.textDim, size: 18),
      dividerTheme: DividerThemeData(
        color: palette.line,
        thickness: 1,
        space: 1,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: palette.surfaceHigh,
          borderRadius: AppRadius.smallAll,
          border: Border.all(color: palette.line),
        ),
        textStyle: textTheme.bodySmall?.copyWith(color: palette.text),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.largeAll,
          side: BorderSide(color: palette.line),
        ),
        textStyle: textTheme.bodyMedium,
        labelTextStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 16,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.xlargeAll,
          side: BorderSide(color: palette.line),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: palette.textDim,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: palette.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: palette.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
        toolbarHeight: 56,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          palette.textDim.withValues(alpha: 0.42),
        ),
        thickness: const WidgetStatePropertyAll(4),
        radius: const Radius.circular(3),
        crossAxisMargin: 2,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surface,
        hintStyle: textTheme.bodyMedium?.copyWith(color: palette.textDim),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: palette.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: palette.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: palette.accent, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.accent,
          foregroundColor: palette.onAccent,
          disabledBackgroundColor: palette.surfaceHigh,
          disabledForegroundColor: palette.textDim,
          elevation: 0,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.text,
          side: BorderSide(color: palette.line),
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.accentSoft,
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: palette.textDim,
          minimumSize: const Size(34, 34),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: palette.surfaceHigh,
        disabledColor: palette.surface,
        side: BorderSide(color: palette.line),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.smallAll),
        labelStyle: textTheme.labelMedium?.copyWith(color: palette.text),
        secondaryLabelStyle: textTheme.labelMedium,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : palette.textDim,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accent
              : palette.surfaceHigh,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : palette.line,
        ),
        thumbIcon: const WidgetStatePropertyAll(null),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accent
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(palette.onAccent),
        side: BorderSide(color: palette.line, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
        visualDensity: VisualDensity.compact,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? palette.surfaceHigh
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? palette.text
                : palette.textDim,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: palette.line)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppRadius.mediumAll),
          ),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        textColor: palette.text,
        iconColor: palette.textDim,
        titleTextStyle: textTheme.titleMedium,
        subtitleTextStyle: textTheme.bodySmall?.copyWith(
          color: palette.textDim,
        ),
        minVerticalPadding: 6,
        visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.surfaceHigh,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: palette.text),
        actionTextColor: palette.accentSoft,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.mediumAll,
          side: BorderSide(color: palette.line),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.accent,
        linearTrackColor: palette.surfaceHigh,
      ),
    );
  }
}
