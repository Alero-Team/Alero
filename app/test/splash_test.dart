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
  });
}
