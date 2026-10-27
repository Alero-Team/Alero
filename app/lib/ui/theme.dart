import 'package:flutter/material.dart';

/// Design tokens (G5). Neutral solid surfaces and one lime accent. Every text/indicator pair was measured
/// against WCAG AA (see docs/design/Sistema.md); change a color only after re-measuring.
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.bg,
    required this.surface,
    required this.alt,
    required this.ink,
    required this.muted,
    required this.line,
    required this.accent,
    required this.signal,
    required this.danger,
    required this.primary,
    required this.onPrimary,
  });

  final Color bg, surface, alt, ink, muted, line;

  /// Lime fill (selected nav, highlights). Text on it is always [onAccent].
  final Color accent;

  /// Lime that is readable on surfaces: connected dot, progress, success icons.
  final Color signal;
  final Color danger;

  /// Main call to action: ink pill in light, lime pill in dark.
  final Color primary, onPrimary;

  static const onAccent = Color(0xFF111111);

  static const light = Palette(
    bg: Color(0xFFF3F3F0),
    surface: Color(0xFFFFFFFF),
    alt: Color(0xFFEBEBE6),
    ink: Color(0xFF111111),
    muted: Color(0xFF5C5C57),
    line: Color(0xFFD9D9D3),
    accent: Color(0xFFC8F031),
    signal: Color(0xFF3D6B0B),
    danger: Color(0xFFB42318),
    primary: Color(0xFF111111),
    onPrimary: Color(0xFFFFFFFF),
  );

  static const dark = Palette(
    bg: Color(0xFF0C0C0D),
    surface: Color(0xFF18181A),
    alt: Color(0xFF242427),
    ink: Color(0xFFF2F2EF),
    muted: Color(0xFFA3A39D),
    line: Color(0xFF34343A),
    accent: Color(0xFFC8F031),
    signal: Color(0xFFC8F031),
    danger: Color(0xFFFF8A7A),
    primary: Color(0xFFC8F031),
    onPrimary: Color(0xFF111111),
  );

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(Palette? other, double t) => t < 0.5 || other == null ? this : other;
}

/// Spacing (4/8 rhythm), radii and sizes.
class Gap {
  static const xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 24.0, xxl = 32.0;
}

class Radii {
  static const card = 24.0, tile = 16.0, chip = 12.0, pill = 999.0;
}

/// Wider than this: side navigation (desktop, tablets). Narrower: floating bottom bar.
const wideLayout = 840.0;

ThemeData buildTheme(Palette p, Brightness b) {
  final scheme = ColorScheme(
    brightness: b,
    primary: p.primary,
    onPrimary: p.onPrimary,
    secondary: p.signal,
    onSecondary: b == Brightness.dark ? Palette.onAccent : Colors.white,
    secondaryContainer: p.accent,
    onSecondaryContainer: Palette.onAccent,
    tertiary: p.signal,
    onTertiary: Palette.onAccent,
    error: p.danger,
    onError: b == Brightness.dark ? Palette.onAccent : Colors.white,
    surface: p.surface,
    onSurface: p.ink,
    onSurfaceVariant: p.muted,
    surfaceContainerLowest: p.surface,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.alt,
    surfaceContainerHighest: p.alt,
    outline: p.muted,
    outlineVariant: p.line,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: b);
  final text = base.textTheme
      .apply(bodyColor: p.ink, displayColor: p.ink)
      .copyWith(
        headlineMedium: base.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
        titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      );
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.pill));
  const tap = Size(48, 48);
  return base.copyWith(
    extensions: [p],
    scaffoldBackgroundColor: p.bg,
    textTheme: text,
    dividerTheme: DividerThemeData(color: p.line, space: 1, thickness: 1),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: p.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: tap,
        padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
        shape: pill,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: tap,
        padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
        shape: pill,
        foregroundColor: p.ink,
        side: BorderSide(color: p.line),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: tap, shape: pill, foregroundColor: p.ink, textStyle: text.labelLarge),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: tap, foregroundColor: p.ink),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.alt,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.tile), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.tile),
        borderSide: BorderSide(color: p.ink, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Palette.onAccent : p.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.alt),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.signal : p.muted),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.signal,
      linearTrackColor: p.alt,
      linearMinHeight: 6,
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.card)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.ink,
      contentTextStyle: text.bodyMedium?.copyWith(color: p.bg),
      actionTextColor: p.accent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.tile)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface,
      indicatorColor: p.accent,
      height: 68,
      elevation: 0,
      labelTextStyle: WidgetStatePropertyAll(text.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? Palette.onAccent : p.ink),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.surface,
      indicatorColor: p.accent,
      selectedIconTheme: const IconThemeData(color: Palette.onAccent),
      unselectedIconTheme: IconThemeData(color: p.ink),
      selectedLabelTextStyle: text.labelLarge,
      unselectedLabelTextStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w500, color: p.muted),
    ),
  );
}

extension PaletteOf on BuildContext {
  Palette get pal => Theme.of(this).extension<Palette>()!;
}
