// Screenshots of every screen with made-up data, in Spanish and English, for the README (not part of
// `flutter test`: the name lacks _test). Nothing real is read: phone, computer, adb and vault are all faked.
//   flutter test --update-goldens test/shots/shots.dart  → test/shots/out/{es,en}/
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/hub.dart';
import 'package:pb_app/l10n.dart';
import 'package:pb_app/phone_adb.dart';
import 'package:pb_app/phone_control.dart';
import 'package:pb_app/remote.dart';
import 'package:pb_app/src/rust/api/engine.dart' as pb;
import 'package:pb_app/ui/shell.dart';
import 'package:pb_app/ui/theme.dart';
import 'package:pb_app/vault.dart';

/// The made-up text in the current language.
String t(String es, String en) => L10n.instance.en ? en : es;

final now = DateTime.now().millisecondsSinceEpoch;
int ago(int minutes) => now - minutes * 60000;

/// Generated pictures (no real photo ever reaches a screenshot): a sky, a sun and two hills.
final pics = <Uint8List>[];
final icons = <String, Uint8List>{};

Future<Uint8List> landscape(int seed, {int w = 320, int h = 320}) async {
  final r = Random(seed);
  Color c(int a, int b, int c) => Color.fromARGB(255, a, b, c);
  final palettes = [
    [c(255, 170, 120), c(255, 94, 98), c(60, 40, 90), c(30, 20, 60)],
    [c(140, 200, 255), c(220, 240, 255), c(70, 140, 90), c(40, 100, 60)],
    [c(30, 40, 90), c(250, 150, 90), c(40, 50, 80), c(20, 25, 45)],
    [c(170, 230, 230), c(255, 250, 220), c(210, 180, 120), c(80, 160, 190)],
    [c(90, 60, 140), c(250, 120, 160), c(60, 30, 70), c(25, 15, 35)],
    [c(200, 225, 240), c(245, 245, 250), c(120, 130, 150), c(80, 90, 110)],
  ];
  final p = palettes[seed % palettes.length];
  final rec = ui.PictureRecorder();
  final cv = Canvas(rec);
  final size = Size(w.toDouble(), h.toDouble());
  cv.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [p[0], p[1]]),
  );
  cv.drawCircle(
    Offset(size.width * (0.2 + r.nextDouble() * 0.6), size.height * (0.25 + r.nextDouble() * 0.2)),
    size.width * (0.08 + r.nextDouble() * 0.06),
    Paint()..color = Colors.white.withValues(alpha: 0.85),
  );
  for (final (i, col) in [p[2], p[3]].indexed) {
    final base = size.height * (0.6 + i * 0.15);
    final path = Path()..moveTo(0, base);
    for (var x = 0.0; x <= size.width; x += size.width / 6) {
      path.lineTo(x, base - r.nextDouble() * size.height * 0.18);
    }
    path
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    cv.drawPath(path, Paint()..color = col);
  }
  final img = await rec.endRecording().toImage(w, h);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

Future<Uint8List> appIcon(Color color) async {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawCircle(const Offset(48, 48), 48, Paint()..color = color);
  final img = await rec.endRecording().toImage(96, 96);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// A Hub that answers its own requests as a phone (or a computer) would.
class ShotHub extends Hub {
  void reply(String peer, String kind, Map<String, Object?> body) => scheduleMicrotask(
    () => onEvent(pb.Event.message(peerId: peer, kind: kind, body: jsonEncode(body))),
  );

  @override
  Future<void> sendMessage(String p, String k, Map<String, Object?> b) async {
    switch (k) {
      case 'pb.x.sms.threads.request':
        reply(p, 'pb.x.sms.threads', {'items': smsThreads()});
      case 'pb.x.sms.thread':
        reply(p, 'pb.x.sms.messages', {'thread': b['thread'], 'items': smsThread()});
      case 'pb.x.fs.roots.request':
        reply(p, 'pb.x.fs.roots', {'allowed': true, 'roots': fsRoots()});
      case 'pb.x.fs.list':
        final e = fsEntries(b['root'] as String);
        reply(p, 'pb.x.fs.entries', {...b, 'entries': e, 'total': e.length});
      case 'pb.x.fs.thumb':
        final i = int.tryParse('${b['id']}'.replaceAll(RegExp(r'\D'), '')) ?? 0;
        reply(p, 'pb.x.fs.thumb.data', {...b, 'jpeg': base64Encode(pics[i % pics.length])});
      case 'pb.x.pcfs.roots.request':
        reply(p, 'pb.x.pcfs.roots', {
          'writable': true,
          'roots': [
            {'id': 'docs', 'name': t('Documentos', 'Documents'), 'kind': 'tree'},
            {'id': 'pics', 'name': t('Imágenes', 'Pictures'), 'kind': 'images'},
          ],
        });
      case 'pb.x.pcfs.list':
        final e = pcEntries();
        reply(p, 'pb.x.pcfs.entries', {...b, 'entries': e, 'total': e.length});
    }
  }

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

const pc = pb.Peer(
  id: 'pc',
  name: 'Portátil de casa',
  addr: '192.168.1.10',
  state: pb.PeerState.connected,
  trusted: true,
  detail: '',
);

List<Map<String, Object?>> smsThreads() => [
  {
    'thread': 1,
    'name': t('Mamá', 'Mom'),
    'addresses': ['+34 600 000 001'],
    'snippet': t('Llego a las 8', 'I\'ll be there at 8'),
    'date': ago(5),
    'read': false,
  },
  {
    'thread': 2,
    'name': t('Banco', 'Bank'),
    'addresses': ['BANCO'],
    'snippet': t('Tu código es 000000', 'Your code is 000000'),
    'date': ago(120),
  },
  {
    'thread': 3,
    'name': 'Ana, Pedro',
    'addresses': ['+34 600 000 002', '+34 600 000 003'],
    'snippet': t('Nos vemos el sábado', 'See you on Saturday'),
    'date': ago(1500),
  },
  {
    'thread': 4,
    'name': 'Carlos',
    'addresses': ['+34 600 000 004'],
    'snippet': t('¡Gracias!', 'Thanks!'),
    'date': ago(4000),
  },
];

List<Map<String, Object?>> smsThread() => [
  {'id': '1', 'body': t('¿A qué hora llegas?', 'What time are you arriving?'), 'date': ago(40), 'out': false},
  {'id': '2', 'body': t('Salgo en media hora', 'Leaving in half an hour'), 'date': ago(35), 'out': true},
  {'id': '3', 'body': t('Vale, preparo la cena', 'OK, I\'ll make dinner'), 'date': ago(20), 'out': false},
  {'id': '4', 'body': t('Llego a las 8', 'I\'ll be there at 8'), 'date': ago(5), 'out': false},
];

List<Map<String, Object?>> fsRoots() => [
  {'id': 'images', 'name': 'Fotos', 'kind': 'images', 'ok': true},
  {'id': 'video', 'name': 'Vídeos', 'kind': 'video', 'ok': true},
  {'id': 'audio', 'name': 'Música', 'kind': 'audio', 'ok': true},
  {'id': 'alero', 'name': 'Recibidos de Alero', 'kind': 'alero', 'ok': true},
  {'id': 'storage', 'name': 'Todas las carpetas', 'kind': 'storage', 'ok': true},
];

List<Map<String, Object?>> fsEntries(String root) {
  final s = now ~/ 1000;
  return switch (root) {
    'images' || 'video' => [
      for (var i = 0; i < 18; i++)
        {
          'id': '$i',
          'name': root == 'video' ? 'VID_2026110${i % 9}_$i.mp4' : 'IMG_2026110${i % 9}_$i.jpg',
          'size': 2400000 + i * 130000,
          'mtime': s - i * 7200,
          'mime': root == 'video' ? 'video/mp4' : 'image/jpeg',
          'path': '',
        },
    ],
    'storage' => [
      for (final (i, (n, items)) in [
        ('Alarms', 0),
        ('DCIM', 3),
        ('Documents', 12),
        ('Download', 27),
        ('Music', 48),
        ('Pictures', 9),
        ('Recordings', 4),
      ].indexed)
        {'id': 'd$i', 'name': n, 'dir': true, 'size': items, 'mtime': s - i * 86400, 'path': n},
      for (final (i, (n, mime, size)) in [
        (t('presupuesto.xlsx', 'budget.xlsx'), 'application/vnd.ms-excel', 48000),
        (t('apuntes.pdf', 'notes.pdf'), 'application/pdf', 1830000),
        ('IMG_20261102_1.jpg', 'image/jpeg', 3100000),
        (t('lista.txt', 'list.txt'), 'text/plain', 1200),
      ].indexed)
        {'id': 'f$i', 'name': n, 'size': size, 'mtime': s - i * 5000, 'mime': mime, 'path': n},
    ],
    _ => [
      for (final (i, n) in ['vacaciones.mp4', 'presentacion.pptx', 'IMG_2041.jpg'].indexed)
        {'id': 'a$i', 'name': n, 'size': 4200000 * (i + 1), 'mtime': s - i * 3600, 'path': n},
    ],
  };
}

List<Map<String, Object?>> pcEntries() {
  final s = now ~/ 1000;
  return [
    for (final (i, n) in [t('Facturas', 'Invoices'), t('Proyectos', 'Projects'), t('Viajes', 'Trips')].indexed)
      {'id': 'd$i', 'name': n, 'dir': true, 'size': 5 + i * 4, 'mtime': s - i * 86400, 'path': n},
    for (final (i, (n, mime)) in [
      (t('informe-final.docx', 'final-report.docx'), 'application/msword'),
      (t('presentacion.pptx', 'slides.pptx'), 'application/vnd.ms-powerpoint'),
      ('IMG_2041.jpg', 'image/jpeg'),
    ].indexed)
      {'id': 'f$i', 'name': n, 'size': 820000 * (i + 1), 'mtime': s - i * 4000, 'mime': mime, 'path': n},
  ];
}

/// What the computer sees: one phone with everything shared.
ShotHub demo() {
  final h = ShotHub()
    ..setupDone = true
    ..name = 'Portátil de casa'
    ..myId = 'demo'
    ..remoteAllow = true
    ..pcFolders = [r'C:\Users\Demo\Documentos']
    ..pcFilesWrite = true
    ..peers = [phone]
    ..info[phone.id] = PeerInfo({
      'kind': 'phone',
      'os': 'Android',
      'osVersion': '16',
      'manufacturer': 'Google',
      'model': 'Pixel 9a',
      'marketName': 'Pixel 9a',
      'battery': {'level': 78, 'charging': true, 'mw': 9200, 'mv': 4310},
      'storage': {'free': 61000000000, 'total': 128000000000},
      'network': 'wifi',
      'wifi': {'mhz': 5180, 'mbps': 866, 'rssi': -52, 'standard': 6},
      'notifAccess': true,
      'sms': true,
      'calls': true,
    })
    ..appIcons.addAll(icons)
    ..notifs[phone.id] = [
      PhoneNotif({
        'key': 'a',
        'app': 'WhatsApp',
        'pkg': 'com.whatsapp',
        'title': 'Lucía',
        'text': t('¿Me pasas las fotos de ayer?', 'Can you send me yesterday\'s photos?'),
        'time': ago(2),
        'replyable': true,
        'markable': true,
        'chat': true,
        'messages': [
          {'text': t('Hola, ¿qué tal el viaje?', 'Hi, how was the trip?'), 'time': ago(10), 'sender': '', 'out': true},
          {'text': t('¡Genial! Ya estamos de vuelta', 'Great! We\'re back home'), 'time': ago(6), 'sender': 'Lucía'},
          {'text': t('¿Me pasas las fotos de ayer?', 'Can you send me yesterday\'s photos?'), 'time': ago(2), 'sender': 'Lucía'},
        ],
      }),
      PhoneNotif({
        'key': 'b',
        'app': 'Gmail',
        'pkg': 'com.google.android.gm',
        'title': t('Factura de octubre', 'October invoice'),
        'text': t('Tu factura ya está disponible.', 'Your invoice is ready.'),
        'time': ago(60),
      }),
      PhoneNotif({
        'key': 'c',
        'app': t('Calendario', 'Calendar'),
        'pkg': 'com.google.android.calendar',
        'title': t('Reunión de equipo', 'Team meeting'),
        'text': t('Hoy, 17:00 – 18:00', 'Today, 5:00 – 6:00 PM'),
        'time': ago(90),
      }),
      PhoneNotif({
        'key': 'd',
        'app': t('Paquetería', 'Parcels'),
        'pkg': 'com.example.parcels',
        'title': t('Tu pedido llega mañana', 'Your order arrives tomorrow'),
        'text': t('Entrega entre las 9:00 y las 13:00.', 'Delivery between 9 AM and 1 PM.'),
        'time': ago(180),
      }),
    ]
    ..media[phone.id] = MediaState({
      'active': true,
      'app': t('Música', 'Music'),
      'pkg': 'com.example.music',
      'title': t('Atardecer en la costa', 'Sunset on the Coast'),
      'artist': 'Los Demo',
      'album': t('Verano', 'Summer'),
      'duration': 214000,
      'position': 83000,
      'at': now,
      'playing': true,
      'volume': 9,
      'volumeMax': 15,
      'art': base64Encode(pics[0]),
    });
  h.history = [
    for (final (i, n) in ['IMG_2041.jpg', t('informe.pdf', 'report.pdf'), t('notas.txt', 'notes.txt')].indexed)
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
        time: BigInt.from(now ~/ 1000 - i * 900),
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
    for (final (i, (n, ty, num)) in [
      (t('Mamá', 'Mom'), 'in', '+34 600 000 001'),
      ('', 'missed', '+34 600 000 009'),
      (t('Banco', 'Bank'), 'out', '+34 900 000 000'),
      ('Carlos', 'in', '+34 600 000 004'),
      ('Ana', 'out', '+34 600 000 002'),
    ].indexed)
      CallEntry({'name': n, 'number': num, 'type': ty, 'date': ago(i * 75), 'duration': i * 75}),
  ];
  h.sms.onMessage(phone.id, 'pb.x.sms.threads', {'items': smsThreads()});
  return h;
}

/// What the phone sees: the computer it is paired with, which lets it control mouse, screen and media.
ShotHub phoneDemo() {
  final h = ShotHub()
    ..setupDone = true
    ..notifAccess = true
    ..filesAllowed = true
    ..filesPermission = true
    ..smsAllowed = true
    ..smsPermission = true
    ..name = 'Pixel 9a'
    ..myId = 'demo'
    ..peers = [pc]
    ..info[pc.id] = PeerInfo({
      'kind': 'pc',
      'os': 'Windows',
      'osVersion': '11',
      'manufacturer': 'Demo',
      'model': t('Portátil 14"', '14" Laptop'),
      'battery': {'level': 64, 'charging': false},
      'remote': {'allowed': true, 'input': true, 'screen': true, 'media': true, 'power': true},
    });
  h.history = [
    for (final (i, n) in ['vacaciones.mp4', 'presentacion.pptx', 'IMG_2041.jpg'].indexed)
      pb.HistoryItem(
        id: '$i',
        peerId: pc.id,
        peerName: pc.name,
        name: n,
        size: BigInt.from(4200000 * (i + 1)),
        incoming: i.isOdd,
        status: 'done',
        code: '',
        message: '',
        time: BigInt.from(now ~/ 1000 - i * 1800),
        path: '',
      ),
  ];
  return h;
}

ThemeData look(Brightness b, {bool amoled = false}) =>
    buildTheme(const Color(0xFF3F6FD8), DynamicSchemeVariant.tonalSpot, b, amoled: amoled);

Future<void> loadFonts() async {
  Future<void> load(String family, String path) async {
    final f = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
    await f.load();
  }

  await load(font, 'assets/fonts/GoogleSansFlex.ttf');
  await load(
    'MaterialIcons',
    '${Platform.environment['FLUTTER_ROOT'] ?? 'C:/src/flutter'}/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
  );
  final pub = Platform.environment['PUB_CACHE'] ?? '${Platform.environment['LOCALAPPDATA']}/Pub/Cache';
  await load(
    'packages/material_symbols_icons/MaterialSymbolsRounded',
    '$pub/hosted/pub.dev/material_symbols_icons-4.2960.0/lib/fonts/MaterialSymbolsRounded.ttf',
  );
}

/// Lets real I/O (images, the vault's PowerShell) finish, then draws the result; waits while a spinner shows.
Future<void> settle(WidgetTester t, [int ms = 300, int min = 3]) async {
  for (var i = 0; i < min || (i < 40 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty); i++) {
    await t.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        await precacheImage((e.widget as Image).image, e);
      }
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await t.pump(const Duration(milliseconds: 600));
  }
}

/// Keeps letting real I/O run until [f] shows (the vault decrypts each note with its own PowerShell).
Future<void> until(WidgetTester t, Finder f) async {
  for (var i = 0; i < 1500 && f.evaluate().isEmpty; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 50));
  }
  if (f.evaluate().isEmpty) {
    debugPrint('SCREEN: ${find.byType(RichText).evaluate().map((e) => (e.widget as RichText).text.toPlainText()).join(' | ')}');
  }
  expect(f, findsWidgets);
  await settle(t, 500);
}

String lang = 'es';

/// Renders [home] at [size] logical pixels, [dpr] times sharper, into out/<lang>/[file].png.
Future<void> shot(
  WidgetTester t,
  String file,
  Size size,
  double dpr,
  Widget home, {
  ThemeData? theme,
  Future<void> Function(WidgetTester t)? then,
}) async {
  t.view.physicalSize = size * dpr;
  t.view.devicePixelRatio = dpr;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme ?? look(Brightness.dark, amoled: true),
      home: home,
    ),
  );
  await t.pump(const Duration(seconds: 2));
  await then?.call(t);
  await settle(t);
  await t.pump(const Duration(seconds: 2));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$lang/$file.png'));
}

late Directory vaults;
String vaultDir = '';
const vaultKey = 'demo-1234';

Future<void> fillVault(String dir, String? key) async {
  vaultDir = dir;
  final v = VaultStore();
  if (key != null) await v.createKey(key);
  for (final (i, (name, data)) in [
    (t('Claves del wifi de casa', 'Home Wi-Fi keys'), t('Red: Casa-5G\nClave: (de ejemplo)', 'Network: Home-5G\nKey: (sample)')),
    (t('Ideas para el viaje', 'Trip ideas'), t('Museo, playa, mercado del sábado', 'Museum, beach, Saturday market')),
    (t('Lista de regalos', 'Gift list'), t('Libro para Ana, auriculares para Carlos', 'Book for Ana, headphones for Carlos')),
  ].indexed) {
    await v.store(
      VaultEntry(
        id: 'demo${'$i'.padLeft(20, '0')}',
        name: name,
        kind: 'note',
        data: data,
        created: DateTime.now().subtract(Duration(days: i * 3)),
      ),
    );
  }
  await v.store(
    VaultEntry(
      id: 'demofile0000000000000000',
      name: 'IMG_2026_privada.png',
      kind: 'file',
      data: base64Encode(pics[3]),
      created: DateTime.now().subtract(const Duration(days: 9)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadFonts();
    for (var i = 0; i < 18; i++) {
      pics.add(await landscape(i));
    }
    icons.addAll({
      'com.whatsapp': await appIcon(const Color(0xFF25A366)),
      'com.google.android.gm': await appIcon(const Color(0xFFD9483B)),
      'com.google.android.calendar': await appIcon(const Color(0xFF3F6FD8)),
      'com.example.parcels': await appIcon(const Color(0xFFE0A030)),
    });
    VaultStore.fakeCrypt = (data, _) async => data;
    vaults = Directory.systemTemp.createTempSync('alero-shots');
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['pb/windows', 'pb/android', 'window_manager', 'screen_retriever']) {
      m.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    m.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => vaultDir,
    );
  });
  tearDownAll(() => vaults.deleteSync(recursive: true));

  for (final language in ['es', 'en']) {
    group(language, () {
      setUpAll(() async {
        lang = language;
        L10n.instance.set(language);
        // Each language seals its own notes, for the computer (with a key) and the phone (system lock).
        await fillVault('${vaults.path}${Platform.pathSeparator}${language}_pc', vaultKey);
        await fillVault('${vaults.path}${Platform.pathSeparator}${language}_phone', null);
      });

      desktop();
      mobile();
    });
  }
}

const desk = Size(1280, 800);

void desktop() => group('desktop', () {
  setUp(() {
    isPhone = false;
    PhoneAdb.fake = const AdbDevice('192.168.1.20:5555', 'device', 'Pixel 9a');
    vaultDir = '${vaults.path}${Platform.pathSeparator}${lang}_pc';
  });
  tearDown(() => PhoneAdb.fake = null);

  testWidgets('home dark', (t) => shot(t, 'desktop_01_home', desk, 1.5, Shell(demo())));
  testWidgets(
    'home light',
    (t) => shot(t, 'desktop_02_home_light', desk, 1.5, Shell(demo()), theme: look(Brightness.light)),
  );
  testWidgets('messages chat', (t) async {
    await shot(
      t,
      'desktop_03_messages',
      desk,
      1.5,
      Shell(demo(), initialSection: Section.messages),
      then: (t) async {
        await t.pump();
        await t.tap(find.text('Lucía').first);
        await t.pump(const Duration(seconds: 1));
      },
    );
  });
  testWidgets('messages sms', (t) async {
    await shot(
      t,
      'desktop_04_sms',
      desk,
      1.5,
      Shell(demo(), initialSection: Section.messages),
      then: (t) async {
        await t.pump();
        await t.tap(find.text(t2('Mamá', 'Mom')).first);
        await t.pump(const Duration(seconds: 1));
      },
    );
  });
  testWidgets('calls', (t) => shot(t, 'desktop_05_calls', desk, 1.5, Shell(demo(), initialSection: Section.calls)));
  testWidgets('incoming call', (t) async {
    final h = demo()
      ..calls[phone.id] = CallState({
        'active': true,
        'ringing': true,
        'canAnswer': true,
        'name': t2('Mamá', 'Mom'),
      });
    await shot(t, 'desktop_06_incoming_call', desk, 1.5, Shell(h));
  });
  testWidgets(
    'notifications',
    (t) => shot(t, 'desktop_07_notifications', desk, 1.5, Shell(demo(), initialSection: Section.notifications)),
  );
  testWidgets('photos', (t) => shot(t, 'desktop_08_photos', desk, 1.5, Shell(demo(), initialSection: Section.photos)));
  testWidgets('explorer', (t) async {
    final h = demo();
    await shot(
      t,
      'desktop_09_explorer',
      desk,
      1.5,
      Shell(h, initialSection: Section.explorer),
      then: (t) async {
        await t.pump();
        h.fs.selectRoot('storage');
        await t.pump(const Duration(seconds: 1));
      },
    );
  });
  testWidgets('vault', (t) async {
    await shot(
      t,
      'desktop_10_vault',
      desk,
      1.5,
      Shell(demo(), initialSection: Section.vault),
      then: (t) async {
        await settle(t, 1500);
        await t.enterText(find.byType(TextField).first, vaultKey);
        await t.tap(find.byType(FilledButton).last);
        await t.pump();
        await until(t, find.textContaining(t2('Lista de regalos', 'Gift list')));
      },
    );
  });
  testWidgets(
    'devices',
    (t) => shot(t, 'desktop_11_devices', const Size(1280, 1150), 1.5, Shell(demo(), initialSection: Section.devices)),
  );
  testWidgets(
    'settings',
    (t) => shot(t, 'desktop_12_settings', const Size(1280, 1700), 1.5, Shell(demo(), initialSection: Section.settings)),
  );
});

/// t() for code inside a testWidgets body, where `t` is the tester.
String t2(String es, String en) => t(es, en);

// A 1080×2400 phone screen.
const phoneSize = Size(1080 / 2.625, 2400 / 2.625);

void mobile() => group('phone', () {
  setUp(() {
    isPhone = true;
    vaultDir = '${vaults.path}${Platform.pathSeparator}${lang}_phone';
  });
  tearDown(() => isPhone = false);

  testWidgets('home dark', (t) => shot(t, 'phone_01_home', phoneSize, 2.625, Shell(phoneDemo())));
  testWidgets(
    'home light',
    (t) => shot(t, 'phone_02_home_light', phoneSize, 2.625, Shell(phoneDemo()), theme: look(Brightness.light)),
  );
  testWidgets('pc files', (t) async {
    await shot(
      t,
      'phone_03_pc_files',
      phoneSize,
      2.625,
      Shell(phoneDemo()),
      then: (t) async {
        await t.tap(find.text(t2('Archivos del ordenador', 'Computer files')).first);
        await t.pump(const Duration(seconds: 1));
        await t.pump(const Duration(seconds: 1));
        await t.tap(find.text(t2('Documentos', 'Documents')).first);
        await t.pump(const Duration(seconds: 1));
        await t.pump(const Duration(seconds: 1));
      },
    );
  });
  testWidgets(
    'devices',
    (t) => shot(t, 'phone_04_devices', const Size(1080 / 2.625, 1900), 2.625, Shell(phoneDemo(), initialSection: Section.devices)),
  );
  testWidgets(
    'settings',
    (t) => shot(t, 'phone_05_settings', const Size(1080 / 2.625, 3150), 2.625, Shell(phoneDemo(), initialSection: Section.settings)),
  );
  testWidgets('vault', (t) async {
    await shot(
      t,
      'phone_06_vault',
      phoneSize,
      2.625,
      Shell(phoneDemo(), initialSection: Section.settings),
      then: (t) async {
        await t.tap(find.text('Alero Vault').first);
        await t.pump(const Duration(seconds: 1));
        await until(t, find.textContaining(t2('Lista de regalos', 'Gift list')));
      },
    );
  });
});
