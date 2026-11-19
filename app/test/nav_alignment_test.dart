import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
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
                  NavData(FluentIcons.home_24_regular, 'Inicio'),
                  NavData(FluentIcons.phone_desktop_24_regular, 'Dispositivos', badge: 3),
                  NavData(FluentIcons.settings_24_regular, 'Ajustes'),
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
      ('Dispositivos', FluentIcons.phone_desktop_24_regular),
      ('Ajustes', FluentIcons.settings_24_regular),
    ]) {
      final center = tester.getCenter(find.byKey(ValueKey('alero-nav-$name')));
      final icon = tester.getCenter(find.byIcon(glyph));
      expect(icon.dx, closeTo(center.dx, 1));
      expect(icon.dy, closeTo(center.dy, 1));
    }

    await tester.tap(find.byKey(const ValueKey('alero-nav-Ajustes')));
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byKey(const ValueKey('alero-nav-Dispositivos')));
    final icon = tester.getCenter(find.byIcon(FluentIcons.phone_desktop_24_regular));
    expect(icon.dx, closeTo(center.dx, 1));
    expect(icon.dy, closeTo(center.dy, 1));
  });
}
