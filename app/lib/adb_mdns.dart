import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// An adb service a phone announces: `adb-<serial>-xyz` (connect) or the QR's name (pairing).
typedef AdbService = ({String name, String ip, int port});

/// Many routers drop multicast, so `adb mdns services` stays empty even with wireless debugging on.
/// Android still answers an mDNS question sent straight to its port 5353, so ask each host directly.
class AdbMdns {
  static const connect = '_adb-tls-connect._tcp.local';
  static const pairing = '_adb-tls-pairing._tcp.local';

  /// Asks [hosts] (or every address of this computer's IPv4 networks) for [type] services.
  static Future<List<AdbService>> query(
    String type, {
    List<String>? hosts,
    Duration wait = const Duration(milliseconds: 1500),
  }) async {
    final targets = hosts ?? await _neighbours();
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final found = <AdbService>[];
    final sub = socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null) return;
      try {
        found.addAll(parse(d.data, d.address.address, type));
      } catch (_) {
        // A malformed or unrelated reply: ignore it.
      }
    });
    final q = question(type);
    for (final h in targets) {
      // A full send buffer drops the packet (send returns 0): wait and retry.
      for (var tries = 0; tries < 20; tries++) {
        if (socket.send(q, InternetAddress(h), 5353) > 0) break;
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }
    await Future.delayed(wait);
    await sub.cancel();
    socket.close();
    return {for (final s in found) '${s.name}@${s.ip}': s}.values.toList();
  }

  /// Every host of the /24 networks this computer is on (where a phone on the same Wi-Fi lives).
  static Future<List<String>> _neighbours() async {
    final out = <String>{};
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      // Virtual machines' adapters never hold the phone and only slow the sweep down.
      if (RegExp(
        r'vmware|virtualbox|vethernet|hyper-v|wsl',
        caseSensitive: false,
      ).hasMatch(i.name))
        continue;
      for (final a in i.addresses) {
        if (a.isLoopback || a.isLinkLocal) continue;
        final p = a.address.split('.');
        for (var n = 1; n < 255; n++) {
          out.add('${p[0]}.${p[1]}.${p[2]}.$n');
        }
      }
    }
    return out.toList();
  }

  /// A PTR question for [type] asking for a unicast answer (QU bit).
  static Uint8List question(String type) {
    final b = BytesBuilder()..add([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    for (final label in type.split('.')) {
      b.addByte(label.length);
      b.add(label.codeUnits);
    }
    b.add([0, 0, 0x0c, 0x80, 0x01]);
    return b.toBytes();
  }

  /// The [type] services (instance name and SRV port) in a reply from [ip].
  static List<AdbService> parse(Uint8List d, String ip, String type) {
    final v = ByteData.sublistView(d);
    var o = 12;
    String name() {
      final labels = <String>[];
      var p = o, jumped = false, hops = 0;
      while (true) {
        final len = d[p];
        if (len == 0) {
          p++;
          break;
        }
        if (len & 0xc0 == 0xc0) {
          if (++hops > 20) throw const FormatException('loop');
          if (!jumped) o = p + 2;
          jumped = true;
          p = v.getUint16(p) & 0x3fff;
          continue;
        }
        labels.add(String.fromCharCodes(d, p + 1, p + 1 + len));
        p += len + 1;
      }
      if (!jumped) o = p;
      return labels.join('.');
    }

    final questions = v.getUint16(4);
    final records = v.getUint16(6) + v.getUint16(8) + v.getUint16(10);
    for (var i = 0; i < questions; i++) {
      name();
      o += 4;
    }
    final out = <AdbService>[];
    for (var i = 0; i < records; i++) {
      final owner = name();
      final rtype = v.getUint16(o);
      final len = v.getUint16(o + 8);
      final data = o + 10;
      if (rtype == 33 && owner.toLowerCase().endsWith('.$type')) {
        out.add((
          name: owner.substring(0, owner.length - type.length - 1),
          ip: ip,
          port: v.getUint16(data + 4),
        ));
      }
      o = data + len;
    }
    return out;
  }
}
