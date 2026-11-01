import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/fs_client.dart';
import 'package:pb_app/hub.dart';
import 'package:pb_app/remote.dart';
import 'package:pb_app/src/rust/api/engine.dart' as pb;
import 'package:pb_app/ui/home.dart';
import 'package:pb_app/ui/media.dart';
import 'package:pb_app/ui/notifications.dart';
import 'package:pb_app/ui/setup.dart';
import 'package:pb_app/ui/shell.dart';
import 'package:pb_app/ui/theme.dart';

class TestHub extends Hub {
  final sent = <(String, String, Map<String, Object?>)>[];
  @override
  Future<void> sendMessage(
    String peer,
    String kind,
    Map<String, Object?> body,
  ) async {
    sent.add((peer, kind, body));
  }

  @override
  Future<void> setName(String value) async {
    name = value;
  }
}

const peer = pb.Peer(
  id: 'peer',
  name: 'Laptop',
  addr: '127.0.0.1',
  state: pb.PeerState.connected,
  trusted: true,
  detail: '',
);
TestHub connected() => TestHub()
  ..peers = [peer]
  ..info[peer.id] = PeerInfo({
    'kind': 'computer',
    'remote': {'allowed': true, 'media': true, 'input': true},
  })
  ..notifs[peer.id] = [
    PhoneNotif({'key': 'n', 'replyable': true}),
  ];

final testTheme = buildTheme(
  Colors.blue,
  DynamicSchemeVariant.tonalSpot,
  Brightness.light,
);

Widget screen(Widget child) => MaterialApp(
  theme: testTheme,
  home: Scaffold(body: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('pb/windows'),
          (call) async => false,
        );
  });
  test('old notifications have no reply field and remain non-replyable', () {
    expect(PhoneNotif({'key': 'old'}).replyable, isFalse);
    expect(PhoneNotif({'replyable': true}).replyable, isTrue);
    expect(PhoneNotif({'replyable': false}).replyable, isFalse);
  });

  test('folder counts distinguish unknown, empty, real and capped', () {
    expect(FsEntry({'dir': true, 'size': -1}).itemCount, '—');
    expect(FsEntry({'dir': true, 'size': 0}).itemCount, '0 elementos');
    expect(FsEntry({'dir': true, 'size': 3}).itemCount, '3 elementos');
    expect(FsEntry({'dir': true, 'size': 1000}).itemCount, '999+ elementos');
  });

  test(
    'reply waits for a result from the matching peer, key and request',
    () async {
      final hub = connected();
      var complete = false;
      final reply = hub
          .replyNotif(peer.id, 'n', 'Hola')
          .then((_) => complete = true);
      final body = hub.sent.single.$3;
      hub.onNotifReplyResult('other', {...body, 'ok': true});
      hub.onNotifReplyResult(peer.id, {...body, 'key': 'wrong', 'ok': true});
      await Future<void>.delayed(Duration.zero);
      expect(complete, isFalse);
      hub.onNotifReplyResult(peer.id, {...body, 'ok': true});
      await reply;
      expect(complete, isTrue);
      // Duplicate/late results are harmless.
      hub.onNotifReplyResult(peer.id, {...body, 'ok': true});
    },
  );

  test(
    'reply reports expired targets, offline peers and invalid input',
    () async {
      final hub = connected();
      await expectLater(hub.replyNotif(peer.id, 'n', ' '), throwsStateError);
      await expectLater(
        hub.replyNotif(peer.id, 'n', 'x' * 4001),
        throwsStateError,
      );
      await expectLater(
        hub.replyNotif(peer.id, 'missing', 'Hola'),
        throwsStateError,
      );
      final reply = hub.replyNotif(peer.id, 'n', 'Hola');
      final checked = expectLater(
        reply,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('caducó'),
          ),
        ),
      );
      hub.onNotifReplyResult(peer.id, {
        ...hub.sent.last.$3,
        'ok': false,
        'error': 'expired',
      });
      await checked;
      hub.peers = [];
      await expectLater(hub.replyNotif(peer.id, 'n', 'Hola'), throwsStateError);
    },
  );

  testWidgets('a missing reply acknowledgement times out', (tester) async {
    final hub = connected();
    final checked = expectLater(
      hub.replyNotif(peer.id, 'n', 'Hola'),
      throwsA(isA<TimeoutException>()),
    );
    await tester.pump(const Duration(seconds: 12));
    await checked;
  });

  testWidgets(
    'PC playback shares controls, capabilities and releases its watch',
    (tester) async {
      final hub = connected()
        ..media[peer.id] = MediaState({
          'active': true,
          'title': 'Canción',
          'artist': 'Artista',
          'app': 'Player',
          'duration': 100000,
          'position': 20000,
          'actions': 4,
        });
      await tester.pumpWidget(screen(MediaPanel(hub, peer.id, computer: true)));
      expect(hub.sent.single.$2, 'pb.x.pcmedia.watch');
      expect(find.text('Canción'), findsOneWidget);
      expect(find.text('Artista · Player'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Siguiente',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Reproducir'));
      expect(hub.sent.last.$2, 'pb.x.remote.media');
      expect(hub.sent.last.$3['action'], 'toggle');
      await tester.pumpWidget(const SizedBox());
      expect(hub.sent.last.$2, 'pb.x.pcmedia.unwatch');
      final count = hub.sent.length;
      await tester.pump(const Duration(seconds: 11));
      expect(hub.sent.length, count);
    },
  );

  testWidgets('PC details keep volume controls with no active session', (
    tester,
  ) async {
    final hub = connected()..media[peer.id] = MediaState({'active': false});
    await tester.pumpWidget(
      screen(MediaPanel(hub, peer.id, computer: true, hideInactive: false)),
    );
    expect(find.text('No suena nada'), findsOneWidget);
    await tester.tap(find.byTooltip('Bajar volumen'));
    expect(hub.sent.last.$2, 'pb.x.remote.media');
    expect(hub.sent.last.$3['action'], 'volume_down');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'inactive and offline PC playback stay hidden without polling offline',
    (tester) async {
      final hub = connected()..media[peer.id] = MediaState({'active': false});
      await tester.pumpWidget(screen(MediaPanel(hub, peer.id, computer: true)));
      expect(find.text('Reproduciendo'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      hub.peers = [];
      hub.sent.clear();
      hub.media[peer.id] = MediaState({'active': true, 'title': 'Stale'});
      await tester.pumpWidget(screen(MediaPanel(hub, peer.id, computer: true)));
      expect(find.text('Stale'), findsNothing);
      await tester.pump(const Duration(seconds: 11));
      expect(hub.sent, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('media keepalives pause in background and resume once', (
    tester,
  ) async {
    final hub = connected();
    hub.remote.watchMedia(peer.id);
    hub.remote.mediaForeground(false);
    final count = hub.sent.length;
    await tester.pump(const Duration(seconds: 31));
    expect(hub.sent.length, count);
    hub.remote.mediaForeground(true);
    expect(hub.sent.last.$2, 'pb.x.pcmedia.watch');
    hub.remote.unwatchMedia(peer.id);
  });

  testWidgets(
    'leaving a 3000-entry explorer releases rows, thumbnails and pending timers',
    (tester) async {
      final hub = TestHub();
      final fs = hub.fs;
      fs.open(peer.id);
      fs.selectRoot('storage');
      fs.onMessage(peer.id, 'pb.x.fs.entries', {
        'root': 'storage',
        'path': '',
        'offset': 0,
        'total': 3000,
        'entries': List.generate(
          3000,
          (i) => {'id': '$i', 'name': 'Archivo $i.jpg'},
        ),
      });
      expect(fs.entries.length, 3000);
      fs.wantThumb(fs.entries.first);
      fs.onMessage(peer.id, 'pb.x.fs.thumb.data', {
        'root': 'storage',
        'id': '0',
        'jpeg': 'YWJj',
      });
      expect(fs.thumb('storage|0'), hasLength(3));
      fs.wantThumb(fs.entries[1]);
      fs.close();
      expect(fs.thumb('storage|0'), isNull);
      expect(fs.entries, isEmpty);
      expect(fs.peerId, isNull);
      fs.onMessage(peer.id, 'pb.x.fs.entries', {
        'root': 'storage',
        'path': '',
        'entries': [
          {'id': 'late'},
        ],
      });
      expect(fs.entries, isEmpty);
      final count = hub.sent.length;
      await tester.pump(const Duration(seconds: 10));
      expect(hub.sent.length, count);
    },
  );

  testWidgets('device mockup navigates to Devices', (tester) async {
    final hub = connected();
    Section? selected;
    await tester.pumpWidget(screen(HomeScreen(hub, go: (s) => selected = s)));
    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.label == 'Ver Laptop en Dispositivos',
      ),
    );
    expect(selected, Section.devices);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'setup is skippable at phone width with large text and reduced motion',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final hub = TestHub()..name = 'Equipo';
      bool? pair;
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          builder: (_, child) => MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 720),
              textScaler: TextScaler.linear(1.5),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: SetupScreen(hub, onDone: (value) => pair = value),
        ),
      );
      expect(find.text('Bienvenido a Alero'), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Omitir'));
      expect(pair, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('device name stays aligned at phone and desktop widths', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in [320.0, 960.0]) {
      tester.view.physicalSize = Size(width, 720);
      final hub = TestHub()..name = 'Mi equipo';
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: SetupScreen(hub, onDone: (_) {}),
        ),
      );
      await tester.pump();
      final label = find.text('Nombre del dispositivo');
      final field = find.byType(TextField);
      expect(label, findsOneWidget);
      expect(field, findsOneWidget);
      expect(tester.widget<TextField>(field).decoration?.labelText, isNull);
      expect(tester.getBottomLeft(label).dy, lessThan(tester.getTopLeft(field).dy));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  if (Platform.isWindows) {
    testWidgets(
      'reply drafts belong to one phone even when notification keys match',
      (tester) async {
        final hub = connected();
        hub.info[peer.id] = PeerInfo({'kind': 'phone', 'notifAccess': true});
        hub.info['other'] = hub.info[peer.id]!;
        hub.notifs['other'] = [
          PhoneNotif({'key': 'n', 'replyable': true}),
        ];
        await tester.pumpWidget(screen(NotificationsPanel(hub, peer.id)));
        await tester.enterText(
          find.byType(TextField),
          'Solo para este teléfono',
        );
        await tester.pumpWidget(screen(NotificationsPanel(hub, 'other')));
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets(
      'notification reply is disabled when blank and displays sending then acknowledgement',
      (tester) async {
        final hub = connected();
        hub.info[peer.id] = PeerInfo({'kind': 'phone', 'notifAccess': true});
        await tester.pumpWidget(screen(NotificationsPanel(hub, peer.id)));
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == 'Enviar respuesta',
                ),
              )
              .onPressed,
          isNull,
        );
        await tester.enterText(find.byType(TextField), 'Hola');
        await tester.pump();
        await tester.tap(find.byTooltip('Enviar respuesta'));
        await tester.pump();
        expect(find.text('Enviando…'), findsOneWidget);
        hub.onNotifReplyResult(peer.id, {...hub.sent.last.$3, 'ok': true});
        await tester.pump();
        expect(find.text('Enviado al teléfono'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
