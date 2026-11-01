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

  /// Spanish decimal comma, one decimal: "9,0 W".
  String get chargeWattsLabel =>
      '${chargeWatts?.toStringAsFixed(1).replaceAll('.', ',')} W';

  /// Same info with a fresh power reading (`pb.x.power`, sent between battery-level changes).
  PeerInfo withPower(Map<String, dynamic> p) => PeerInfo({
    ...j,
    'battery': {...?(j['battery'] as Map?), 'mw': p['mw']},
  });
  int get storageFree =>
      ((j['storage'] as Map?)?['free'] as num?)?.toInt() ?? 0;
  int get storageTotal =>
      ((j['storage'] as Map?)?['total'] as num?)?.toInt() ?? 0;
  bool get notifAccess => j['notifAccess'] == true;

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
      replyable = j['replyable'] == true;
  final String key, app, pkg, title, text;
  final DateTime time;
  final bool clearable, replyable;
}

class MediaState {
  MediaState(Map j)
    : active = j['active'] == true,
      app = j['app'] as String? ?? '',
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
  final String app, title, artist, album;
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
