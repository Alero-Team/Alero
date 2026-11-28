import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/ui/theme.dart';

void main() {
  const seed = Color(0xFF808080);
  const v = DynamicSchemeVariant.tonalSpot;

  test('background tints the surfaces and keeps the text', () {
    for (final b in Brightness.values) {
      final plain = schemeFor(seed, v, b);
      final blue = schemeFor(seed, v, b, background: const Color(0xFF2563EB));
      expect(blue.surface, isNot(plain.surface));
      expect(blue.onSurface, plain.onSurface);
      expect(contrast(blue.onSurface, blue.surface), greaterThan(7));
      expect(blue.primary, plain.primary, reason: 'the accent stays Alero\'s');
    }
  });

  test('accent replaces the monochrome one and stays readable', () {
    for (final b in Brightness.values) {
      for (final c in const [Color(0xFFFDD663), Color(0xFF2563EB)]) {
        final s = schemeFor(seed, v, b, accent: c, amoled: true);
        expect(s.primary, isNot(schemeFor(seed, v, b).primary));
        expect(contrast(s.onPrimary, s.primary), greaterThan(4.5));
        expect(contrast(s.primary, s.surface), greaterThanOrEqualTo(3));
      }
    }
  });
}
