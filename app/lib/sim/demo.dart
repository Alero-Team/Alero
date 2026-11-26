// ignore_for_file: invalid_use_of_visible_for_testing_member, avoid_renaming_method_parameters
// Demo data for the web simulation (copied from test/shots/shots.dart, no flutter_test).
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pb_app/hub.dart';
import 'package:pb_app/l10n.dart';
import 'package:pb_app/remote.dart';
import 'package:pb_app/src/rust/api/engine.dart' as pb;

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
