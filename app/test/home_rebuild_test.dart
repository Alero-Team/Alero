import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/remote.dart';
import 'package:pb_app/ui/home.dart';
import 'package:pb_app/ui/media.dart';
import 'package:pb_app/ui/notifications.dart';

import 'v013_test.dart' show TestHub, connected, peer, screen;

class _Hub extends TestHub {
  void poke() => notifyListeners();
}

MediaState playing(int position) => MediaState({
  'active': true,
  'title': 'Canción',
  'artist': 'Artista',
  'duration': 200000,
  'position': position,
  'playing': false,
  'actions': 0xFFFF,
});

void main() {
  testWidgets('a media tick rebuilds the player, not the notification feed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final base = connected();
    final hub = _Hub()
      ..peers = base.peers
      ..homeHidden =
          {'controls'} // its adb lookup would spawn a process
      ..info[peer.id] = PeerInfo({'kind': 'phone', 'notifAccess': true})
      ..media[peer.id] = playing(0)
      ..notifs[peer.id] = [
        PhoneNotif({'key': 'a', 'title': 'Ana', 'text': 'Hola'}),
        PhoneNotif({'key': 'b', 'title': 'Beto', 'text': 'Qué tal'}),
      ];
    // Rebuilt from the hub on every notify, as the shell does.
    await tester.pumpWidget(
      screen(
        ListenableBuilder(
          listenable: hub,
          builder: (_, _) => HomeScreen(hub, go: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NotificationsPanel), findsOneWidget);
    expect(find.byType(MediaPanel), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('Canción'), findsOneWidget);

    final rebuilt = <String, int>{};
    debugOnRebuildDirtyWidget = (e, _) {
      final n = e.widget.runtimeType.toString();
      rebuilt[n] = (rebuilt[n] ?? 0) + 1;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    // The hub notifies with nothing new for the player or the feed (an unrelated change).
    hub.poke();
    await tester.pump();
    expect(rebuilt['HomeScreen'], 1);
    expect(rebuilt['NotificationsPanel'], isNull);
    expect(rebuilt['MediaPanel'], isNull);

    // A media tick: only the player is rebuilt again, the feed's rows are not.
    rebuilt.clear();
    hub.media[peer.id] = playing(1000);
    hub.poke();
    await tester.pump();
    expect(rebuilt['HomeScreen'], 1);
    expect(rebuilt['MediaPanel'], 1);
    expect(rebuilt['NotificationsPanel'], isNull);
    expect(find.text('Ana'), findsOneWidget);
    debugOnRebuildDirtyWidget = null;
  });
}
