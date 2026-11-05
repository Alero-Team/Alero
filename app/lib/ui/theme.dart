import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Neutral graphite surfaces with the user's system accent on actions and status.
/// Text/background pairs are verified in light, dark and AMOLED modes.
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.bg,
    required this.surface,
    required this.alt,
    required this.ink,
    required this.muted,
    required this.line,
    required this.accent,
    required this.onAccent,
    required this.signal,
    required this.danger,
    required this.primary,
    required this.onPrimary,
  });

  factory Palette.of(ColorScheme s) => Palette(
    bg: s.surface,
    surface: s.surfaceContainerLow,
    alt: s.surfaceContainerHighest,
    ink: s.onSurface,
    muted: s.onSurfaceVariant,
    line: s.outlineVariant,
    accent: s.primaryContainer,
    onAccent: s.onPrimaryContainer,
    signal: s.brightness == Brightness.light ? Tokens.light.success : Tokens.dark.success,
    danger: s.error,
    primary: s.primary,
    onPrimary: s.onPrimary,
  );

  final Color bg, surface, alt, ink, muted, line;

  /// Tonal accent fill (selected nav, highlights) and the text/icon color that goes on it.
  final Color accent, onAccent;

  /// Accent readable on surfaces: connected dot, progress, success icons.
  final Color signal;
  final Color danger;
  final Color primary, onPrimary;

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(Palette? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

/// Spacing (4/8 rhythm), radii and sizes.
class Gap {
  static const xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 24.0, xxl = 32.0;
}

class Radii {
  static const card = 16.0, tile = 12.0, chip = 10.0, button = 10.0, dialog = 20.0, pill = 999.0;
}

/// Wider than this: side navigation (desktop, tablets). Narrower: floating bottom bar.
const wideLayout = 840.0;

/// Used when the system offers no color (older Android, Linux without a portal).
const brandGraphite = Color(0xFF1B1B1D);
const fallbackSeed = Color(0xFF50565E);

/// Reads the system color once (and again when the app comes back to the front).
class SystemColor extends ValueNotifier<(Color, DynamicSchemeVariant)> {
  SystemColor() : super((fallbackSeed, DynamicSchemeVariant.tonalSpot));

  Future<void> load() async {
    try {
      final core = await DynamicColorPlugin.getCorePalette();
      if (core != null) {
        // Android 12+: the system palette's key color, expanded the way the system does it.
        value = (Color(core.primary.get(40)), DynamicSchemeVariant.tonalSpot);
        return;
      }
      final accent = await DynamicColorPlugin.getAccentColor();
      // Windows: the accent's hue, expanded like Material You (fidelity made saturated accents garish).
      if (accent != null) value = (accent, DynamicSchemeVariant.tonalSpot);
    } on PlatformException {
      // keep the fallback
    }
  }
}

const font = 'GoogleSansFlex';

/// Variable font: weight must also be passed as an axis.
TextStyle? weight(TextStyle? s, int w) => s?.copyWith(
  fontWeight: FontWeight.values[(w ~/ 100 - 1).clamp(0, 8)],
  fontVariations: [FontVariation('wght', w.toDouble())],
);

/// Alero Fluent Identity tokens (light, dark, AMOLED): neutral surfaces and a monochrome accent, black on light
/// and white on dark. Status keeps its own colors; the system accent is not used, so the app looks the same
/// everywhere.
class Tokens {
  const Tokens({
    required this.bg,
    required this.surface,
    required this.elevated,
    required this.secondary,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.text2,
    required this.accent,
    required this.onAccent,
    required this.success,
    required this.error,
  });
  final Color bg, surface, elevated, secondary, border, borderStrong;
  final Color text, text2, accent, onAccent, success, error;

  static const light = Tokens(
    bg: Color(0xFFF2F2F2), surface: Color(0xFFFFFFFF), elevated: Color(0xFFFFFFFF),
    secondary: Color(0xFFF4F4F4), border: Color(0xFFE3E3E3), borderStrong: Color(0xFFCFCFCF),
    text: Color(0xFF111111), text2: Color(0xFF5B5B5B),
    accent: Color(0xFF111111), onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1B7A3D), error: Color(0xFFC42B1C),
  );
  static const dark = Tokens(
    bg: Color(0xFF1B1B1B), surface: Color(0xFF262626), elevated: Color(0xFF2E2E2E),
    secondary: Color(0xFF2F2F2F), border: Color(0xFF383838), borderStrong: Color(0xFF4A4A4A),
    text: Color(0xFFF4F4F4), text2: Color(0xFFA9A9A9),
    accent: Color(0xFFF4F4F4), onAccent: Color(0xFF111111),
    success: Color(0xFF4CC27A), error: Color(0xFFFF7B72),
  );
  static const amoled = Tokens(
    bg: Color(0xFF000000), surface: Color(0xFF0F0F0F), elevated: Color(0xFF1A1A1A),
    secondary: Color(0xFF181818), border: Color(0xFF242424), borderStrong: Color(0xFF3A3A3A),
    text: Color(0xFFFFFFFF), text2: Color(0xFFA6A6A6),
    accent: Color(0xFFFFFFFF), onAccent: Color(0xFF000000),
    success: Color(0xFF52D184), error: Color(0xFFFF8078),
  );
}

/// The color scheme for a brightness. [amoled] (dark only) uses pure black and near-black steps.
/// [seed] only tints the roles Alero does not set (tertiary), the accent stays monochrome.
ColorScheme schemeFor(
  Color seed,
  DynamicSchemeVariant variant,
  Brightness b, {
  bool amoled = false,
}) {
  final k = b == Brightness.light ? Tokens.light : (amoled ? Tokens.amoled : Tokens.dark);
  return ColorScheme.fromSeed(
    seedColor: seed,
    brightness: b,
    dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
  ).copyWith(
    primary: k.accent,
    onPrimary: k.onAccent,
    primaryContainer: k.secondary,
    onPrimaryContainer: k.text,
    secondary: k.text2,
    onSecondary: k.bg,
    // Tonal buttons and selections: one step off the card (white on white was invisible in light).
    secondaryContainer: b == Brightness.light ? k.border : k.elevated,
    onSecondaryContainer: k.text,
    inversePrimary: k.bg,
    surface: k.bg,
    surfaceDim: k.bg,
    surfaceBright: k.elevated,
    surfaceContainerLowest: k.bg,
    surfaceContainerLow: k.surface,
    surfaceContainer: k.secondary,
    surfaceContainerHigh: k.elevated,
    surfaceContainerHighest: k.borderStrong.withValues(alpha: 0.45),
    onSurface: k.text,
    onSurfaceVariant: k.text2,
    outline: k.borderStrong,
    outlineVariant: k.border,
    inverseSurface: k.text,
    onInverseSurface: k.bg,
    error: k.error,
    surfaceTint: Colors.transparent,
  );
}

ThemeData buildTheme(
  Color seed,
  DynamicSchemeVariant variant,
  Brightness b, {
  bool amoled = false,
}) {
  final scheme = schemeFor(seed, variant, b, amoled: amoled);
  final p = Palette.of(scheme);
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: b,
    fontFamily: font,
  );
  final t = base.textTheme;
  // Material 3 type scale (not enlarged); emphasis comes from weight, as in M3 Expressive.
  final text = t
      .copyWith(
        displaySmall: weight(t.displaySmall, 600),
        headlineMedium: weight(t.headlineMedium, 600),
        headlineSmall: weight(t.headlineSmall, 600),
        titleLarge: weight(t.titleLarge, 600),
        titleMedium: weight(t.titleMedium, 600),
        titleSmall: weight(t.titleSmall, 600),
        labelLarge: weight(t.labelLarge, 600),
        labelMedium: weight(t.labelMedium, 500),
        bodyLarge: weight(t.bodyLarge, 400),
        bodyMedium: weight(t.bodyMedium, 400),
        bodySmall: weight(t.bodySmall, 400),
      )
      .apply(bodyColor: p.ink, displayColor: p.ink, fontFamily: font);
  final corner = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Radii.button),
  );
  const tap = Size(48, 48);
  return base.copyWith(
    extensions: [p],
    scaffoldBackgroundColor: p.bg,
    textTheme: text,
    iconTheme: IconThemeData(
      color: p.ink,
      size: 20,
      weight: 400,
      fill: 0,
      opticalSize: 20,
    ),
    dividerTheme: DividerThemeData(color: p.line, space: 1, thickness: 1),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      // A discreet border keeps cards readable on any surface, black included.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: p.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: tap,
        padding: const EdgeInsets.symmetric(horizontal: Gap.l + 4),
        shape: corner,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: tap,
        padding: const EdgeInsets.symmetric(horizontal: Gap.l + 4),
        shape: corner,
        foregroundColor: p.ink,
        side: BorderSide(color: p.line),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: tap,
        shape: corner,
        textStyle: text.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: tap, foregroundColor: p.ink),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.alt,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.tile),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.tile),
        borderSide: BorderSide(color: p.primary, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Gap.l,
        vertical: Gap.m,
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.ink,
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodyMedium?.copyWith(color: p.muted),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.primary,
      linearTrackColor: p.alt,
      linearMinHeight: 6,
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outline),
        borderRadius: BorderRadius.circular(Radii.dialog),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: text.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      actionTextColor: scheme.inversePrimary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.tile),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      textStyle: text.bodySmall?.copyWith(color: scheme.onInverseSurface),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: p.alt,
      height: 68,
      elevation: 0,
      labelTextStyle: WidgetStatePropertyAll(text.labelMedium),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          size: 22,
          color: s.contains(WidgetState.selected) ? p.ink : p.muted,
          fill: s.contains(WidgetState.selected) ? 1 : 0,
        ),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}

extension PaletteOf on BuildContext {
  Palette get pal => Theme.of(this).extension<Palette>()!;
}
