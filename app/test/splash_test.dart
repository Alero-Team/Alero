import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pb_app/ui/brand.dart';

Widget _app({required bool reduced}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: const Scaffold(body: Center(child: AleroSplash())),
  ),
);

void main() {
  testWidgets('splash shows the wordmark after its animation', (t) async {
    await t.pumpWidget(_app(reduced: false));
    expect(t.widget<Opacity>(find.byType(Opacity)).opacity, 0);
    await t.pump(const Duration(seconds: 2));
    expect(t.widget<Opacity>(find.byType(Opacity)).opacity, 1);
  });

  testWidgets('reduced motion shows the final frame at once', (t) async {
    await t.pumpWidget(_app(reduced: true));
    await t.pump();
    expect(t.widget<Opacity>(find.byType(Opacity)).opacity, 1);
    await t.pump(const Duration(seconds: 2));
    expect(t.widget<AleroMark>(find.byType(AleroMark)).dim, 0);
  });

  testWidgets(
    'after its entrance the mark keeps loading until it is replaced',
    (t) async {
      await t.pumpWidget(_app(reduced: false));
      await t.pump(
        const Duration(seconds: 2),
      ); // the entrance ends; the loop starts with the next frame
      await t.pump(const Duration(milliseconds: 400));
      final a = t.widget<AleroMark>(find.byType(AleroMark));
      await t.pump(const Duration(milliseconds: 400));
      final b = t.widget<AleroMark>(find.byType(AleroMark));
      expect(a.dim, 1);
      expect(b.sweep, isNot(a.sweep));
      await t.pump(const Duration(seconds: 5));
      expect(t.binding.hasScheduledFrame, isTrue);
    },
  );
}
