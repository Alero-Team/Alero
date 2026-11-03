import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'device_image.dart';

/// Plain views of the app messages a paired device sends (`pb.x.*`, Protocol.md §6). Parsing only: unknown or
/// missing fields fall back to empty values, because the other side may be an older or newer version.

class ScreenShape {
  ScreenShape(this.w, this.h, this.radius, this.cutout);
  final int w, h, radius;

  /// Front camera hole/notch in screen pixels: (x, y, w, h).
  final (int, int, int, int)? cutout;

  static ScreenShape? from(Object? j) {
    if (j is! Map) return null;
    final w = (j['w'] as num?)?.toInt() ?? 0,
        h = (j['h'] as num?)?.toInt() ?? 0;
    if (w <= 0 || h <= 0) return null;
    final c = j['cutout'];
    return ScreenShape(
      w,
      h,
      (j['radius'] as num?)?.toInt() ?? 0,
      c is Map
          ? (
              (c['x'] as num).toInt(),
              (c['y'] as num).toInt(),
              (c['w'] as num).toInt(),
              (c['h'] as num).toInt(),
            )
          : null,
    );
  }
}

class PeerInfo {
  PeerInfo(this.j);
  final Map<String, dynamic> j;

  bool get phone => j['kind'] == 'phone';
  String get manufacturer => j['manufacturer'] as String? ?? '';
  String get model => j['model'] as String? ?? '';

  /// What identifies the exact model (`ro.product.*`); absent from older phones, then only manufacturer and model.
  PhoneId get phoneId => PhoneId(
    manufacturer: manufacturer,
    brand: j['brand'] as String? ?? '',
    model: model,
    device: j['device'] as String? ?? '',
    product: j['product'] as String? ?? '',
    marketName: j['marketName'] as String? ?? '',
  );
  String get os => j['os'] as String? ?? '';
  String get osVersion => j['osVersion'] as String? ?? '';
  String get osLabel => [os, osVersion].where((s) => s.isNotEmpty).join(' ');
  int get battery => ((j['battery'] as Map?)?['level'] as num?)?.toInt() ?? -1;
  bool get charging => (j['battery'] as Map?)?['charging'] == true;

  /// Power going into the battery now, measured by the phone (voltage × current); null if unplugged or unknown.
  double? get chargeWatts {
    final mw = (j['battery'] as Map?)?['mw'];
    return charging && mw is num && mw > 0 ? mw / 1000 : null;
  }

  /// Battery voltage measured with it, in volts (the charger's own voltage is not visible to apps).
  double? get chargeVolts {
    final mv = (j['battery'] as Map?)?['mv'];
    return mv is num && mv > 0 ? mv / 1000 : null;
  }

  /// "Buena" from 10 W (a phone charger), "Mala" from 5 W, "Deficiente" below (a weak port or cable).
  String get chargeState => switch (chargeWatts) {
    null => 'en pausa',
    final w when w >= 10 => 'Buena',
    final w when w >= 5 => 'Mala',
    _ => 'Deficiente',
  };

  /// "9,0 W · 4,31 V" for the Home status; null when the phone is not charging or cannot measure it.
  String? get chargeLabel {
    final mw = (j['battery'] as Map?)?['mw'];
    if (!charging || mw is! num) return null;
    final w = chargeWatts;
    if (w == null) return 'Batería mantenida';
    String n(double v, int d) => v.toStringAsFixed(d).replaceAll('.', ',');
    return [
      '${n(w, 1)} W',
      if (chargeVolts != null) '${n(chargeVolts!, 2)} V',
    ].join(' · ');
  }

  /// Same info with a fresh power reading (`pb.x.power`, sent between battery-level changes).
  PeerInfo withPower(Map<String, dynamic> p) => PeerInfo({
    ...j,
    'battery': {...?(j['battery'] as Map?), 'mw': p['mw'], 'mv': p['mv']},
  });
  int get storageFree =>
      ((j['storage'] as Map?)?['free'] as num?)?.toInt() ?? 0;
  int get storageTotal =>
      ((j['storage'] as Map?)?['total'] as num?)?.toInt() ?? 0;
  bool get notifAccess => j['notifAccess'] == true;

  /// The phone's owner lets this computer read and send SMS.
  bool get sms => j['sms'] == true;

  /// The phone's owner lets this computer answer, end and place calls.
  bool get calls => j['calls'] == true;

  /// A computer's remote-control capabilities (the "remote" field of its pb.x.info). Absent on phones and old versions.
  Map? get _remote => j['remote'] as Map?;
  bool get remoteAllowed => _remote?['allowed'] == true;
  bool get canInput => _remote?['input'] == true;
  bool get canScreen => _remote?['screen'] == true;
  bool get canMedia => _remote?['media'] == true;
  bool get canPower => _remote?['power'] == true;

  /// Laptops report a battery; desktops report none (-1).
  bool get hasBattery => battery >= 0;

  /// Same info with the user's switch changed (the computer tells us when its owner flips it).
  PeerInfo withAllowed(bool on) => PeerInfo({
    ...j,
    'remote': {...?_remote, 'allowed': on},
  });
  ScreenShape? get screen => ScreenShape.from(j['screen']);

  /// Dominant colours of the phone's wallpaper (ARGB), which Android hands to any app without a permission.
  List<Color> get wallpaperColors => [
    for (final c in ((j['wallpaper'] as Map?)?['colors'] as List? ?? const []))
      if (c is num) Color(c.toInt()),
  ];

  /// The user picked an actual image for the computer to draw (it arrives as pb.x.wallpaper).
  bool get wallpaperCustom => (j['wallpaper'] as Map?)?['custom'] == true;

  String get network => switch (j['network']) {
    'wifi' => 'Wi-Fi',
    'ethernet' => 'Ethernet',
    'cellular' => 'Datos móviles',
    _ => '',
  };
}

class PhoneNotif {
  PhoneNotif(Map j)
    : key = j['key'] as String? ?? '',
      app = j['app'] as String? ?? '',
      pkg = j['pkg'] as String? ?? '',
      title = j['title'] as String? ?? '',
      text = j['text'] as String? ?? '',
      time = DateTime.fromMillisecondsSinceEpoch(
        (j['time'] as num?)?.toInt() ?? 0,
      ),
      clearable = j['clearable'] != false,
      replyable = j['replyable'] == true,
      markable = j['markable'] == true,
      mutable = j['mutable'] == true,
      chat = j['chat'] == true,
      conversation = j['conversation'] as String? ?? '',
      messages = [
        for (final m in (j['messages'] as List? ?? []))
          if (m is Map) ChatMsg.fromNotif(m),
      ];
  final String key, app, pkg, title, text;
  final DateTime time;
  final bool clearable, replyable;

  /// The app has its own "mark as read" / "mute conversation" buttons.
  final bool markable, mutable;

  /// A messaging app's conversation, with the last messages its notification carries.
  final bool chat;
  final String conversation;
  final List<ChatMsg> messages;
}

/// The phone's quick controls (`pb.x.phone.state`).
class PhoneState {
  PhoneState(Map j)
    : dnd = j['dnd'] == true,
      dndAccess = j['dndAccess'] == true,
      torch = j['torch'] == true,
      finding = j['finding'] == true,
      callLog = j['callLog'] == true,
      ringer = j['ringer'] as String? ?? 'normal',
      media = (j['media'] as num?)?.toInt() ?? 0,
      mediaMax = (j['mediaMax'] as num?)?.toInt() ?? 15,
      ring = (j['ring'] as num?)?.toInt() ?? 0,
      ringMax = (j['ringMax'] as num?)?.toInt() ?? 7;
  final bool dnd, dndAccess, torch, finding, callLog;
  final String ringer;
  final int media, mediaMax, ring, ringMax;
}

/// One line of the phone's call log, or one contact number.
class CallEntry {
  CallEntry(Map j)
    : number = j['number'] as String? ?? '',
      name = j['name'] as String? ?? '',
      type = j['type'] as String? ?? '',
      date = DateTime.fromMillisecondsSinceEpoch(
        (j['date'] as num?)?.toInt() ?? 0,
      ),
      duration = (j['duration'] as num?)?.toInt() ?? 0;
  final String number, name, type;
  final DateTime date;
  final int duration;
  String get who => name.isNotEmpty ? name : number;
}

/// The phone's call right now (`pb.x.call`): nothing, ringing, or in progress.
class CallState {
  CallState(Map j)
    : active = j['active'] == true,
      ringing = j['ringing'] == true,
      canAnswer = j['canAnswer'] == true,
      name = j['name'] as String? ?? '',
      text = j['text'] as String? ?? '';
  final bool active, ringing, canAnswer;
  final String name, text;
}

/// One message of a conversation: an SMS/MMS from the phone's store or a line of a chat notification.
class ChatMsg {
  ChatMsg({
    required this.body,
    required this.time,
    required this.out,
    this.sender = '',
    this.media = 0,
    this.failed = false,
    this.id = '',
  });
  ChatMsg.fromNotif(Map m)
    : this(
        body: m['text'] as String? ?? '',
        time: DateTime.fromMillisecondsSinceEpoch(
          (m['time'] as num?)?.toInt() ?? 0,
        ),
        out: m['out'] == true,
        sender: m['sender'] as String? ?? '',
      );
  ChatMsg.fromSms(Map m)
    : this(
        id: m['id'] as String? ?? '',
        body: m['body'] as String? ?? '',
        time: DateTime.fromMillisecondsSinceEpoch(
          (m['date'] as num?)?.toInt() ?? 0,
        ),
        out: m['out'] == true,
        sender: m['sender'] as String? ?? '',
        media: (m['media'] as num?)?.toInt() ?? 0,
        failed: m['failed'] == true,
      );
  final String id, body, sender;
  final DateTime time;
  final bool out, failed;

  /// Attachments (pictures, audio) of an MMS; they stay on the phone.
  final int media;
}

class MediaState {
  MediaState(Map j)
    : active = j['active'] == true,
      app = j['app'] as String? ?? '',
      pkg = j['pkg'] as String? ?? '',
      cast = j['cast'] == true,
      title = j['title'] as String? ?? '',
      artist = j['artist'] as String? ?? '',
      album = j['album'] as String? ?? '',
      duration = (j['duration'] as num?)?.toInt() ?? 0,
      playing = j['playing'] == true,
      position = (j['position'] as num?)?.toInt() ?? 0,
      at = (j['at'] as num?)?.toInt() ?? 0,
      volume = (j['volume'] as num?)?.toInt() ?? 0,
      volumeMax = (j['volumeMax'] as num?)?.toInt() ?? 0,
      speed = (j['speed'] as num?)?.toDouble() ?? 1,
      actions = (j['actions'] as num?)?.toInt(),
      receivedAt = DateTime.now().millisecondsSinceEpoch,
      art = _art(j['art']);
  final bool active, playing;

  /// Played on another device (Chromecast, a speaker), not on the phone itself.
  final bool cast;
  final String app, pkg, title, artist, album;
  final int duration, position, at, volume, volumeMax;
  final Uint8List? art;
  final double speed;
  final int? actions;
  final int receivedAt;
  bool supports(int flag) => actions == null || (actions! & flag) != 0;

  /// Position now, extrapolated from the last report while playing (the phone does not stream it).
  int get positionNow {
    if (!playing) return position;
    final elapsed = (DateTime.now().millisecondsSinceEpoch - receivedAt).clamp(
      0,
      15000,
    );
    final p = position + (elapsed * speed).round();
    return duration > 0 ? p.clamp(0, duration) : p.clamp(0, 1 << 53);
  }

  static Uint8List? _art(Object? s) {
    if (s is! String || s.isEmpty) return null;
    try {
      return base64Decode(s);
    } catch (_) {
      return null;
    }
  }
}

class ClipItem {
  ClipItem(this.text, this.peerName, this.incoming) : time = DateTime.now();
  final String text, peerName;
  final bool incoming;
  final DateTime time;
}

/// The engine speaks English in a few details; the UI is Spanish. Unknown texts pass through unchanged.
String es(String m) {
  if (m.isEmpty) return m;
  final retry = RegExp(r'^(.*); retrying in (\d+)s \((\d+)/(\d+)\)$')
      .firstMatch(m);
  if (retry != null) {
    return 'Sin conexión; reintento en ${retry[2]} s (${retry[3]} de ${retry[4]})';
  }
  if (m.startsWith('cannot reach ')) {
    return 'No se puede conectar; comprueba que el otro dispositivo tenga la app abierta';
  }
  if (m.startsWith('cannot read file')) return 'No se puede leer el archivo';
  if (m.startsWith('bad address')) return 'Dirección no válida';
  return switch (m) {
    'connection lost' => 'Se perdió la conexión',
    'paused' => 'Pulsa Conectar para volver a usarlo',
    'paused_remote' => 'Se volverá a conectar cuando lo conecten desde allí',
    'that device is disconnected: connect it first' =>
      'Ese dispositivo está desconectado; conéctalo primero',
    'the other device no longer trusts this one' ||
    'the other device does not trust this one' =>
      'El otro dispositivo ya no confía en este',
    'that device is not paired' => 'Ese dispositivo no está emparejado',
    'that device has not been seen on the network' =>
      'Ese dispositivo no está en la red ahora',
    'this transfer cannot be retried' =>
      'Esta transferencia no se puede reintentar',
    'file name not allowed' => 'Nombre de archivo no permitido',
    'checksum mismatch' => 'El archivo llegó dañado',
    'message too large' => 'El contenido es demasiado grande',
    'peer address unknown' => 'No se conoce la dirección del otro dispositivo',
    _ => m,
  };
}
