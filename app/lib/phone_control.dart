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
    this.record,
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

  /// A file the phone's screen is recorded into, with no window (`.mkv`: still playable when the process is killed).
  final String? record;
}

/// The scrcpy command line for one session. Keyboard, mouse and clipboard sync are scrcpy's defaults.
List<String> scrcpyArgs(String serial, String title, SessionOptions o) => [
  '-s',
  serial,
  '--window-title=$title',
  // scrcpy refuses --stay-awake with --no-control (the camera) and exits at once.
  if (o.camera == null && o.record == null) '--stay-awake',
  if (o.record != null) ...[
    '--record=${o.record}',
    '--no-window',
    '--no-control',
  ],
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
      await old.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () => -1,
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    final p = await Scrcpy.launch(scrcpyArgs(serial, title, o));
    _running[key] = p;
    // Read both pipes so scrcpy cannot block on full buffers; keep its errors to explain a failure.
    final errors = <String>[];
    void keep(String line) {
      if (line.contains('ERROR')) {
        errors.add(line.replaceFirst(RegExp(r'^.*ERROR:\s*'), ''));
      }
    }

    final out = [p.stdout, p.stderr].map(
      (s) => s
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(keep)
          .asFuture<void>()
          .catchError((Object _) {}),
    );
    // Use the actual process exit, not stdout closing (which is unreliable
    // when native subprocesses inherit a pipe). Scrcpy's SDL window closing
    // terminates scrcpy; Alero's Stop button also kills this same process.
    p.exitCode.then((code) async {
      await Future.wait(out)
          .timeout(const Duration(seconds: 1), onTimeout: () => []);
      if (_running[key] != p) return; // stopped by Alero
      _running.remove(key);
      if (code != 0) {
        failures[key] = sessionError(errors, camera: o.camera != null);
      }
      notifyListeners();
    });
    notifyListeners();
  }

  final _rotationWatch = <String, Timer>{};

  /// The phone's camera in a window, upright: the camera sends its frames in the sensor's orientation whatever
  /// the phone does, so Alero rotates the window (scrcpy `--orientation`) and reopens it when the phone turns.
  Future<void> startCamera(String serial, String title, String facing) async {
    final key = '$serial|camera';
    _rotationWatch.remove(key)?.cancel();
    var turn = await _cameraTurn(serial, facing);
    await start(
      serial,
      title,
      SessionOptions(
        camera: facing,
        maxSize: 1920,
        audio: false,
        orientation: turn,
      ),
      extra: 'camera',
    );
    var busy = false;
    _rotationWatch[key] = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (!runningExtra(serial, 'camera')) {
        t.cancel();
        if (_rotationWatch[key] == t) _rotationWatch.remove(key);
        return;
      }
      if (busy) return;
      busy = true;
      try {
        final now = await _cameraTurn(serial, facing);
        if (now != turn && runningExtra(serial, 'camera')) {
          turn = now;
          await start(
            serial,
            title,
            SessionOptions(
              camera: facing,
              maxSize: 1920,
              audio: false,
              orientation: turn,
            ),
            extra: 'camera',
          );
        }
      } catch (_) {
        // The phone left adb: the session ends by itself and the timer with it.
      } finally {
        busy = false;
      }
    });
  }

  static final _sensor = <String, int>{};

  Future<int> _cameraTurn(String serial, String facing) async {
    final sensorKey = '$serial|$facing';
    final sensor = _sensor[sensorKey] ??= sensorOrientation(
      await Scrcpy.shell(serial, 'dumpsys media.camera').catchError((_) => ''),
      facing,
    );
    final rotation = displayRotation(
      await Scrcpy.shell(
        serial,
        'dumpsys window displays | grep -m 3 -E "mCurrentRotation|mRotation="; '
        'dumpsys input | grep -m 2 -E "SurfaceOrientation|Viewport INTERNAL"',
      ).catchError((_) => ''),
    );
    return cameraTurn(sensor, rotation, facing);
  }

  void stop(String serial) {
    _rotationWatch.remove(serial)?.cancel();
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
  final busy =
      all.contains('in use') ||
      all.contains('busy') ||
      all.contains('disconnected');
  // Another camera session or app holding the camera makes the server die before it connects.
  if (camera &&
      ((all.contains('camera') && busy) ||
          all.contains('server connection failed'))) {
    return 'La cámara está ocupada o el teléfono la bloqueó. Cierra otras apps de cámara, desbloquea el teléfono y vuelve a intentarlo.';
  }
  if (camera && all.contains('api')) {
    return 'La cámara en una ventana necesita Android 12 o posterior.';
  }
  if (all.contains('unauthorized')) {
    return 'Acepta la depuración USB en el teléfono.';
  }
  if (all.contains('not found') || all.contains('no devices')) {
    return 'El teléfono ya no está conectado por ADB.';
  }
  return errors.isEmpty
      ? 'La ventana del teléfono se cerró por un error.'
      : errors.last;
}

/// Clockwise degrees to turn a camera's frames so they look upright, from the sensor's mounting
/// ([sensor], Android's SENSOR_ORIENTATION) and the screen rotation ([rotation], Surface.ROTATION_* in degrees).
/// The back camera turns against the screen and the front one with it (Android's own preview formula).
int cameraTurn(int sensor, int rotation, String facing) => facing == 'front'
    ? (sensor + rotation) % 360
    : (sensor - rotation + 360) % 360;

/// The screen rotation in degrees from `dumpsys window displays` / `dumpsys input`; 0 when unknown.
int displayRotation(String dump) {
  final named = RegExp(r'mCurrentRotation=ROTATION_(\d+)').firstMatch(dump);
  if (named != null) return _degrees(int.parse(named.group(1)!), named: true);
  final index =
      RegExp(r'mRotation=(\d)\b').firstMatch(dump) ??
      RegExp(r'SurfaceOrientation:\s*(\d)').firstMatch(dump) ??
      RegExp(r'Viewport INTERNAL:.*?orientation=(\d)').firstMatch(dump);
  return index == null ? 0 : _degrees(int.parse(index.group(1)!));
}

int _degrees(int v, {bool named = false}) {
  final d = named ? v : v * 90;
  return const [0, 90, 180, 270].contains(d) ? d : 0;
}

/// SENSOR_ORIENTATION of the first [facing] camera in `dumpsys media.camera`; phones mount the back camera at
/// 90 and the front one at 270 almost always, which is the fallback when the dump says nothing.
int sensorOrientation(String dump, String facing) {
  final want = facing == 'front' ? 'front' : 'back';
  for (final m in RegExp(
    r'Facing:\s*(\w+)[^\n]*\n?[^\n]*?Orientation:\s*(\d+)',
    caseSensitive: false,
  ).allMatches(dump)) {
    if (m.group(1)!.toLowerCase() == want) {
      final o = int.parse(m.group(2)!);
      if (const [0, 90, 180, 270].contains(o)) return o;
    }
  }
  return want == 'front' ? 270 : 90;
}
