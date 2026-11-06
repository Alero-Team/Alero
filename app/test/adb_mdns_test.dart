import 'dart:typed_data';

import 'package:pb_app/adb_mdns.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);

void main() {
  // A Pixel 9a's real answer to a unicast question (wireless debugging on, port 34615).
  final reply = _hex(
    '000084000000000100000006105f6164622d746c732d636f6e6e656374045f746370056c6f63616c00000c000100001194001c196164622d41424344313233344546474835362d51476f657331c00c10416e64726f69645f534b593052453052c022002f8001000000780008c04f000440000008c04f001c8001000000780010fe800000000000000200000000000001c0330010800100001194004713676976656e5f6e616d653d506978656c2039611573657269616c3d414243443132333445464748353605763d322e31086170693d33372e310d6e616d653d506978656c203961c033002f8001000000780009c03300050000800040c03300218001000000780008000000008737c04fc04f00018001000000780004c000021d',
  );

  test('reads the connect service and its port from a real reply', () {
    expect(AdbMdns.parse(reply, '192.0.2.29', AdbMdns.connect), [
      (name: 'adb-ABCD1234EFGH56-QGoes1', ip: '192.0.2.29', port: 34615),
    ]);
  });

  test('a reply about another service type gives nothing', () {
    expect(AdbMdns.parse(reply, '192.0.2.29', AdbMdns.pairing), isEmpty);
  });

  test('the question asks for PTR records with a unicast answer', () {
    final q = AdbMdns.question(AdbMdns.pairing);
    expect(q.sublist(q.length - 4), [0, 0x0c, 0x80, 0x01]);
    expect(String.fromCharCodes(q, 13, 13 + 16), '_adb-tls-pairing');
  });

  test('truncated data throws instead of looping', () {
    expect(
      () => AdbMdns.parse(reply.sublist(0, 40), '1.1.1.1', AdbMdns.connect),
      throwsA(anything),
    );
  });
}
