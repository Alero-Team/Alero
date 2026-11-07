import 'package:flutter/foundation.dart';

import 'phone_control.dart';
import 'scrcpy.dart';
import 'src/rust/api/engine.dart' as pb;

/// The adb connection (USB cable or wireless debugging) of a paired phone: one on the phone's Wi-Fi address,
/// else one of the same model over USB, else the only ready device. Null without one.
AdbDevice? adbFor(List<AdbDevice> devices, pb.Peer phone, String model) {
  final i = phone.addr.lastIndexOf(':');
  final ip = i > 0 ? phone.addr.substring(0, i) : '';
  final ready = devices.where((d) => d.ready).toList();
  final m = model.toLowerCase().replaceAll(' ', '_');
  return ready
          .where((d) => ip.isNotEmpty && d.serial.startsWith('$ip:'))
          .firstOrNull ??
      ready
          .where(
            (d) =>
                m.isNotEmpty && d.model.toLowerCase().replaceAll(' ', '_') == m,
          )
          .firstOrNull ??
      (ready.length == 1 ? ready.first : null);
}

/// What only adb can do on a phone (Android keeps Wi-Fi and Bluetooth away from ordinary apps).
abstract final class PhoneAdb {
  // Shared across Dispositivos, Aplicaciones and Alero Desktop. The user
  // explicitly chooses an ADB transport; do not silently switch to a different
  // phone after selecting one. No pairing secrets are stored here.
  static final selectedChanged = ValueNotifier<int>(0);
  static final _chosen = <String, String>{};

  static void choose(String peerId, String serial) {
    _chosen[peerId] = serial;
    selectedChanged.value++;
  }

  static void forgetChoice(String peerId) {
    _chosen.remove(peerId);
    selectedChanged.value++;
  }

  static Future<AdbDevice?> find(pb.Peer phone, String model) async {
    if (!Scrcpy.available) return null;
    final list = await Scrcpy.list();
    final serial = _chosen[phone.id];
    final d = serial != null
        ? list.where((d) => d.serial == serial && d.ready).firstOrNull
        : adbFor(list, phone, model);
    if (d != null) return d;
    // A chosen USB cable that was unplugged has nothing to reconnect over Wi-Fi.
    if (serial != null && !AdbDevice(serial, '', '').wifi) return null;
    final t = await (_reconnecting[phone.id] ??= _reconnect(
      phone,
      serial,
    ).whenComplete(() => _reconnecting.remove(phone.id)));
    if (t == null) return null;
    return (await Scrcpy.list())
        .where((d) => d.serial == t && d.ready)
        .firstOrNull;
  }

  static final _reconnecting = <String, Future<String?>>{};

  /// After a Wi-Fi drop Android reopens wireless debugging on a new port (and maybe a new IP). The computer
  /// stays paired, so mDNS finds the new port and `adb connect` needs no code: the user does nothing.
  static Future<String?> _reconnect(pb.Peer phone, String? stale) async {
    String ipOf(String a) {
      final i = a.lastIndexOf(':');
      return i > 0 ? a.substring(0, i) : '';
    }

    final ips = {
      ipOf(phone.addr),
      if (stale != null) ipOf(stale),
    }.where((ip) => ip.isNotEmpty && !ip.startsWith('127.'));
    for (final ip in ips) {
      final t = await Scrcpy.find(ip).catchError((_) => null);
      if (t == null || !await Scrcpy.connect(t).catchError((_) => false)) {
        continue;
      }
      if (stale != null && stale != t) {
        // The old ip:port stays "offline" in adb forever otherwise.
        await Scrcpy.disconnectWireless(stale).catchError((_) {});
        choose(phone.id, t);
      }
      return t;
    }
    return null;
  }

  /// A selection made by the user in any of the three sections remains
  /// available to the other sections for that same paired phone.
  static String? selectedSerial(String peerId) => _chosen[peerId];

  /// (Wi-Fi on, Bluetooth on), read from the phone's global settings.
  static Future<(bool, bool)> radios(String serial) async {
    final out = await Scrcpy.shell(
      serial,
      'settings get global wifi_on; settings get global bluetooth_on',
    );
    final v = out.trim().split(RegExp(r'\s+'));
    return (v.isNotEmpty && v[0] != '0', v.length > 1 && v[1] == '1');
  }

  static Future<void> setWifi(String serial, bool on) =>
      Scrcpy.shell(serial, 'svc wifi ${on ? 'enable' : 'disable'}');

  static Future<void> setBluetooth(String serial, bool on) => Scrcpy.shell(
    serial,
    'cmd bluetooth_manager ${on ? 'enable' : 'disable'}',
  );

  /// Android has no command to start the hotspot: this opens its settings screen on the phone.
  static Future<void> openHotspot(String serial) =>
      Scrcpy.shell(serial, 'am start -a android.settings.TETHER_SETTINGS');

  static Future<void> lock(String serial) =>
      Scrcpy.shell(serial, 'input keyevent 223');
}
