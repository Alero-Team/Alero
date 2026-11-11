import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'native.dart';

/// Local, device-bound encryption: Android Keystore AES-256-GCM; Windows
/// DPAPI CurrentUser. The plaintext title and content are both encrypted.
/// No vault content is ever transmitted to a paired Alero device.
class VaultEntry {
  const VaultEntry({
    required this.id,
    required this.name,
    required this.kind,
    required this.data,
    required this.created,
  });

  final String id;
  final String name;
  final String kind; // note | file
  final String data; // note text or base64-encoded file content
  final DateTime created;
  bool get isNote => kind == 'note';
  int get bytes => isNote ? utf8.encode(data).length : (data.length * 3 ~/ 4);
  Uint8List get fileBytes => base64Decode(data);

  factory VaultEntry.fromMap(String id, Map<String, dynamic> map) {
    final kind = map['kind'] as String?;
    if (kind != 'note' && kind != 'file') {
      throw const FormatException('Formato de bóveda no admitido');
    }
    return VaultEntry(
      id: id,
      name: map['name'] as String? ?? 'Sin nombre',
      kind: kind!,
      data: map['data'] as String? ?? '',
      created: DateTime.parse(map['created'] as String),
    );
  }

  Map<String, String> toMap() => {
    'name': name,
    'kind': kind,
    'data': data,
    'created': created.toUtc().toIso8601String(),
  };
}

class VaultStore {
  static const maxFileBytes = 8 * 1024 * 1024;
  static const minKeyLength = 4;

  /// Windows: the vault key the user typed. It goes into DPAPI as extra entropy, so the records open only
  /// with this Windows account AND this key; Alero keeps it in memory while the vault is open and nowhere
  /// else. Android asks the system for the fingerprint or PIN instead (see the vault screen).
  String? _key;

  Future<File> _check() async =>
      File('${(await _folder()).path}${Platform.pathSeparator}vault.key');

  /// Whether a vault key was ever set on this computer.
  Future<bool> hasKey() async => (await _check()).exists();

  /// Sets the key for the first time and seals again, under it, whatever the vault already held.
  Future<void> createKey(String key) async {
    if (key.length < minKeyLength) {
      throw const FormatException('La clave necesita al menos 4 caracteres.');
    }
    final old = await list();
    _key = key;
    for (final entry in old) {
      await store(entry);
    }
    await (await _check()).writeAsBytes(
      await _seal(Uint8List.fromList(utf8.encode('alero-vault'))),
      flush: true,
    );
  }

  /// True when [key] opens the vault. A wrong key opens nothing: there is no stored copy to compare with.
  Future<bool> unlock(String key) async {
    _key = key;
    try {
      await _open(await (await _check()).readAsBytes());
      return true;
    } catch (_) {
      _key = null;
      return false;
    }
  }

  void lock() => _key = null;

  Future<Directory> _folder() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}secure-vault-v1')
        .create(recursive: true);
  }

  static String _newId() {
    final random = Random.secure();
    return base64UrlEncode(
      Uint8List.fromList(List<int>.generate(18, (_) => random.nextInt(256))),
    ).replaceAll('=', '');
  }

  static bool _validId(String id) =>
      RegExp(r'^[A-Za-z0-9_-]{24}$').hasMatch(id);

  Future<Uint8List> _seal(Uint8List data) async {
    if (Platform.isAndroid) return Native.vaultSeal(data);
    if (Platform.isWindows) return _windowsCrypt(data, true, _key);
    throw UnsupportedError('Alero Vault solo admite Android y Windows.');
  }

  Future<Uint8List> _open(Uint8List data) async {
    if (Platform.isAndroid) return Native.vaultOpen(data);
    if (Platform.isWindows) return _windowsCrypt(data, false, _key);
    throw UnsupportedError('Alero Vault solo admite Android y Windows.');
  }

  /// PowerShell receives the secret on standard input, never in arguments.
  /// DPAPI binds encrypted data to the current Windows user profile.
  static Future<Uint8List> _windowsCrypt(
    Uint8List input,
    bool seal,
    String? key,
  ) async {
    final api = seal ? 'Protect' : 'Unprotect';
    final script = [
      "\$ErrorActionPreference = 'Stop'",
      // Windows PowerShell does not load this assembly by itself: without it the type below does not exist.
      "Add-Type -AssemblyName System.Security",
      "\$b = [Convert]::FromBase64String([Console]::In.ReadLine())",
      "\$k = [Console]::In.ReadLine()",
      "\$e = if (\$k) { [Convert]::FromBase64String(\$k) } else { \$null }",
      "\$out = [System.Security.Cryptography.ProtectedData]::$api(\$b, \$e, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)",
      "[Console]::Out.Write([Convert]::ToBase64String(\$out))",
    ].join('; ');
    final process = await Process.start('powershell.exe', [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ]);
    process.stdin.writeln(base64Encode(input));
    process.stdin.writeln(key == null ? '' : base64Encode(utf8.encode(key)));
    await process.stdin.close();
    final stdoutText = await process.stdout.transform(utf8.decoder).join();
    await process.stderr.drain<void>();
    if (await process.exitCode != 0) {
      throw const FormatException(
        'No se pudo proteger o abrir el contenido de la bóveda.',
      );
    }
    return base64Decode(stdoutText.trim());
  }

  Future<List<VaultEntry>> list() async {
    final root = await _folder();
    final entries = <VaultEntry>[];
    await for (final item in root.list(followLinks: false)) {
      if (item is! File || !item.path.endsWith('.avlt')) continue;
      final name = item.uri.pathSegments.last;
      final id = name.substring(0, name.length - '.avlt'.length);
      if (!_validId(id)) continue;
      // Never ignore failed authentication / corrupt records silently.
      final decoded = jsonDecode(
        utf8.decode(await _open(await item.readAsBytes())),
      );
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Registro cifrado inválido');
      }
      entries.add(VaultEntry.fromMap(id, decoded));
    }
    entries.sort((a, b) => b.created.compareTo(a.created));
    return entries;
  }

  Future<void> store(VaultEntry entry) async {
    if (!_validId(entry.id)) throw const FormatException('ID inválido');
    if (entry.name.trim().isEmpty || entry.name.length > 180) {
      throw const FormatException('Nombre inválido');
    }
    final root = await _folder();
    final sealed = await _seal(
      Uint8List.fromList(utf8.encode(jsonEncode(entry.toMap()))),
    );
    final target = File(
      '${root.path}${Platform.pathSeparator}${entry.id}.avlt',
    );
    final tmp = File('${target.path}.partial');
    try {
      await tmp.writeAsBytes(sealed, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  Future<VaultEntry> saveNote(
    String name,
    String text, {
    VaultEntry? existing,
  }) async {
    final entry = VaultEntry(
      id: existing?.id ?? _newId(),
      name: name.trim(),
      kind: 'note',
      data: text,
      created: existing?.created ?? DateTime.now().toUtc(),
    );
    await store(entry);
    return entry;
  }

  Future<void> saveFile(String name, Uint8List bytes) async {
    if (bytes.length > maxFileBytes) {
      throw const FormatException('Archivo demasiado grande (máximo 8 MB).');
    }
    await store(
      VaultEntry(
        id: _newId(),
        name: name,
        kind: 'file',
        data: base64Encode(bytes),
        created: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> remove(VaultEntry entry) async {
    if (!_validId(entry.id)) throw const FormatException('ID inválido');
    final root = await _folder();
    final file = File('${root.path}${Platform.pathSeparator}${entry.id}.avlt');
    if (await file.exists()) await file.delete();
  }
}
