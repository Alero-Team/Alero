import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/app_info.dart';
import 'package:pb_app/updater.dart';

void main() {
  test('isNewerVersion compares numerically', () {
    expect(isNewerVersion('v2.5.2', '2.5.1'), isTrue);
    expect(isNewerVersion('v2.10.0', '2.9.9'), isTrue);
    expect(isNewerVersion('v3.0.0', '2.99.99'), isTrue);
    expect(isNewerVersion('v2.5.1', '2.5.1'), isFalse);
    expect(isNewerVersion('v2.5.0', '2.5.1'), isFalse);
    expect(isNewerVersion('2.5.2-beta', '2.5.1+40'), isTrue);
    expect(isNewerVersion('latest', '2.5.1'), isFalse);
    expect(isNewerVersion('v2.5.2', 'x'), isFalse);
  });

  test('aleroVersion matches pubspec.yaml', () {
    final v = RegExp(r'^version:\s*([^+\s]+)', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync())![1];
    expect(aleroVersion, v);
  });

  test('parseRelease picks the asset by exact name and ignores old releases', () {
    final j = {
      'tag_name': 'v2.6.0',
      'html_url': 'https://github.com/k0op4/Alero/releases/tag/v2.6.0',
      'assets': [
        {
          'name': 'Alero-2.6.0-android-arm64.apk',
          'browser_download_url': 'https://github.com/k0op4/Alero/releases/download/v2.6.0/Alero-2.6.0-android-arm64.apk',
          'digest': 'sha256:abc',
          'size': 10,
        },
      ],
    };
    final u = parseRelease(j, '2.5.1')!;
    expect(u.version, '2.6.0');
    expect(assetFor(u, UpdateKind.android)!.digest, 'sha256:abc');
    expect(assetFor(u, UpdateKind.windows), isNull);
    expect(assetFor(u, UpdateKind.page), isNull);
    expect(parseRelease(j, '2.6.0'), isNull);
  });

  test('downloadVerified refuses a missing or wrong digest', () async {
    final data = utf8.encode('alero');
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((r) => r.response
      ..add(data)
      ..close());
    final dir = Directory.systemTemp.createTempSync('alero-upd');
    final f = File('${dir.path}/a.bin');
    // The URL check pins GitHub, so a local server is refused before any request.
    final local = UpdateAsset('a', 'http://127.0.0.1:${server.port}/a', 'sha256:${sha256.convert(data)}', 5);
    await expectLater(
      downloadVerified(local, f, onProgress: (_) {}, cancelled: () => false),
      throwsA(isA<HttpException>()),
    );
    const noDigest = UpdateAsset('a', 'https://github.com/k0op4/Alero/x', '', 5);
    await expectLater(
      downloadVerified(noDigest, f, onProgress: (_) {}, cancelled: () => false),
      throwsA(isA<HttpException>()),
    );
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });
}
