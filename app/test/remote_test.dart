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
}
