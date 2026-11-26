import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'app_info.dart';
import 'l10n.dart' show tx;
import 'native.dart';

const _api = 'https://api.github.com/repos/k0op4/Alero/releases/latest';
const _releaseBase = 'https://github.com/k0op4/Alero/';

/// True when [remote] is a higher `X.Y.Z` than [local] (a leading `v` and any `-beta`/`+build` suffix are ignored).
bool isNewerVersion(String remote, String local) {
  List<int>? parse(String v) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(v.trim());
    return m == null ? null : [for (var i = 1; i <= 3; i++) int.parse(m[i]!)];
  }

  final r = parse(remote), l = parse(local);
  if (r == null || l == null) return false;
  for (var i = 0; i < 3; i++) {
    if (r[i] != l[i]) return r[i] > l[i];
  }
  return false;
}

/// A release asset: where to download it and the SHA-256 GitHub reports for it.
class UpdateAsset {
  const UpdateAsset(this.name, this.url, this.digest, this.size);
  final String name, url, digest;
  final int size;
}

class UpdateInfo {
  const UpdateInfo(this.version, this.page, this.assets);
  final String version, page;
  final List<UpdateAsset> assets;

  UpdateAsset? asset(String suffix) {
    for (final a in assets) {
      if (a.name == 'Alero-$version-$suffix') return a;
    }
    return null;
  }
}

/// How this install updates itself.
enum UpdateKind { android, windows, appImage, deb, rpm, page }

UpdateKind updateKind() {
  if (Platform.isAndroid) return UpdateKind.android;
  if (Platform.isWindows) return UpdateKind.windows;
  if (!Platform.isLinux) return UpdateKind.page;
  if ((Platform.environment['APPIMAGE'] ?? '').isNotEmpty) {
    return UpdateKind.appImage;
  }
  if (!Platform.resolvedExecutable.startsWith('/usr/')) return UpdateKind.page;
  if (File('/etc/debian_version').existsSync()) return UpdateKind.deb;
  return File('/usr/bin/rpm').existsSync() ? UpdateKind.rpm : UpdateKind.page;
}

String _suffix(UpdateKind k) => switch (k) {
  UpdateKind.android => 'android-arm64.apk',
  UpdateKind.windows => 'windows-x64-setup.exe',
  UpdateKind.appImage => 'linux-x86_64.AppImage',
  UpdateKind.deb => 'linux-amd64.deb',
  UpdateKind.rpm => 'linux-x86_64.rpm',
  UpdateKind.page => '',
};

/// The asset this install needs, or null when it can only open the release page.
UpdateAsset? assetFor(UpdateInfo u, UpdateKind k) =>
    k == UpdateKind.page ? null : u.asset(_suffix(k));

/// Parses the GitHub "latest release" JSON; null when it is not a version newer than [local].
UpdateInfo? parseRelease(Map<String, dynamic> j, String local) {
  final tag = j['tag_name'] as String? ?? '';
  if (!isNewerVersion(tag, local)) return null;
  final version = tag.replaceFirst(RegExp(r'^v'), '');
  return UpdateInfo(
    version,
    j['html_url'] as String? ?? _releaseBase,
    [
      for (final a in (j['assets'] as List? ?? []).whereType<Map>())
        UpdateAsset(
          a['name'] as String? ?? '',
          a['browser_download_url'] as String? ?? '',
          a['digest'] as String? ?? '',
          (a['size'] as num?)?.toInt() ?? 0,
        ),
    ],
  );
}

HttpClient _client() => HttpClient()
  ..userAgent = 'Alero-Updater'
  ..connectionTimeout = const Duration(seconds: 15);

/// The newest release if it is newer than this app, else null. Throws on network or format errors.
Future<UpdateInfo?> checkForUpdate() async {
  final c = _client();
  try {
    final req = await c.getUrl(Uri.parse(_api));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('GitHub ${res.statusCode}');
    }
    final body = await res.transform(utf8.decoder).join();
    return parseRelease(jsonDecode(body) as Map<String, dynamic>, aleroVersion);
  } finally {
    c.close(force: true);
  }
}

/// Downloads [a] to [dest] and checks its SHA-256 against GitHub's digest; the file is deleted and an error thrown
/// when the digest is missing or different, or when [cancelled] turns true.
Future<void> downloadVerified(
  UpdateAsset a,
  File dest, {
  required void Function(double?) onProgress,
  required bool Function() cancelled,
}) async {
  if (!a.url.startsWith(_releaseBase) || !a.digest.startsWith('sha256:')) {
    throw HttpException(tx('La actualización no trae una huella SHA-256 válida.'));
  }
  final want = a.digest.substring(7).toLowerCase();
  final c = _client();
  try {
    final req = await c.getUrl(Uri.parse(a.url));
    final res = await req.close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('GitHub ${res.statusCode}');
    }
    final total = res.contentLength > 0 ? res.contentLength : a.size;
    var got = 0;
    final out = dest.openWrite();
    try {
      await for (final chunk in res) {
        if (cancelled()) throw const _Cancelled();
        out.add(chunk);
        got += chunk.length;
        onProgress(total > 0 ? (got / total).clamp(0, 1).toDouble() : null);
      }
    } catch (_) {
      await out.close();
      if (dest.existsSync()) dest.deleteSync();
      rethrow;
    }
    await out.close();
    final got256 = (await sha256.bind(dest.openRead()).first).toString();
    if (got256 != want) {
      dest.deleteSync();
      throw HttpException(
        tx('La descarga no coincide con la huella SHA-256 publicada. No se instaló.'),
      );
    }
  } finally {
    c.close(force: true);
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

bool isCancelled(Object e) => e is _Cancelled;

/// Where the download goes: next to the AppImage (so the swap is one atomic rename), else the cache folder.
Future<File> updateFile(UpdateAsset a, UpdateKind k) async {
  if (k == UpdateKind.appImage) {
    return File('${Platform.environment['APPIMAGE']}.update');
  }
  final dir = Directory('${(await getTemporaryDirectory()).path}/alero-update');
  dir.createSync(recursive: true);
  return File('${dir.path}/${a.name}');
}

/// Hands the verified file over. Android shows the system installer; Windows runs the setup silently (it closes
/// Alero and reopens it) and this process leaves; the .deb/.rpm opens in the software installer. An AppImage is
/// swapped in place and the caller offers [restartAppImage].
Future<void> installUpdate(UpdateKind k, File f) async {
  switch (k) {
    case UpdateKind.android:
      await Native.installApk(f.path);
    case UpdateKind.windows:
      await Process.start(f.path, [
        '/SILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/ReopenAlero=1',
      ], mode: ProcessStartMode.detached);
      exit(0);
    case UpdateKind.appImage:
      final r = await Process.run('chmod', ['+x', f.path]);
      if (r.exitCode != 0) throw FileSystemException('chmod', f.path);
      await f.rename(Platform.environment['APPIMAGE']!);
    case UpdateKind.deb || UpdateKind.rpm:
      final r = await Process.run('xdg-open', [f.path]);
      if (r.exitCode != 0) throw FileSystemException('xdg-open', f.path);
    case UpdateKind.page:
      break;
  }
}

Future<void> restartAppImage() async {
  await Process.start(Platform.environment['APPIMAGE']!, const [], mode: ProcessStartMode.detached);
  exit(0);
}
