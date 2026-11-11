import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import 'hub.dart';
import 'src/rust/api/engine.dart' as pb;

/// The phone side of controlling a computer (ADR-0011): every action is a `pb.x.remote.*` message to a paired
/// computer. The computer carries it out only if its owner switched "Control remoto" on there; otherwise it
/// answers `pb.x.remote.denied` and the Hub tells the user. Nothing here decides trust.
class PcRemote {
  PcRemote(this.hub);
  final Hub hub;

  void _go(String peer, String kind, Map<String, Object?> body) =>
      hub.sendMessage(peer, kind, body);

  void move(String peer, int dx, int dy) =>
      _go(peer, 'pb.x.remote.move', {'dx': dx, 'dy': dy});
  void click(String peer, {String button = 'left', int count = 1}) =>
      _go(peer, 'pb.x.remote.click', {'button': button, 'count': count});
  final _held = <String, Set<String>>{};
  Timer? _buttonTimer;
  bool buttonHeld(String peer, String button) =>
      _held[peer]?.contains(button) ?? false;
  void button(String peer, String button, bool down) {
    _go(peer, 'pb.x.remote.button', {'button': button, 'down': down});
    if (down) {
      (_held[peer] ??= {}).add(button);
      _buttonTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
        for (final id in _held.keys) {
          _go(id, 'pb.x.remote.keepalive', {});
        }
      });
    } else {
      _held[peer]?.remove(button);
      if (_held[peer]?.isEmpty ?? false) _held.remove(peer);
      if (_held.isEmpty) {
        _buttonTimer?.cancel();
        _buttonTimer = null;
      }
    }
  }

  /// Notches: positive scrolls up/right.
  void scroll(String peer, {double dy = 0, double dx = 0}) =>
      _go(peer, 'pb.x.remote.scroll', {'dy': dy, 'dx': dx});
  void key(String peer, String key, {List<String> mods = const []}) =>
      _go(peer, 'pb.x.remote.key', {'key': key, 'mods': mods});
  void text(String peer, String text) =>
      _go(peer, 'pb.x.remote.text', {'text': text});

  /// volume_up, volume_down, mute, toggle, next, prev, stop.
  void media(String peer, String action) =>
      _go(peer, 'pb.x.remote.media', {'action': action});

  /// lock, sleep. The caller asks the user first.
  void power(String peer, String action) =>
      _go(peer, 'pb.x.remote.power', {'action': action});

  /// The computer sends a full-resolution screenshot as a normal file; the Hub shows it when it lands.
  void shot(String peer) {
    hub.shotWanted = peer;
    _go(peer, 'pb.x.shot.request', {});
  }

  // --- what the computer is playing: it only polls while someone keeps asking ---------------------------

  final _watchers = <String, int>{};
  Timer? _watchTimer;
  bool _mediaForeground = true;

  void _watchMedia(String peer) {
    if (_mediaForeground &&
        hub.peers.any(
          (p) => p.id == peer && p.trusted && p.state == pb.PeerState.connected,
        ) &&
        hub.info[peer]?.remoteAllowed == true) {
      _go(peer, 'pb.x.pcmedia.watch', {});
    }
  }

  void watchMedia(String peer) {
    _watchers[peer] = (_watchers[peer] ?? 0) + 1;
    _watchMedia(peer);
    _watchTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_mediaForeground) return;
      for (final p in _watchers.keys) {
        _watchMedia(p);
      }
    });
  }

  void mediaForeground(bool foreground) {
    if (_mediaForeground == foreground) return;
    _mediaForeground = foreground;
    if (foreground) {
      for (final p in _watchers.keys) {
        _watchMedia(p);
      }
    } else {
      for (final p in _watchers.keys) {
        _go(p, 'pb.x.pcmedia.unwatch', {});
      }
    }
  }

  void unwatchMedia(String peer) {
    final n = (_watchers[peer] ?? 1) - 1;
    if (n <= 0) {
      _watchers.remove(peer);
      _go(peer, 'pb.x.pcmedia.unwatch', {});
    } else {
      _watchers[peer] = n;
    }
    if (_watchers.isEmpty) {
      _watchTimer?.cancel();
      _watchTimer = null;
    }
  }
}

/// The computer's screen as a stream of JPEG frames (`pb.x.screen.*`). The computer keeps at most two frames in
/// flight (we acknowledge each one) and stops by itself if we stop sending keepalives.
class ScreenFeed extends ChangeNotifier {
  ScreenFeed(this.hub, this.peerId);
  final Hub hub;
  final String peerId;

  Uint8List? frame;
  int w = 0, h = 0;
  bool running = false;
  Timer? _keepalive;

  /// Frame width asked from the computer, and frames per second.
  int width = 960, fps = 15;

  /// Where the computer's pointer is, as fractions of the picture; null while hidden. It arrives on its own,
  /// far more often than the pictures, and is drawn over them: the pointer follows the finger at once.
  final cursor = ValueNotifier<Offset?>(null);

  void _ask() => hub.sendMessage(peerId, 'pb.x.screen.start', {
    'w': width,
    'fps': fps,
    'cursor': true,
  });

  void onCursor(Map<String, dynamic> b) {
    final x = b['x'], y = b['y'];
    cursor.value = x is num && y is num
        ? Offset(x.toDouble().clamp(0, 1), y.toDouble().clamp(0, 1))
        : null;
  }

  void start() {
    _keepalive?.cancel();
    running = true;
    _ask();
    _keepalive = Timer.periodic(
      const Duration(seconds: 5),
      (_) => hub.sendMessage(peerId, 'pb.x.screen.keepalive', {}),
    );
    notifyListeners();
  }

  /// Quality change while watching: restart the stream with the new size.
  void setQuality({required int width, required int fps}) {
    this.width = width;
    this.fps = fps;
    if (running) _ask();
    notifyListeners();
  }

  void onFrame(Map<String, dynamic> b) {
    if (!running) return;
    try {
      frame = base64Decode(b['jpeg'] as String);
    } catch (_) {
      return; // damaged frame: wait for the next one
    }
    w = (b['w'] as num?)?.toInt() ?? w;
    h = (b['h'] as num?)?.toInt() ?? h;
    hub.sendMessage(peerId, 'pb.x.screen.ack', {'seq': b['seq']});
    notifyListeners();
  }

  void stop() {
    if (!running) return;
    running = false;
    _keepalive?.cancel();
    _keepalive = null;
    frame = null;
    cursor.value = null;
    hub.sendMessage(peerId, 'pb.x.screen.stop', {});
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    cursor.dispose();
    super.dispose();
  }
}

/// A screenshot of the computer that has arrived.
class Shot {
  Shot(this.bytes, this.name, this.peerName) : time = DateTime.now();
  final Uint8List bytes;
  final String name, peerName;
  final DateTime time;
}
