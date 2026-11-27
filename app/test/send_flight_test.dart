import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/ui/send_preview.dart';
import 'package:pb_app/ui/theme.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Scaffold(
      body: Center(child: SizedBox(width: 400, child: child)),
    ),
  ),
);

void main() {
  for (final phone in [false, true]) {
    testWidgets(
      'the receiver fills, then the tick pops and it rests (phone: $phone)',
      (t) async {
        isPhone = phone;
        addTearDown(() => isPhone = false);
        for (final incoming in [false, true]) {
          await t.pumpWidget(
            _app(SendFlight(progress: 0, done: false, incoming: incoming)),
          );
          await t.pump(const Duration(milliseconds: 300));
          expect(
            t.binding.hasScheduledFrame,
            isTrue,
            reason: 'the arrow bobs while waiting',
          );
          await t.pumpWidget(
            _app(SendFlight(progress: .5, done: false, incoming: incoming)),
          );
          await t.pump(const Duration(milliseconds: 600));
          await t.pumpWidget(
            _app(SendFlight(progress: 1, done: true, incoming: incoming)),
          );
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          await t.pumpWidget(
            _app(
              SendFlight(
                progress: 1,
                done: true,
                ok: false,
                incoming: incoming,
              ),
            ),
          );
          await t.pumpAndSettle();
        }
      },
    );
  }

  testWidgets('reduced motion draws still frames', (t) async {
    await t.pumpWidget(
      _app(const SendFlight(progress: .4, done: false), reduced: true),
    );
    await t.pump();
    expect(t.binding.hasScheduledFrame, isFalse);
  });
}
