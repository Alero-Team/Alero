import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/ui/theme.dart';

/// WCAG 2.1 contrast ratio.
double ratio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

void main() {
  // Windows default blue, the user's magenta, and awkward ones (yellow, green, red, grey).
  const seeds = [
    Color(0xFF0078D4),
    Color(0xFFFF00FF),
    Color(0xFFFFD400),
    Color(0xFF00C853),
    Color(0xFFE81123),
    Color(0xFF808080),
  ];
  for (final seed in seeds) {
    for (final b in Brightness.values) {
      test('contrast ${seed.toARGB32().toRadixString(16)} $b', () {
        for (final amoled in [false, true]) {
        final p = Palette.of(schemeFor(seed, DynamicSchemeVariant.tonalSpot, b, amoled: amoled));
        // Text: 4.5:1. Indicators (dots, progress, icons that carry state): 3:1.
        for (final (fg, bg, min, what) in [
          (p.ink, p.bg, 4.5, 'ink/bg'),
          (p.ink, p.surface, 4.5, 'ink/surface'),
          (p.muted, p.surface, 4.5, 'muted/surface'),
          (p.muted, p.alt, 4.5, 'muted/alt'),
          (p.onAccent, p.accent, 4.5, 'onAccent/accent'),
          (p.onPrimary, p.primary, 4.5, 'onPrimary/primary'),
          (p.signal, p.surface, 3.0, 'signal/surface'),
          (p.signal, p.alt, 3.0, 'signal/alt'),
          (p.danger, p.surface, 4.5, 'danger/surface'),
        ]) {
          expect(ratio(fg, bg), greaterThanOrEqualTo(min), reason: '$what amoled=$amoled');
        }
        if (amoled && b == Brightness.dark) {
          // The page really is black, and cards/lines stay distinguishable from it.
          expect(p.bg, Colors.black);
          expect(ratio(p.line, Colors.black), greaterThanOrEqualTo(1.5), reason: 'hairline on black');
        }
        }
      });
    }
  }
}
