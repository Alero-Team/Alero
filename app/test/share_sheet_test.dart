import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/hub.dart';
import 'package:pb_app/native.dart';
import 'package:pb_app/src/rust/api/engine.dart' as pb;
import 'package:pb_app/ui/shell.dart';
import 'package:pb_app/ui/theme.dart';

const pc = pb.Peer(
  id: 'pc',
  name: 'Ordenador de prueba',
  addr: '',
  state: pb.PeerState.connected,
  trusted: true,
  detail: '',
);

Widget app(Hub hub) => MaterialApp(
  theme: buildTheme(
    Colors.blue,
    DynamicSchemeVariant.tonalSpot,
    Brightness.dark,
  ),
  home: Shell(hub, initialSection: Section.devices),
);

void main() {
  setUp(() {
    isPhone = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('pb/windows'),
          (_) async => null,
        );
  });
  tearDown(() => isPhone = false);

  testWidgets('a cold-start share opens without waiting for another Hub event', (
    tester,
  ) async {
    final hub = Hub()..share = Shared([Picked('foto.pdf', 'foto.pdf')], '');
    await tester.pumpWidget(app(hub));
    await tester.pumpAndSettle();
    expect(find.text('Enviar a…'), findsOneWidget);
    expect(find.text('foto.pdf'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await tester.pumpAndSettle();
    expect(hub.share, isNull);
  });

  testWidgets('a computer connecting while the share sheet is open appears', (
    tester,
  ) async {
    final hub = Hub()..share = Shared([], 'Texto compartido');
    await tester.pumpWidget(app(hub));
    await tester.pumpAndSettle();
    expect(
      find.text('Ningún dispositivo conectado. Abre la app en el ordenador.'),
      findsOneWidget,
    );
    hub.peers = [pc];
    hub.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, pc.name), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await tester.pumpAndSettle();
  });

  testWidgets('choosing a computer keeps the send confirmation open', (
    tester,
  ) async {
    final hub = Hub()..peers = [pc];
    await tester.pumpWidget(app(hub));
    await tester.pumpAndSettle();
    hub.share = Shared([Picked('foto.pdf', 'foto.pdf')], '');
    hub.notifyListeners();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, pc.name));
    await tester.pumpAndSettle();
    expect(find.text('Enviar a…'), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Enviar a ${pc.name}'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Enviar'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await tester.pumpAndSettle();
    expect(hub.share, isNull);
  });
}
