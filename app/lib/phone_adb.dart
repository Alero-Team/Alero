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
  static Future<AdbDevice?> find(pb.Peer phone, String model) async =>
      Scrcpy.available ? adbFor(await Scrcpy.list(), phone, model) : null;

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
