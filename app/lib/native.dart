import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';


class Picked {
  Picked(this.path, this.name, [this.fd]);
  final String path; // real path, or `fd:N` on Android
  final String? name;
  final int? fd;
}

/// Everything platform-specific. Android goes through a small Kotlin channel (MainActivity.kt);
/// desktop uses the window plugin (the tray lives in the daemon). Nothing here decides protocol or trust.
class Native {
  static const _ch = MethodChannel('pb/android');
  static final _android = Platform.isAndroid;

  static Future<String> deviceName() async {
    if (_android) return await _ch.invokeMethod<String>('deviceName') ?? 'Android';
    return Platform.environment['COMPUTERNAME'] ?? Platform.environment['HOSTNAME'] ?? 'Ordenador';
  }

  static Future<List<Picked>> pickFiles() async {
    if (!_android) return [for (final f in await openFiles()) Picked(f.path, null)];
    final l = await _ch.invokeListMethod<Map>('pickFiles') ?? [];
    return [for (final m in l) Picked('fd:${m['fd']}', m['name'] as String, m['fd'] as int)];
  }

  static void closeFd(int fd) => _ch.invokeMethod('closeFd', fd);

  /// Android: moves a received file to Downloads/Phonebridge and returns where it went. Desktop: already there.
  static Future<String> publish(String path) async =>
      _android ? await _ch.invokeMethod<String>('publish', path) ?? '' : '';

  /// Android: text of the ongoing service notification.
  static void status(String text) {
    if (_android) _ch.invokeMethod('status', text);
  }

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
      const WindowOptions(title: 'Phonebridge', size: Size(900, 680), minimumSize: Size(420, 480)),
      () => windowManager.show(),
    );
  }
}
