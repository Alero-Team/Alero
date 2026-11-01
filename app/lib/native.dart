import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

class Shared {
  Shared(this.files, this.text);
  final List<Picked> files;
  final String text;
}

class Picked {
  Picked(this.path, this.name, [this.fd]);
  final String path; // real path, or `fd:N` on Android
  final String? name;
  final int? fd;
}

/// Everything platform-specific. Android goes through a small Kotlin channel (MainActivity.kt);
/// desktop uses the window plugin (the tray lives in the daemon). Nothing here decides protocol or trust.
class Native {
  static final lock = ValueNotifier(false);
  static Future<void> loadLock() async {
    lock.value =
        _android && (await _ch.invokeMethod<bool>('lockEnabled') ?? false);
  }

  static Future<bool> authenticate() async =>
      !_android || (await _ch.invokeMethod<bool>('authenticate') ?? false);
  static Future<bool> setLock(bool on) async {
    final ok = await _ch.invokeMethod<bool>('setLock', on) ?? false;
    if (ok) lock.value = on;
    return ok;
  }

  static Future<bool> firstLaunch() async =>
      !_android || (await _ch.invokeMethod<bool>('firstLaunch') ?? false);
  static Future<void> requestNotifications() async =>
      _ch.invokeMethod('requestNotifications');
  static Future<bool> installPermission() async =>
      _android && (await _ch.invokeMethod<bool>('installPermission') ?? false);
  static Future<void> requestInstallPermission() async =>
      _ch.invokeMethod('requestInstallPermission');
  static Future<bool> startupEnabled() async =>
      await const MethodChannel('pb/windows')
          .invokeMethod<bool>('startupEnabled') ??
      false;
  static Future<void> setStartup(bool on) async =>
      const MethodChannel('pb/windows').invokeMethod('setStartup', on);

  static Future<bool> allFiles() async =>
      _android && (await _ch.invokeMethod<bool>('allFiles') ?? false);
  static Future<void> requestAllFiles() async =>
      _ch.invokeMethod('requestAllFiles');
  static Future<void> rememberFile(String id, int fd) async {
    if (_android) await _ch.invokeMethod('rememberFile', {'id': id, 'fd': fd});
  }

  static Future<void> openFile(String path, {String? id}) async {
    if (_android) {
      await _ch.invokeMethod('openFile', {'path': path, 'id': id});
    } else if (Platform.isWindows) {
      await const MethodChannel('pb/windows').invokeMethod('openFile', path);
    } else {
      final result = await Process.run('xdg-open', [path]);
      if (result.exitCode != 0) {
        throw FileSystemException('No se pudo abrir', path);
      }
    }
  }

  static const _ch = MethodChannel('pb/android');
  static final _android = Platform.isAndroid;

  static Future<String> deviceName() async {
    if (_android) {
      return await _ch.invokeMethod<String>('deviceName') ?? 'Android';
    }
    return Platform.environment['COMPUTERNAME'] ??
        Platform.environment['HOSTNAME'] ??
        'Ordenador';
  }

  static Future<List<Picked>> pickFiles() async {
    if (!_android) {
      return [for (final f in await openFiles()) Picked(f.path, null)];
    }
    final l = await _ch.invokeListMethod<Map>('pickFiles') ?? [];
    return [
      for (final m in l)
        Picked('fd:${m['fd']}', m['name'] as String, m['fd'] as int),
    ];
  }

  static void closeFd(int fd) => _ch.invokeMethod('closeFd', fd);

  /// Android share menu: what another app shared with us, once.
  static Future<Shared?> takeShared() async {
    if (!_android) return null;
    final m = await _ch.invokeMapMethod<String, Object?>('takeShared');
    if (m == null) return null;
    final files = [
      for (final f in (m['files'] as List? ?? []))
        if (f is Map)
          Picked('fd:${f['fd']}', f['name'] as String, f['fd'] as int),
    ];
    return Shared(files, m['text'] as String? ?? '');
  }

  /// Called when Android hands us a new share while the app is open.
  static void onShared(Future<void> Function() f) {
    if (!_android) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'shared') await f();
    });
  }

  /// Android special access for notifications and media sessions (granted in system settings).
  static Future<bool> notifAccess() async =>
      _android && (await _ch.invokeMethod<bool>('notifAccess') ?? false);
  static Future<void> openNotifAccess() async =>
      _android ? _ch.invokeMethod('openNotifAccess') : null;
  static Future<bool> notifPermission() async =>
      !_android || (await _ch.invokeMethod<bool>('notifPermission') ?? true);
  static Future<void> openAppSettings() async =>
      _android ? _ch.invokeMethod('openAppSettings') : null;

  /// Opens Android's USB screen if this maker has one reachable; otherwise the general settings. It can never
  /// change the USB mode itself: that choice belongs to the user.
  static Future<void> openUsbSettings() async =>
      _android ? _ch.invokeMethod('openUsbSettings') : null;

  /// Android: files the computer may browse. `allowed` is the owner's switch, `permission` whether Android's media
  /// permission is granted, `folders` the folders picked with the system picker.
  static Future<
    ({
      bool allowed,
      bool permission,
      List<String> folders,
      Set<String> media,
      bool limited,
    })
  >
  files() async {
    if (!_android) {
      return (
        allowed: false,
        permission: false,
        folders: <String>[],
        media: <String>{},
        limited: false,
      );
    }
    final m = await _ch.invokeMapMethod<String, Object?>('files') ?? {};
    return (
      allowed: m['allowed'] == true,
      permission: m['permission'] == true,
      folders: [for (final f in (m['folders'] as List? ?? [])) '$f'],
      media: {
        for (final e in ((m['media'] as Map?) ?? {}).entries)
          if (e.value == true && e.key != 'limited') '${e.key}',
      },
      limited: ((m['media'] as Map?) ?? {})['limited'] == true,
    );
  }

  static Future<void> setFiles(bool on) async =>
      _android ? _ch.invokeMethod('setFiles', on) : null;

  /// Asks Android for the media permissions still missing. True when it will not ask again (settings only).
  static Future<bool> requestMedia() async =>
      _android && (await _ch.invokeMethod<bool>('requestMedia') ?? false);

  /// The app's own permission page in system settings (photos, music and so on live there).
  static Future<void> openPermissions() async =>
      _android ? _ch.invokeMethod('openPermissions') : null;
  static Future<bool> addFolder() async =>
      _android && (await _ch.invokeMethod<bool>('addFolder') ?? false);
  static Future<void> removeFolder(int i) async =>
      _android ? _ch.invokeMethod('removeFolder', i) : null;

  static Future<void> openDevSettings() async =>
      _android ? _ch.invokeMethod('openDevSettings') : null;

  /// Android: scans a QR with the camera (ZXing, no Google services). null if cancelled.
  static Future<String?> scanQr() async =>
      _android ? _ch.invokeMethod<String>('scanQr') : null;

  /// Android: pick an image (no permission: the system picker) to show as this phone's wallpaper on the computer.
  static Future<bool> pickWallpaper() async =>
      _android && (await _ch.invokeMethod<bool>('pickWallpaper') ?? false);
  static Future<void> clearWallpaper() async =>
      _android ? _ch.invokeMethod('clearWallpaper') : null;
  static Future<bool> hasWallpaper() async {
    final j = await deviceInfo();
    return j != null && jsonDecode(j)['wallpaper']?['custom'] == true;
  }

  /// This phone's own info (same JSON it sends as `pb.x.info`).
  static Future<String?> deviceInfo() async =>
      _android ? _ch.invokeMethod<String>('deviceInfo') : null;

  static Future<void> openFolder(String path) async {
    if (_android) return _ch.invokeMethod('openDownloads');
    Directory(path).createSync(recursive: true);
    await Process.start(Platform.isWindows ? 'explorer' : 'xdg-open', [path]);
  }

  /// Android: moves a received file to Downloads/Alero and returns where it went. Desktop: already there.
  static Future<String> publish(String path) async =>
      _android ? await _ch.invokeMethod<String>('publish', path) ?? '' : '';

  /// Android: keep listening in the background even with no computer connected (adds a silent notification).
  static Future<bool> background() async =>
      _android && (await _ch.invokeMethod<bool>('background') ?? false);
  static Future<void> setBackground(bool on) async =>
      _android ? _ch.invokeMethod('setBackground', on) : null;

  /// Something needs the user: a notification on Android, the window comes up on desktop.
  static void alert(String title, String text) {
    if (_android) {
      _ch.invokeMethod('alert', {'title': title, 'text': text});
    } else {
      showWindow();
    }
  }

  static Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// Desktop: closing the window ends this process; the engine keeps running in the tray daemon.
  static Future<void> initDesktop() async {
    if (_android) return;
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'Alero',
        size: Size(900, 680),
        minimumSize: Size(420, 480),
      ),
      () => windowManager.show(),
    );
  }
}
