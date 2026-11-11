import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'adb_mdns.dart';
import 'phone_control.dart';

/// A screen of the phone as `scrcpy --list-displays` prints it.
class PhoneDisplay {
  const PhoneDisplay(this.id, this.description);
  final int id;
  final String description;

  static List<PhoneDisplay> parse(String output) {
    final ids = <int, PhoneDisplay>{};
    for (final line in output.split('\n')) {
      final id = int.tryParse(
        RegExp(r'--display-id=(\d+)').firstMatch(line)?.group(1) ?? '',
      );
      if (id != null) ids[id] = PhoneDisplay(id, line.trim());
    }
    return ids.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }
}

/// Desktop wrapper around the bundled scrcpy + adb (Apache-2.0). The phone must have wireless
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

  /// First time only: the code and port from "Vincular dispositivo con código" on Android.
  /// Feed the one-time code through stdin, not on the process command line
  /// (which would expose it to local process-list readers). Never log it.
  static Future<String> pair(String ip, String port, String code) async {
    final process = await Process.start(
      _adb,
      ['pair', '$ip:$port'],
      environment: {'ADB_MDNS_AUTO_CONNECT': 'adb-tls-connect'},
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    process.stdin.writeln(code);
    await process.stdin.close();
    final status = await process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    final output = await stdout;
    // Drain stderr but do not return it (errors may echo sensitive data).
    await stderr;
    if (status != 0 || !output.contains('Successfully paired')) {
      throw StateError(
        'No se pudo vincular ADB. Comprueba la IP, el puerto y el código temporal.',
      );
    }
    return 'Dispositivo vinculado correctamente con Android.';
  }

  /// "Vincular con código QR": the phone, after scanning, announces the QR's service name for pairing.
  /// Returns its `ip:port`, or null while it has not appeared yet.
  static Future<String?> findPairing(String name) async {
    final r = await _run(['mdns', 'services']);
    for (final l in '${r.stdout}'.split('\n')) {
      final m = RegExp(
        r'^(\S+)\s+_adb-tls-pairing\._tcp\.?\s+(\d+\.\d+\.\d+\.\d+:\d+)',
      ).firstMatch(l.trim());
      if (m != null && m[1] == name) return m[2];
    }
    // The router may drop multicast: ask every neighbour directly.
    final s = (await AdbMdns.query(AdbMdns.pairing))
        .where((s) => s.name == name)
        .firstOrNull;
    return s == null ? null : '${s.ip}:${s.port}';
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
    final s = (await AdbMdns.query(
      AdbMdns.connect,
      hosts: [ip],
    )).where((s) => s.ip == ip).firstOrNull;
    return s == null ? null : '${s.ip}:${s.port}';
  }

  static Future<bool> connect(String target) async {
    // The first attempt after the phone wakes its wireless debugging often fails and the next one works.
    for (var i = 0; i < 2; i++) {
      final r = await _run(['connect', target]);
      // A success-looking string alone is not proof of authorization.
      if (r.exitCode == 0 && (await devices()).contains(target)) return true;
    }
    return false;
  }

  /// Disconnects only the ADB Wi-Fi transport; it does not forget the Alero
  /// peer, its TLS identity or its app-level pairing.
  static Future<void> disconnectWireless(String serial) async {
    if (!serial.contains(':') && !serial.contains('._adb-tls')) return;
    await _run(['disconnect', serial]);
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

  /// Every device adb sees, authorised or not, with its model (`adb devices -l`).
  static Future<List<AdbDevice>> list() async =>
      parseDevices('${(await _run(['devices', '-l'])).stdout}');

  /// The phone's screen as a PNG file on this computer (`screencap`, what the power+volume keys take).
  static Future<void> screenshot(String serial, String path) async {
    final r = await Process.run(_adb, [
      '-s',
      serial,
      'exec-out',
      'screencap',
      '-p',
    ], stdoutEncoding: null).timeout(const Duration(seconds: 20));
    final bytes = r.stdout as List<int>;
    // A locked or protected screen answers with an error text instead of a picture.
    if (r.exitCode != 0 || bytes.length < 8 || bytes[1] != 0x50) {
      throw StateError('Android no entregó la captura.');
    }
    await File(path).writeAsBytes(bytes, flush: true);
  }

  /// One shell command on the phone; its output, trimmed.
  static Future<String> shell(String serial, String command) async =>
      '${(await _run(['-s', serial, 'shell', command])).stdout}'.trim();

  /// Display IDs actually advertised by this version of scrcpy + Android.
  static Future<List<PhoneDisplay>> displays(String serial) async {
    final r = await Process.run(
      _scrcpy,
      ['-s', serial, '--list-displays'],
      environment: {'ADB': _adb},
    ).timeout(const Duration(seconds: 20));
    if (r.exitCode != 0) throw StateError('${r.stderr}');
    final found = PhoneDisplay.parse('${r.stdout}\n${r.stderr}');
    return found.isEmpty
        ? [const PhoneDisplay(0, 'Pantalla principal')]
        : found;
  }

  /// A hardware key on the phone (back, home, volume…), as Android's `input keyevent`.
  /// Spoken to the running adb server: no extra adb process per tap (and none of another adb version, which
  /// would restart the server and cut the scrcpy session).
  static Future<void> key(String serial, int code) =>
      _AdbServer._ask(['host:transport:$serial', 'shell:input keyevent $code']);

  static Future<Process> launch(List<String> args) => Process.start(
    _scrcpy,
    args,
    environment: {'ADB': _adb},
    // Attached stdio uses CREATE_NO_WINDOW for Windows console programs in
    // Dart's process launcher. This hides scrcpy's auxiliary console but
    // keeps its SDL phone window visible. It also exposes the real exit code
    // so the session ends when scrcpy exits, not when a pipe happens to close.
    mode: ProcessStartMode.normal,
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
