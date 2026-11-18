import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/hub.dart';
import 'package:pb_app/ui/remote_ui.dart';
import 'package:pb_app/remote.dart';

class RecordingHub extends Hub {
  final sent = <(String, Map<String, Object?>)>[];
  @override
  Future<void> sendMessage(
    String peer,
    String kind,
    Map<String, Object?> body,
  ) async {
    sent.add((kind, body));
  }
}

void main() {
  testWidgets('double tap holds left through movement then releases', (
    tester,
  ) async {
    final hub = RecordingHub();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Touchpad(hub, 'pc', height: 300))),
    );
    final center = tester.getCenter(find.byType(Touchpad));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 80));
    final second = await tester.startGesture(center);
    await tester.pump();
    expect(hub.sent.last.$1, 'pb.x.remote.button');
    expect(hub.sent.last.$2, {'button': 'left', 'down': true});
    await second.moveBy(const Offset(30, 20));
    await tester.pump(const Duration(milliseconds: 20));
    expect(hub.sent.any((m) => m.$1 == 'pb.x.remote.move'), isTrue);
    await second.up();
    expect(hub.sent.last.$1, 'pb.x.remote.button');
    expect(hub.sent.last.$2, {'button': 'left', 'down': false});
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('two fingers scroll only; remaining finger cannot move cursor', (
    tester,
  ) async {
    final hub = RecordingHub();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Touchpad(hub, 'pc', height: 300))),
    );
    final center = tester.getCenter(find.byType(Touchpad));
    final a = await tester.startGesture(center, pointer: 1);
    final b = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 2,
    );
    await a.moveBy(const Offset(0, 60));
    await b.moveBy(const Offset(0, 60));
    await tester.pump(const Duration(milliseconds: 20));
    await b.up();
    await a.moveBy(const Offset(50, 0));
    await a.up();
    expect(hub.sent.map((m) => m.$1), everyElement('pb.x.remote.scroll'));
    expect(hub.sent, isNotEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('cancel and app background release a held mouse button', (
    tester,
  ) async {
    final hub = RecordingHub();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: MouseActionBar(hub, 'pc'))),
    );
    final down = await tester.startGesture(
      tester.getCenter(find.text('Izquierdo')),
    );
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.byType(Tooltip), findsNothing);
    expect(hub.sent.last.$2['down'], true);
    await down.cancel();
    expect(hub.sent.last.$2['down'], false);
    await tester.startGesture(
      tester.getCenter(find.text('Derecho')),
      pointer: 2,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(hub.sent.last.$1, 'pb.x.remote.button');
    expect(hub.sent.last.$2, {'button': 'right', 'down': false});
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('keyboard button opens the keyboard instead of a tooltip', (
    tester,
  ) async {
    final hub = RecordingHub();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: MouseActionBar(hub, 'pc'))),
    );
    await tester.tap(find.text('Teclado'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hola');
    expect(hub.sent.last.$1, 'pb.x.remote.text');
    expect(hub.sent.last.$2, {'text': 'hola'});
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('pinching zooms instead of scrolling or right-clicking', (
    tester,
  ) async {
    final hub = RecordingHub();
    var zoom = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Touchpad(hub, 'pc', height: 400, onZoom: (f) => zoom *= f),
        ),
      ),
    );
    final c = tester.getCenter(find.byType(Touchpad));
    final a = await tester.startGesture(c - const Offset(40, 0));
    final b = await tester.startGesture(c + const Offset(40, 0));
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-8, 0));
      await b.moveBy(const Offset(8, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 50));
    expect(zoom, greaterThan(1.5));
    expect(hub.sent.where((m) => m.$1 == 'pb.x.remote.click'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('what was typed survives closing the keyboard and coming back', (
    tester,
  ) async {
    final hub = RecordingHub();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: MouseActionBar(hub, 'pc-draft'))),
    );
    await tester.tap(find.text('Teclado'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hola mundo');
    // Closing the sheet (swipe down / back) used to empty the field.
    Navigator.of(tester.element(find.byType(TextField))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Teclado'));
    await tester.pumpAndSettle();
    expect(find.text('hola mundo'), findsOneWidget);
    // Going on from where it was: only the new letters reach the computer.
    hub.sent.clear();
    await tester.enterText(find.byType(TextField), 'hola mundo!');
    expect(hub.sent.map((m) => m.$1), ['pb.x.remote.text']);
    expect(hub.sent.last.$2, {'text': '!'});
    // Emptying the field deletes nothing on the computer.
    hub.sent.clear();
    await tester.tap(find.byTooltip('Vaciar el campo (no borra nada en el ordenador)'));
    await tester.pump();
    expect(hub.sent, isEmpty);
    expect(find.text('hola mundo!'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'mouse selection persists after lifting and releases on next tap',
    (tester) async {
      final hub = RecordingHub();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: MouseActionBar(hub, 'pc'))),
      );
      await tester.tap(find.text('Izquierdo'));
      await tester.pump();
      expect(hub.remote.buttonHeld('pc', 'left'), true);
      expect(find.text('Soltar izq.'), findsOneWidget);
      await tester.tap(find.text('Soltar izq.'));
      await tester.pump();
      expect(hub.remote.buttonHeld('pc', 'left'), false);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('playback ignores remote clock skew and respects transport actions', () {
    final m = MediaState({
      'active': true,
      'playing': true,
      'position': 12000,
      'duration': 100000,
      'at': 1,
      'speed': 1.5,
      'actions': 2,
    });
    expect(m.positionNow, inInclusiveRange(12000, 12100));
    expect(m.supports(2), true);
    expect(m.supports(256), false);
    final paused = MediaState({'playing': false, 'position': 5000});
    expect(paused.positionNow, 5000);
  });

  test('Wi-Fi label shows generation, band, speed and signal', () {
    final i = PeerInfo({
      'network': 'wifi',
      'wifi': {'mhz': 5180, 'mbps': 1201, 'rssi': -55, 'standard': 6},
    });
    expect(i.wifiLabel, 'Wi-Fi 6 · 5 GHz · 1201 Mbps · señal buena');
    expect(PeerInfo({'wifi': {'mhz': 2437}}).wifiLabel, '2,4 GHz');
    expect(PeerInfo({'network': 'wifi'}).wifiLabel, '');
  });
}
