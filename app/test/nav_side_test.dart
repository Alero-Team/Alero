import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pb_app/ui/nav.dart';

void main() {
  testWidgets('side bar is a compact column: icons centered, selection reported', (tester) async {
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerLeft,
          child: StatefulBuilder(
            builder: (context, setState) => AleroSideBar(
              items: const [
                NavData(Symbols.home_rounded, 'Inicio'),
                NavData(Symbols.devices_rounded, 'Dispositivos', badge: 3, gapBefore: true),
                NavData(Symbols.settings_rounded, 'Ajustes'),
              ],
              selected: selected,
              onSelect: (i) => setState(() => selected = i),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(AleroSideBar)).width, AleroSideBar.width);
    for (final (name, glyph) in [
      ('Inicio', Symbols.home_rounded),
      ('Dispositivos', Symbols.devices_rounded),
      ('Ajustes', Symbols.settings_rounded),
    ]) {
      final center = tester.getCenter(find.byKey(ValueKey('alero-side-$name')));
      final icon = tester.getCenter(find.byIcon(glyph));
      expect(icon.dx, closeTo(center.dx, 1));
      expect(icon.dy, closeTo(center.dy, 1));
    }

    await tester.tap(find.byKey(const ValueKey('alero-side-Ajustes')));
    await tester.pumpAndSettle();
    expect(selected, 2);
  });
}
