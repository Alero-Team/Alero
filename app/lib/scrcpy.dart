import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Desktop wrapper around the bundled scrcpy + adb (Apache-2.0, ADR-0008). The phone must have wireless
/// debugging on (Developer options); this is the "ADB" permission class in the project rules, chosen by the user
/// and explained in the UI. Nothing here touches the engine or the trust store.
class Scrcpy {
  static final _exe = File(Platform.resolvedExecutable).parent.path;
  static String get _dir => '$_exe${Platform.pathSeparator}scrcpy';
  static String get _adb =>
      '$_dir${Platform.pathSeparator}${Platform.isWindows ? 'adb.exe' : 'adb'}';
  static String get _scrcpy =>
      '$_dir${Platform.pathSeparator}${Platform.isWindows ? 'scrcpy.exe' : 'scrcpy'}';

  static bool get available =>
      !Platform.isAndroid &&
      File(_scrcpy).existsSync() &&
      File(_adb).existsSync();

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
        if (l.trim().endsWith('\tdevice') ||
            RegExp(r'\sdevice$').hasMatch(l.trim()))
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
      final m = RegExp(
        r'_adb-tls-connect\._tcp\.?\s+(\d+\.\d+\.\d+\.\d+):(\d+)',
      ).firstMatch(l);
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
    final now = (await devices())
        .where((d) => d.startsWith('$ip:'))
        .firstOrNull;
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
  ///
  /// It speaks to whatever adb server is already running instead of launching our own `adb`: two adb versions on
  /// one PC (ours, Android Studio's, an old `C:db`) kill each other's server, and with it every tunnel.
  static Future<String?> cable({
    required int phonePort,
    required int pcPort,
    bool startServer = true,
  }) async {
    if (!await _AdbServer.up()) {
      if (!startServer) return 'adb no está en marcha.';
      if (!available) {
        return 'Falta adb: vuelve a compilar con tools\\fetch-scrcpy.ps1.';
      }
      await _run(['start-server']);
    }
    try {
      final usb = (await _AdbServer.devices())
          .where((d) => !d.contains(':'))
          .toList();
      if (usb.isEmpty) {
        return 'No veo ningún teléfono por USB. Conéctalo, activa «Depuración USB» y acepta la autorización en su pantalla.';
      }
      if (usb.length > 1) {
        return 'Hay más de un dispositivo USB conectado. Deja solo el teléfono.';
      }
      if (!await _AdbServer.hasTunnel(usb.first, phonePort, pcPort)) {
        await _AdbServer.forward(usb.first, phonePort);
        await _AdbServer.reverse(usb.first, pcPort);
      }
      return null;
    } catch (e) {
      return 'adb no pudo abrir el túnel: $e';
    }
  }

  /// True while both tunnels exist (a restarted adb server forgets them).
  static Future<bool> tunnelUp({
    required int phonePort,
    required int pcPort,
  }) async {
    try {
      final usb = (await _AdbServer.devices())
          .where((d) => !d.contains(':'))
          .toList();
      return usb.length == 1 &&
          await _AdbServer.hasTunnel(usb.first, phonePort, pcPort);
    } catch (_) {
      return false;
    }
  }

  static Future<Process> start(
    String serial, {
    required String title,
    bool screenOff = false,
    bool audio = true,
  }) => Process.start(
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

/// The adb server's own wire protocol (`<4 hex digits of length><request>` -> `OKAY`/`FAIL`), stable since the
/// first adb. Only what the tunnel needs.
class _AdbServer {
  static const _port = 5037;

  static Future<bool> up() async {
    try {
      (await Socket.connect(
        '127.0.0.1',
        _port,
        timeout: const Duration(seconds: 2),
      )).destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Sends each request in turn on one connection, waiting for its OKAY; returns what the server sent after
  /// the last one until it goes quiet or closes.
  static Future<String> _ask(List<String> requests) async {
    final s = await Socket.connect(
      '127.0.0.1',
      _port,
      timeout: const Duration(seconds: 2),
    );
    final buf = <int>[];
    var closed = false;
    s.listen(
      buf.addAll,
      onDone: () => closed = true,
      onError: (_) => closed = true,
    );
    Future<void> until(bool Function() ok, [int ms = 3000]) async {
      for (var i = 0; i < ms ~/ 20 && !ok() && !closed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    try {
      for (var i = 0; i < requests.length; i++) {
        final r = requests[i];
        s.add(
          ascii.encode(r.length.toRadixString(16).padLeft(4, '0')) +
              utf8.encode(r),
        );
        await until(() => buf.length >= 4);
        final status = latin1.decode(buf.take(4).toList());
        if (status == 'FAIL') {
          await until(() => buf.length >= 8);
          throw Exception(
            utf8.decode(buf.skip(8).toList(), allowMalformed: true),
          );
        }
        if (status != 'OKAY') throw Exception('respuesta inesperada de adb');
        buf.removeRange(0, 4);
        if (i < requests.length - 1) continue;
        // Let any second OKAY or payload arrive.
        var last = -1;
        for (var k = 0; k < 15 && buf.length != last && !closed; k++) {
          last = buf.length;
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }
      return utf8.decode(buf, allowMalformed: true);
    } finally {
      s.destroy();
    }
  }

  static String _payload(String r) => r.length >= 4 ? r.substring(4) : r;

  static Future<List<String>> devices() async => [
    for (final l in _payload(await _ask(['host:devices'])).split('\n'))
      if (RegExp(r'\sdevice$').hasMatch(l.trim()))
        l.trim().split(RegExp(r'\s+')).first,
  ];

  static Future<void> forward(String serial, int port) =>
      _ask(['host-serial:$serial:forward:tcp:$port;tcp:$port']);

  static Future<void> reverse(String serial, int port) =>
      _ask(['host:transport:$serial', 'reverse:forward:tcp:$port;tcp:$port']);

  static Future<bool> hasTunnel(
    String serial,
    int phonePort,
    int pcPort,
  ) async {
    final f = await _ask(['host-serial:$serial:list-forward']);
    final r = await _ask(['host:transport:$serial', 'reverse:list-forward']);
    return f.contains('tcp:$phonePort') && r.contains('tcp:$pcPort');
  }
}
