import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pb_app/ui/nav.dart';

void main() {
  testWidgets('the bar shrinks while compact and returns to its size', (
    tester,
  ) async {
    final compact = ValueNotifier(false);
    addTearDown(compact.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 340,
              child: AleroNavBar(
                items: const [
                  NavData(Symbols.home_rounded, 'Inicio'),
                  NavData(Symbols.devices_rounded, 'Dispositivos'),
                  NavData(Symbols.settings_rounded, 'Ajustes'),
                ],
                selected: 0,
                onSelect: (_) {},
                compact: compact,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The scale applies to what is inside the bar's Transform, so measure the bar's own box (a child of it).
    final box = find
        .descendant(
          of: find.byType(AleroNavBar),
          matching: find.byType(DecoratedBox),
        )
        .first;
    double width() => tester.getBottomRight(box).dx - tester.getTopLeft(box).dx;

    final bottom = tester.getBottomLeft(box).dy;
    final full = width();
    expect(full, closeTo(340, 1));

    compact.value = true;
    await tester.pumpAndSettle();
    expect(width(), closeTo(full * AleroNavBar.compactScale, 1));
    // It shrinks towards the bottom edge instead of floating up.
    expect(tester.getBottomLeft(box).dy, closeTo(bottom, 1));

    compact.value = false;
    await tester.pumpAndSettle();
    expect(width(), closeTo(full, 1));
  });
}
