// Screenshots of the main screens, for design review (not part of `flutter test`: the name lacks _test).
// flutter test --update-goldens test/shots/shots.dart  → PNGs in test/shots/out/
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/hub.dart';
import 'package:pb_app/remote.dart';
import 'package:pb_app/src/rust/api/engine.dart' as pb;
import 'package:pb_app/ui/shell.dart';
import 'package:pb_app/ui/theme.dart';

class ShotHub extends Hub {
  @override
  Future<void> sendMessage(String p, String k, Map<String, Object?> b) async {}
  @override
  Future<void> refresh() async {}
}

const phone = pb.Peer(
  id: 'pixel',
  name: 'Pixel 9a',
  addr: '192.168.1.20',
  state: pb.PeerState.connected,
  trusted: true,
  detail: '',
);

ShotHub demo() {
  final h = ShotHub()
    ..setupDone = true
    ..name = 'Lenovo V15'
    ..peers = [phone]
    ..info[phone.id] = PeerInfo({
      'kind': 'phone',
      'os': 'Android',
      'osVersion': '16',
      'manufacturer': 'Google',
      'model': 'Pixel 9a',
      'marketName': 'Pixel 9a',
      'battery': {'level': 78, 'charging': true},
      'notifAccess': true,
      'sms': true,
      'calls': true,
    })
    ..notifs[phone.id] = [
      PhoneNotif({
        'key': 'a',
        'app': 'WhatsApp',
        'pkg': 'com.whatsapp',
        'title': 'Lucía',
        'text': '¿Me pasas las fotos de ayer?',
        'time': DateTime.now().millisecondsSinceEpoch - 120000,
        'replyable': true,
        'markable': true,
        'chat': true,
        'messages': [
          {
            'text': 'Hola, ¿qué tal el viaje?',
            'time': DateTime.now().millisecondsSinceEpoch - 600000,
            'sender': '',
            'out': true,
          },
          {
            'text': '¿Me pasas las fotos de ayer?',
            'time': DateTime.now().millisecondsSinceEpoch - 120000,
            'sender': 'Lucía',
          },
        ],
      }),
      PhoneNotif({
        'key': 'b',
        'app': 'Gmail',
        'pkg': 'com.google.android.gm',
        'title': 'Factura de octubre',
        'text': 'Tu factura ya está disponible.',
        'time': DateTime.now().millisecondsSinceEpoch - 3600000,
      }),
    ];
  h.history = [
    for (final (i, n) in ['IMG_2041.jpg', 'informe.pdf', 'notas.txt'].indexed)
      pb.HistoryItem(
        id: '$i',
        peerId: phone.id,
        peerName: phone.name,
        name: n,
        size: BigInt.from(1200000 * (i + 1)),
        incoming: i.isEven,
        status: 'done',
        code: '',
        message: '',
        time: BigInt.from(
          DateTime.now().millisecondsSinceEpoch ~/ 1000 - i * 900,
        ),
        path: '',
      ),
  ];
  h.phoneState[phone.id] = PhoneState({
    'dnd': true,
    'dndAccess': true,
    'torch': false,
    'ringer': 'vibrate',
    'media': 6,
    'mediaMax': 15,
    'ring': 4,
    'ringMax': 7,
    'callLog': true,
  });
  h.callLog[phone.id] = [
    for (final (i, (n, ty)) in [
      ('Mamá', 'in'),
      ('', 'missed'),
      ('Banco', 'out'),
    ].indexed)
      CallEntry({
        'name': n,
        'number': '+51 900 000 00$i',
        'type': ty,
        'date': DateTime.now().millisecondsSinceEpoch - i * 3600000,
        'duration': i * 75,
      }),
  ];
  return h;
}

Future<void> loadFonts() async {
  Future<void> load(String family, String path) async {
    final f = FontLoader(family)
      ..addFont(
        Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
      );
    await f.load();
  }

  await load(font, 'assets/fonts/GoogleSansFlex.ttf');
  final pub =
      Platform.environment['PUB_CACHE'] ??
      '${Platform.environment['LOCALAPPDATA']}/Pub/Cache';
  await load(
    'packages/material_symbols_icons/MaterialSymbolsRounded',
    '$pub/hosted/pub.dev/material_symbols_icons-4.2960.0/lib/fonts/MaterialSymbolsRounded.ttf',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadFonts();
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['pb/windows', 'window_manager', 'screen_retriever']) {
      m.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
  });

  for (final sec in [
    Section.calls,
    Section.messages,
    Section.devices,
    Section.settings,
  ]) {
    testWidgets('desktop ${sec.name}', (t) async {
      final h = demo();
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            const Color(0xFF3F6FD8),
            DynamicSchemeVariant.tonalSpot,
            Brightness.dark,
            amoled: true,
          ),
          home: Shell(h, initialSection: sec),
        ),
      );
      await t.pump(const Duration(seconds: 2));
      if (sec == Section.messages) {
        final now = DateTime.now().millisecondsSinceEpoch;
        h.sms.onMessage(phone.id, 'pb.x.sms.threads', {
          'items': [
            {
              'thread': 1,
              'name': 'Mamá',
              'addresses': ['+34 600 000 001'],
              'snippet': 'Llego a las 8',
              'date': now - 300000,
              'read': false,
            },
            {
              'thread': 2,
              'name': 'Banco',
              'addresses': ['BANCO'],
              'snippet': 'Tu código es 482913',
              'date': now - 7200000,
            },
            {
              'thread': 3,
              'name': 'Ana, Pedro',
              'addresses': ['+34 1', '+34 2'],
              'snippet': 'Nos vemos el sábado',
              'date': now - 90000000,
            },
          ],
        });
        await t.pump();
        await t.tap(find.text('Lucía').first);
        await t.pump(const Duration(seconds: 1));
      }
      await expectLater(
        find.byType(Shell),
        matchesGoldenFile('out/desktop_${sec.name}.png'),
      );
    });
  }

  for (final (name, w, h) in [
    ('wide', 1600.0, 1000.0),
    ('desktop', 1280.0, 800.0),
    ('small', 900.0, 600.0),
  ]) {
    for (final (look, b, amoled) in [
      ('light', Brightness.light, false),
      ('dark', Brightness.dark, false),
      ('amoled', Brightness.dark, true),
    ]) {
      testWidgets('$name $look', (t) async {
        t.view.physicalSize = Size(w, h);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(
              const Color(0xFF3F6FD8),
              DynamicSchemeVariant.tonalSpot,
              b,
              amoled: amoled,
            ),
            home: Shell(demo()),
          ),
        );
        await t.pump(const Duration(seconds: 2));
        await expectLater(
          find.byType(Shell),
          matchesGoldenFile('out/${name}_$look.png'),
        );
      });
    }
  }
}
