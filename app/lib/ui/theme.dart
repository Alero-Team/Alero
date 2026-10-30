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
    signal: s.primary,
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
  static const card = 28.0, tile = 16.0, chip = 12.0, pill = 999.0;
}

/// Wider than this: side navigation (desktop, tablets). Narrower: floating bottom bar.
const wideLayout = 840.0;

/// Used when the system offers no color (older Android, Linux without a portal).
const brandGraphite = Color(0xFF111315);
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

/// The color scheme for a seed. [amoled] (dark only) swaps the grey surfaces for pure black and near-black steps:
/// the accent colors, text and outline roles are untouched, so contrast and identity stay as in the dark theme.
ColorScheme schemeFor(
  Color seed,
  DynamicSchemeVariant variant,
  Brightness b, {
  bool amoled = false,
}) {
  final s = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: b,
    dynamicSchemeVariant: variant,
  );
  if (b == Brightness.light) {
    return s.copyWith(
      surface: const Color(0xFFF4F5F6),
      surfaceDim: const Color(0xFFE4E6E8),
      surfaceBright: Colors.white,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: Colors.white,
      surfaceContainer: const Color(0xFFF0F1F2),
      surfaceContainerHigh: const Color(0xFFE8EAED),
      surfaceContainerHighest: const Color(0xFFDFE2E6),
      onSurface: brandGraphite,
      onSurfaceVariant: const Color(0xFF4C535C),
      outline: const Color(0xFF707780),
      outlineVariant: const Color(0xFFCDD1D6),
    );
  }
  final neutral = s.copyWith(
    surface: brandGraphite,
    surfaceDim: brandGraphite,
    surfaceBright: const Color(0xFF353A40),
    surfaceContainerLowest: const Color(0xFF0B0D0F),
    surfaceContainerLow: const Color(0xFF181B1F),
    surfaceContainer: const Color(0xFF1E2226),
    surfaceContainerHigh: const Color(0xFF262A2F),
    surfaceContainerHighest: const Color(0xFF30353B),
    onSurface: const Color(0xFFF5F5F2),
    onSurfaceVariant: const Color(0xFFB8BEC6),
    outline: const Color(0xFF858D98),
    outlineVariant: const Color(0xFF353B43),
  );
  if (!amoled) return neutral;
  return neutral.copyWith(
    surface: Colors.black,
    surfaceDim: Colors.black,
    surfaceBright: const Color(0xFF242424),
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: const Color(0xFF0C0C0C),
    surfaceContainer: const Color(0xFF131313),
    surfaceContainerHigh: const Color(0xFF1B1B1B),
    surfaceContainerHighest: const Color(0xFF242424),
    // Hairlines must stay visible against black.
    outlineVariant: const Color(0xFF383838),
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
  final pill = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Radii.pill),
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
        side: BorderSide(color: p.line.withValues(alpha: 0.55)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: tap,
        padding: const EdgeInsets.symmetric(horizontal: Gap.l + 4),
        shape: pill,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: tap,
        padding: const EdgeInsets.symmetric(horizontal: Gap.l + 4),
        shape: pill,
        foregroundColor: p.ink,
        side: BorderSide(color: p.line),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: tap,
        shape: pill,
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
      color: p.signal,
      linearTrackColor: p.alt,
      linearMinHeight: 6,
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
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
