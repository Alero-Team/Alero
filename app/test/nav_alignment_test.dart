import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pb_app/ui/nav.dart';

void main() {
  testWidgets('unselected navigation glyphs stay geometrically centered with badges', (tester) async {
    int selected = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 340,
            child: StatefulBuilder(
              builder: (context, setState) => AleroNavBar(
                items: const [
                  NavData(Symbols.home_rounded, 'Inicio'),
                  NavData(Symbols.devices_rounded, 'Dispositivos', badge: 3),
                  NavData(Symbols.settings_rounded, 'Ajustes'),
                ],
                selected: selected,
                onSelect: (i) => setState(() => selected = i),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    for (final (name, glyph) in [
      ('Dispositivos', Symbols.devices_rounded),
      ('Ajustes', Symbols.settings_rounded),
    ]) {
      final center = tester.getCenter(find.byKey(ValueKey('alero-nav-$name')));
      final icon = tester.getCenter(find.byIcon(glyph));
      expect(icon.dx, closeTo(center.dx, 1));
      expect(icon.dy, closeTo(center.dy, 1));
    }

    await tester.tap(find.byKey(const ValueKey('alero-nav-Ajustes')));
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byKey(const ValueKey('alero-nav-Dispositivos')));
    final icon = tester.getCenter(find.byIcon(Symbols.devices_rounded));
    expect(icon.dx, closeTo(center.dx, 1));
    expect(icon.dy, closeTo(center.dy, 1));
  });
}
