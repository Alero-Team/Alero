import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'scrcpy.dart';

/// A phone as adb sees it. `state` is adb's own word: `device` (ready), `unauthorized` (the phone has not
/// accepted this computer yet), `offline`, …
class AdbDevice {
  const AdbDevice(this.serial, this.state, this.model);
  final String serial, state, model;

  bool get ready => state == 'device';
  bool get unauthorized => state == 'unauthorized';

  /// Wireless debugging: `ip:port` or an mDNS name.
  bool get wifi => serial.contains(':') || serial.contains('._adb-tls');
  String get name => model.isEmpty ? serial : model;
}

/// Parses `adb devices -l`.
List<AdbDevice> parseDevices(String out) {
  final list = <AdbDevice>[];
  for (final l in out.split('\n').map((l) => l.trim())) {
    if (l.isEmpty || l.startsWith('List of') || l.startsWith('*')) continue;
    final p = l.split(RegExp(r'\s+'));
    if (p.length < 2) continue;
    final m = RegExp(r'model:(\S+)').firstMatch(l);
    list.add(AdbDevice(p[0], p[1], (m?[1] ?? '').replaceAll('_', ' ')));
  }
  return list;
}

/// Android 16+ may expose native desktop windowing without the legacy
/// 'force desktop mode' developer flag. This is a capability hint, not proof
/// that an untrusted scrcpy virtual display has window decorations.
enum Desktop { unsupported, needsSetting, ready }

Desktop desktopSupport({
  required int sdk,
  required bool freeform,
  required bool forced,
}) => sdk < 29 || !freeform
    ? Desktop.unsupported
    : (forced || sdk >= 36)
    ? Desktop.ready
    : Desktop.needsSetting;

class SessionOptions {
  const SessionOptions({
    this.maxSize = 1600,
    this.bitRate = 8,
    this.maxFps = 60,
    this.audio = true,
    this.screenOff = false,
    this.fullscreen = false,
    this.orientation = 0,
    this.desktop = false,
    this.desktopSize = '1920x1080',
    this.displayId = 0,
    this.flexDisplay = false,
    this.startApp,
    this.appWindow = false,
    this.camera,
  });

  /// Longest side in pixels; 0 keeps the phone's own resolution.
  final int maxSize;

  /// Megabits per second.
  final int bitRate, maxFps, orientation;
  final bool audio, screenOff, fullscreen, desktop;
  final String desktopSize;
  final int displayId;
  final bool flexDisplay;
  final String? startApp;

  /// One app alone in its own window: a virtual display the size of the phone, without launcher or bars.
  final bool appWindow;

  /// `back` or `front`: the window shows that camera instead of the screen (Android 12+).
  final String? camera;
}

/// The scrcpy command line for one session. Keyboard, mouse and clipboard sync are scrcpy's defaults.
List<String> scrcpyArgs(String serial, String title, SessionOptions o) => [
  '-s',
  serial,
  '--window-title=$title',
  // scrcpy refuses --stay-awake with --no-control (the camera) and exits at once.
  if (o.camera == null) '--stay-awake',
  if (o.maxSize > 0) '--max-size=${o.maxSize}',
  '--video-bit-rate=${o.bitRate}M',
  '--max-fps=${o.maxFps}',
  if (o.camera != null) ...[
    '--video-source=camera',
    '--camera-facing=${o.camera}',
    '--no-control',
    if (o.audio) '--audio-source=mic' else '--no-audio',
  ] else if (!o.audio)
    '--no-audio',
  if (o.fullscreen) '--fullscreen',
  if (o.orientation != 0) '--orientation=${o.orientation}',
  if (!o.desktop && o.displayId > 0) '--display-id=${o.displayId}',
  // A virtual display shows the phone's desktop; the phone's own screen is untouched, so it is not turned off.
  if (o.camera != null)
    ...[]
  else if (o.appWindow && o.startApp != null) ...[
    '--new-display',
    '--no-vd-system-decorations',
    '--display-ime-policy=local',
    '--start-app=${o.startApp}',
  ] else if (o.desktop) ...[
    '--new-display=${o.desktopSize}',
    // Android 17 refuses Home on scrcpy's displays and its taskbar covers Alero's: Alero Desktop draws its own.
    '--no-vd-system-decorations',
    '--keep-active',
    '--display-ime-policy=local',
    if (o.flexDisplay) '--flex-display',
    if (o.startApp != null) '--start-app=${o.startApp}',
  ] else if (o.screenOff)
    '--turn-screen-off',
];

/// Android key codes for the toolbar.
abstract final class Keys {
  static const back = 4, home = 3, recents = 187;
  static const volumeUp = 24, volumeDown = 25, playPause = 85;
  static const next = 87, previous = 88;
}

/// Running scrcpy windows, one per phone. Closing the window, "Detener" here or on the phone, or quitting
/// Alero ends a session; nothing keeps running after that.
class PhoneSessions extends ChangeNotifier {
  PhoneSessions._();
  static final instance = PhoneSessions._();

  final _running = <String, Process>{};

  bool running(String serial) => _running.containsKey(serial);
  Iterable<String> get serials => _running.keys.where((k) => !k.contains('|'));

  /// Extra windows of a phone (an app, the camera) run next to its main session: key `serial|what`.
  bool runningExtra(String serial, String what) =>
      _running.containsKey('$serial|$what');

  /// Why the last session of a key ended on its own with an error (camera busy, phone locked, …), shown by the UI.
  final failures = <String, String>{};

  Future<void> start(
    String serial,
    String title,
    SessionOptions o, {
    String? extra,
  }) async {
    final key = extra == null ? serial : '$serial|$extra';
    failures.remove(key);
    final old = _running.remove(key);
    if (old != null) {
      // The phone frees the camera only when the old server is gone: opening the other one at once failed both.
      Process.killPid(old.pid);
      await old.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    final p = await Scrcpy.launch(scrcpyArgs(serial, title, o));
    _running[key] = p;
    // Read both pipes so scrcpy cannot block on full buffers; keep its errors to explain a failure.
    final errors = <String>[];
    void keep(String line) {
      if (line.contains('ERROR')) errors.add(line.replaceFirst(RegExp(r'^.*ERROR:\s*'), ''));
    }
    final out = [p.stdout, p.stderr]
        .map((s) => s.transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen(keep).asFuture<void>().catchError((Object _) {}));
    // Use the actual process exit, not stdout closing (which is unreliable
    // when native subprocesses inherit a pipe). Scrcpy's SDL window closing
    // terminates scrcpy; Alero's Stop button also kills this same process.
    p.exitCode.then((code) async {
      await Future.wait(out).timeout(const Duration(seconds: 1), onTimeout: () => []);
      if (_running[key] != p) return; // stopped by Alero
      _running.remove(key);
      if (code != 0) failures[key] = sessionError(errors, camera: o.camera != null);
      notifyListeners();
    });
    notifyListeners();
  }

  void stop(String serial) {
    final p = _running.remove(serial);
    if (p == null) return;
    Process.killPid(p.pid); // works for detached processes too
    notifyListeners();
  }

  void stopAll() {
    for (final s in _running.keys.toList()) {
      stop(s);
    }
  }
}

/// scrcpy's own error lines, in words for the user.
String sessionError(List<String> errors, {bool camera = false}) {
  final all = errors.join(' ').toLowerCase();
  final busy = all.contains('in use') || all.contains('busy') || all.contains('disconnected');
  // Another camera session or app holding the camera makes the server die before it connects.
  if (camera && ((all.contains('camera') && busy) || all.contains('server connection failed'))) {
    return 'La cámara está ocupada o el teléfono la bloqueó. Cierra otras apps de cámara, desbloquea el teléfono y vuelve a intentarlo.';
  }
  if (camera && all.contains('api')) return 'La cámara en una ventana necesita Android 12 o posterior.';
  if (all.contains('unauthorized')) return 'Acepta la depuración USB en el teléfono.';
  if (all.contains('not found') || all.contains('no devices')) return 'El teléfono ya no está conectado por ADB.';
  return errors.isEmpty ? 'La ventana del teléfono se cerró por un error.' : errors.last;
}
