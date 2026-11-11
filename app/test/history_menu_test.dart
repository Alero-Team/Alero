import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/hub.dart';
import 'package:pb_app/src/rust/api/engine.dart' as pb;
import 'package:pb_app/ui/theme.dart';
import 'package:pb_app/ui/widgets.dart';

class _Hub extends Hub {
  final removed = <String>[];
  @override
  Future<void> removeHistory(String id) async => removed.add(id);
}

pb.HistoryItem _item(String path) => pb.HistoryItem(
  id: 'h1',
  peerId: 'p',
  peerName: 'Pixel',
  name: 'foto.jpg',
  size: BigInt.from(1000),
  incoming: true,
  status: 'done',
  code: '',
  message: '',
  time: BigInt.from(1700000000),
  path: path,
);

Widget _app(Widget child) => MaterialApp(
  theme: buildTheme(
    Colors.blue,
    DynamicSchemeVariant.tonalSpot,
    Brightness.dark,
  ),
  home: Scaffold(body: child),
);

Future<void> _rightClick(WidgetTester t) async {
  final g = await t.startGesture(
    t.getCenter(find.text('foto.jpg')),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await g.up();
  await t.pumpAndSettle();
}

void main() {
  testWidgets('right click on a transfer offers what can be done with it', (
    t,
  ) async {
    final hub = _Hub();
    await t.pumpWidget(_app(HistoryTile(_item(''), hub)));
    await _rightClick(t);
    // No file on this computer: only what needs none.
    expect(find.text('Abrir'), findsOneWidget);
    expect(find.text('Copiar el nombre'), findsOneWidget);
    expect(find.text('Mostrar en la carpeta'), findsNothing);
    expect(find.text('Eliminar el archivo'), findsNothing);
    await t.tap(find.text('Quitar del historial'));
    await t.pumpAndSettle();
    expect(hub.removed, ['h1']);
  });

  testWidgets('deleting the file asks first and then removes file and entry', (
    t,
  ) async {
    final hub = _Hub();
    late File file;
    // Real file access must run outside the fake-async zone of the test.
    await t.runAsync(() async {
      file = File(
        '${Directory.systemTemp.createTempSync('alero').path}/foto.jpg',
      )..writeAsStringSync('x');
    });
    await t.pumpWidget(_app(HistoryTile(_item(file.path), hub)));
    await _rightClick(t);
    expect(find.text('Mostrar en la carpeta'), findsOneWidget);
    await t.tap(find.text('Eliminar el archivo'));
    await t.pumpAndSettle();
    expect(file.existsSync(), isTrue, reason: 'nothing goes before confirming');
    await t.tap(find.text('Eliminar'));
    await t.pumpAndSettle();
    expect(file.existsSync(), isFalse);
    expect(hub.removed, ['h1']);
  }, skip: Platform.isAndroid);
}
