import 'dart:io';

/// Desktop wrapper around the bundled scrcpy + adb (Apache-2.0, ADR-0008). The phone must have wireless
/// debugging on (Developer options); this is the "ADB" permission class in the project rules, chosen by the user
/// and explained in the UI. Nothing here touches the engine or the trust store.
class Scrcpy {
  static final _exe = File(Platform.resolvedExecutable).parent.path;
  static String get _dir => '$_exe${Platform.pathSeparator}scrcpy';
  static String get _adb => '$_dir${Platform.pathSeparator}${Platform.isWindows ? 'adb.exe' : 'adb'}';
  static String get _scrcpy => '$_dir${Platform.pathSeparator}${Platform.isWindows ? 'scrcpy.exe' : 'scrcpy'}';

  static bool get available => !Platform.isAndroid && File(_scrcpy).existsSync() && File(_adb).existsSync();

  static Future<ProcessResult> _run(List<String> args) => Process.run(
    _adb,
    args,
    environment: {'ADB_MDNS_AUTO_CONNECT': 'adb-tls-connect'},
  ).timeout(const Duration(seconds: 20));

  /// Serials adb can use right now (e.g. `192.0.2.29:41257`).
  static Future<List<String>> devices() async {
    final r = await _run(['devices']);
    return [
      for (final l in '${r.stdout}'.split('\n'))
        if (l.trim().endsWith('\tdevice') || RegExp(r'\sdevice$').hasMatch(l.trim()))
          l.trim().split(RegExp(r'\s+')).first,
    ];
  }

  /// First time only: the code and port from "Vincular dispositivo con código de vinculación" on the phone.
  static Future<String> pair(String ip, String port, String code) async {
    final r = await _run(['pair', '$ip:$port', code]);
    return '${r.stdout}${r.stderr}'.trim();
  }

  /// The phone's wireless-debugging port changes every time; mDNS tells us where it is.
  static Future<String?> find(String ip) async {
    final r = await _run(['mdns', 'services']);
    for (final l in '${r.stdout}'.split('\n')) {
      final m = RegExp(r'_adb-tls-connect\._tcp\.?\s+(\d+\.\d+\.\d+\.\d+):(\d+)').firstMatch(l);
      if (m != null && m[1] == ip) return '${m[1]}:${m[2]}';
    }
    return null;
  }

  static Future<bool> connect(String target) async {
    final r = await _run(['connect', target]);
    return '${r.stdout}'.contains('connected');
  }

  /// A serial for this phone: already connected over Wi-Fi, found via mDNS, or the only phone on USB.
  static Future<String?> ready(String ip) async {
    final now = (await devices()).where((d) => d.startsWith('$ip:')).firstOrNull;
    if (now != null) return now;
    final t = await find(ip);
    if (t != null && await connect(t)) return t;
    // A single phone on USB with debugging on also works (no Wi-Fi pairing needed).
    final usb = (await devices()).where((d) => !d.contains(':')).toList();
    return usb.length == 1 ? usb.first : null;
  }

  /// USB cable with no network at all: the two engine ports travel through adb (forward: computer -> phone,
  /// reverse: phone -> computer). Each side then sees the other at `127.0.0.1:port`, which is why the phone
  /// listens one port above the computer. Returns an error text, or null when the tunnel is up.
  static Future<String?> cable({required int phonePort, required int pcPort}) async {
    if (!available) return 'Falta adb: vuelve a compilar con tools\\fetch-scrcpy.ps1.';
    final usb = (await devices()).where((d) => !d.contains(':')).toList();
    if (usb.isEmpty) {
      return 'No veo ningún teléfono por USB. Conéctalo, activa «Depuración USB» y acepta la autorización en su pantalla.';
    }
    if (usb.length > 1) return 'Hay más de un dispositivo USB conectado. Deja solo el teléfono.';
    for (final a in [
      ['-s', usb.first, 'forward', 'tcp:$phonePort', 'tcp:$phonePort'],
      ['-s', usb.first, 'reverse', 'tcp:$pcPort', 'tcp:$pcPort'],
    ]) {
      final r = await _run(a);
      if (r.exitCode != 0) return 'adb no pudo abrir el túnel: ${'${r.stderr}'.trim()}';
    }
    return null;
  }

  static Future<Process> start(String serial, {required String title, bool screenOff = false, bool audio = true}) =>
      Process.start(
        _scrcpy,
        [
          '-s',
          serial,
          '--window-title=$title',
          '--stay-awake',
          if (screenOff) '--turn-screen-off',
          if (!audio) '--no-audio',
        ],
        environment: {'ADB': _adb},
        // Detached: no console window. Its stdout closing tells us the window was closed.
        mode: ProcessStartMode.detachedWithStdio,
      );
}
