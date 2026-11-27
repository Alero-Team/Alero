import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/hub.dart';
import 'package:pb_app/ui/devices.dart';
import 'package:pb_app/ui/theme.dart';
import 'package:pb_app/ui/widgets.dart' show IconTile;

import 'v013_test.dart' show peer;

void main() {
  for (final width in [360.0, 800.0, 1440.0]) {
    testWidgets('paired actions align at width $width with large text', (
      tester,
    ) async {
      isPhone = true;
      addTearDown(() => isPhone = false);
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final hub = Hub()..peers = [peer];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(
            Colors.blue,
            DynamicSchemeVariant.tonalSpot,
            Brightness.dark,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.5),
            ),
            child: child!,
          ),
          home: Scaffold(body: DevicesScreen(hub)),
        ),
      );
      await tester.pumpAndSettle();
      final disconnect = find.widgetWithText(OutlinedButton, 'Desconectar');
      final forget = find.byTooltip('Olvidar ${peer.name}');
      expect(tester.getSize(disconnect).height, 48);
      expect(tester.getSize(forget).height, 48);
      expect(
        tester.getCenter(disconnect).dy,
        closeTo(tester.getCenter(forget).dy, .1),
      );
      // Wide window: the buttons sit in the device's own row, to the right of the name.
      if (width >= 800) {
        final name = find.text(peer.name).last;
        // Same row as the icon and the name, vertically centered on the text block.
        final dy = tester.getCenter(disconnect).dy;
        expect(
          find.byType(IconTile).evaluate().map(
            (e) => (tester.getCenter(find.byWidget(e.widget)).dy - dy).abs(),
          ),
          contains(lessThan(1)),
        );
        expect(tester.getTopLeft(disconnect).dx, greaterThan(tester.getTopRight(name).dx));
      }
      expect(find.byIcon(FluentIcons.arrow_upload_24_regular), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
