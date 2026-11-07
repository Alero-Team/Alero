import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/hub.dart';
import 'package:pb_app/ui/send_preview.dart';
import 'package:pb_app/ui/theme.dart';

void main() {
  testWidgets(
    'send dialog shows the percentage and closes when the file is done',
    (t) async {
      final hub = Hub();
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(
            Colors.blue,
            DynamicSchemeVariant.tonalSpot,
            Brightness.light,
          ),
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () => showSendProgress(c, hub, 1),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Preparando…'), findsOneWidget);

      final x = Xfer('1', 'PC', 'foto.jpg', 1000, false);
      hub.active = [x];
      hub.notifyListeners();
      await t.pump();
      x.done = 500;
      hub.notifyListeners();
      await t.pump(); // the bar starts gliding towards 50 %
      await t.pump(const Duration(seconds: 1));
      expect(find.text('50 %'), findsOneWidget);

      hub.active = [];
      hub.notifyListeners();
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Enviando archivo'), findsNothing);
    },
  );
}
