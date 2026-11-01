import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/device_image.dart';
import 'package:pb_app/remote.dart';

Map<String, Object?> file(
  String title, {
  String mime = 'image/png',
  String license = 'CC BY-SA 4.0',
  int w = 480,
  int h = 960,
  String desc = '',
  String cats = '',
}) => {
  'title': 'File:$title',
  'index': 1,
  'imageinfo': [
    {
      'mime': mime,
      'width': w,
      'height': h,
      'thumburl':
          'https://thumb.wikimedia.org/${Uri.encodeComponent(title)}.png',
      'extmetadata': {
        'LicenseShortName': {'value': license},
        'Artist': {'value': '<a href="x">Ana</a>'},
        'ImageDescription': {'value': desc},
        'Categories': {'value': cats},
      },
    },
  ],
};

/// Google's list: UTF-16LE with BOM, every field quoted.
Uint8List csv(List<List<String>> rows) {
  final text = [
    'Retail Branding,Marketing Name,Device,Model',
    for (final r in rows) r.map((c) => '"$c"').join(','),
  ].join('\n');
  final b = BytesBuilder()..add([0xFF, 0xFE]);
  for (final u in text.codeUnits) {
    b.add([u & 0xFF, u >> 8]);
  }
  return b.toBytes();
}

class Net {
  Net(this.files, {this.rows = const [], this.down = false});
  final Map<String, List<Map<String, Object?>>> files; // search text -> results
  final List<List<String>> rows;
  bool down;
  final urls = <String>[];

  Future<Uint8List> call(Uri u) async {
    urls.add(u.toString());
    if (down) throw const SocketException('offline');
    if (u.host == 'storage.googleapis.com') return csv(rows);
    if (u.host == 'commons.wikimedia.org') {
      final pages = files[u.queryParameters['gsrsearch']] ?? [];
      return utf8.encode(
        jsonEncode({
          'query': {'pages': pages},
        }),
      );
    }
    return Uint8List.fromList(List.filled(2048, 7)); // the picture
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('alero-art'));
  tearDown(() => dir.deleteSync(recursive: true));
  DeviceImages images(Net n) => DeviceImages(() async => dir, fetch: n.call);

  const pixel8 = PhoneId(
    manufacturer: 'Google',
    brand: 'google',
    model: 'Pixel 8',
    device: 'shiba',
    marketName: 'Pixel 8',
  );
  const pixel9 = PhoneId(
    manufacturer: 'Google',
    brand: 'google',
    model: 'Pixel 9',
    device: 'tokay',
    marketName: 'Pixel 9',
  );

  test('a model only matches its own words, not a bigger sibling', () {
    bool m(String title, String name) =>
        matchesModel(titleTokens(title), nameTokens(name));
    expect(m('File:Google Pixel 9 (Obsidian) front.svg', 'Pixel 9'), isTrue);
    expect(m('File:Google Pixel 9 Pro XL.jpg', 'Pixel 9'), isFalse);
    expect(m('File:Google Pixel 8a.jpg', 'Pixel 8'), isFalse);
    expect(m('File:Samsung Galaxy S24 Ultra.jpg', 'Galaxy S24'), isFalse);
    expect(m('File:Samsung Galaxy S24+.jpg', 'Galaxy S24'), isFalse);
    expect(m('File:Samsung Galaxy S24+.jpg', 'Galaxy S24+'), isTrue);
    expect(m('File:Redmi Note 13 5G.jpg', 'Redmi Note 13'), isTrue);
    expect(m('File:Redmi Note 13 Pro.jpg', 'Redmi Note 13'), isFalse);
    expect(m('File:Moto G54 2023.jpg', 'Moto G54'), isFalse);
    expect(m('File:Samsung Galaxy S24 01.jpg', 'Galaxy S24'), isTrue);
  });

  test('Pixel 8 and Pixel 9 each get their own picture', () async {
    final net = Net({
      'Google Pixel 8': [
        file('Google Pixel 9 front.png'),
        file('Google Pixel 8 front.png'),
      ],
      'Google Pixel 9': [
        file('Google Pixel 9 Pro.png'),
        file('Google Pixel 9 front.png'),
      ],
    });
    final a = await images(net).look(pixel8);
    final b = await images(net).look(pixel9);
    expect(a.name, 'Google Pixel 8');
    expect(b.name, 'Google Pixel 9');
    expect(a.file!.path, isNot(b.file!.path));
    expect(net.urls.where((u) => u.contains('Pixel%209%20Pro')), isEmpty);
    expect(a.credit, 'Ana · CC BY-SA 4.0 · Wikimedia Commons');
  });

  test(
    'a cached model needs no network, even in a new session and offline',
    () async {
      final net = Net({
        'Google Pixel 8': [file('Google Pixel 8 front.png')],
      });
      await images(net).look(pixel8);
      final offline = Net({}, down: true);
      final again = await images(offline).look(pixel8);
      expect(again.file!.existsSync(), isTrue);
      expect(offline.urls, isEmpty);
    },
  );

  test(
    'offline without cache: name only, no error, and it tries again later',
    () async {
      final net = Net({}, down: true);
      final l = await images(net).look(pixel8);
      expect(l.name, 'Google Pixel 8');
      expect(l.file, isNull);
      net.down = false;
      net.files['Google Pixel 8'] = [file('Google Pixel 8 front.png')];
      expect((await images(net).look(pixel8)).file, isNotNull);
    },
  );

  test('no verified picture: generic fallback, remembered so we do not keep asking', () async {
    final net = Net({
      'Google Pixel 8': [
        file('Google Pixel 8 launch event.jpg'),
        file('Google Pixel 8 front.png', license: 'All rights reserved'),
      ],
    });
    final l = await images(net).look(pixel8);
    expect(l.file, isNull);
    expect(l.name, 'Google Pixel 8');
    final before = net.urls.length;
    await images(net).look(pixel8);
    expect(net.urls.length, before);
  });

  test(
    'name comes from the Play list when the phone has no marketing name',
    () async {
      final net = Net(
        {
          'Samsung Galaxy S24': [
            file('Samsung Galaxy S24 Ultra.jpg'),
            file('Samsung Galaxy S24 front.png'),
          ],
        },
        rows: [
          ['Samsung', 'Galaxy S24', 'e1s', 'SM-S921B'],
          ['Samsung', 'Galaxy S24 Ultra', 'e3q', 'SM-S928B'],
        ],
      );
      const s24 = PhoneId(
        manufacturer: 'samsung',
        brand: 'samsung',
        model: 'SM-S921B',
        device: 'e1s',
      );
      final l = await images(net).look(s24);
      expect(l.name, 'Samsung Galaxy S24');
      expect(l.file, isNotNull);
      expect(net.urls.any((u) => u.contains('Ultra.jpg')), isFalse);

      final redmi = Net(
        {
          'Redmi Redmi Note 13'.replaceFirst('Redmi ', ''): [
            file('Redmi Note 13.png'),
          ],
        },
        rows: [
          ['Redmi', 'Redmi Note 13', 'sapphire', '23129RA5FL'],
        ],
      );
      const note = PhoneId(
        manufacturer: 'Xiaomi',
        brand: 'Redmi',
        model: '23129RA5FL',
        device: 'sapphire',
      );
      expect((await images(redmi).look(note)).name, 'Redmi Note 13');
    },
  );

  test('a title is not enough: "series" descriptions and sibling categories are rejected', () async {
    final net = Net({
      'Samsung Galaxy S24': [
        file(
          'Samsung Galaxy S24 (webtekno) 001.png',
          desc: 'View of a model from the Samsung Galaxy S24 series.',
        ),
        file('Samsung Galaxy S24 back.png', cats: 'Samsung Galaxy S24 Ultra'),
        file(
          'Samsung Galaxy S24 01.jpg',
          mime: 'image/jpeg',
          cats: 'Samsung Galaxy S24',
        ),
      ],
    });
    const s24 = PhoneId(
      manufacturer: 'samsung',
      brand: 'samsung',
      model: 'SM-S921B',
      device: 'e1s',
      marketName: 'Galaxy S24',
    );
    final l = await images(net).look(s24);
    expect(l.file, isNotNull);
    expect(net.urls.any((u) => u.contains('S24%2001.jpg')), isTrue);
    expect(
      net.urls.where((u) => u.contains('webtekno') || u.contains('back')),
      isEmpty,
    );
  });

  test('titles without the maker or the 5G still match their model', () async {
    final net = Net({
      'moto g54 5G': [
        file(
          'Moto G54 5G.jpg',
          mime: 'image/jpeg',
          desc: 'Motorola smartphone',
        ),
      ],
    });
    const moto = PhoneId(
      manufacturer: 'motorola',
      brand: 'motorola',
      model: 'moto g54 5G',
      device: 'cancunf',
      marketName: 'moto g54 5G',
    );
    expect((await images(net).look(moto)).file, isNotNull);
  });

  test('a model code alone is never searched: unknown phones get the generic fallback', () async {
    final net = Net({
      'Foo ZX-1': [file('ZX-1.jpg', mime: 'image/jpeg')],
      'ZX-1': [file('ZX-1.jpg', mime: 'image/jpeg')],
    });
    const foo = PhoneId(
      manufacturer: 'Foo',
      brand: 'foo',
      model: 'ZX-1',
      device: 'zx1',
    );
    final l = await images(net).look(foo);
    expect(l.file, isNull);
    expect(l.name, 'Foo ZX-1');
    expect(net.urls.where((u) => u.contains('commons')), isEmpty);
  });

  test('the phone reports its identity and the charging power', () {
    final i = PeerInfo({
      'kind': 'phone',
      'manufacturer': 'Google',
      'brand': 'google',
      'model': 'Pixel 9a',
      'device': 'tegu',
      'battery': {'level': 75, 'charging': true, 'mw': 8996},
    });
    expect(i.phoneId.device, 'tegu');
    expect(i.chargeWattsLabel, '9,0 W');
    expect(i.withPower({'mw': 18250}).chargeWattsLabel, '18,3 W');
    expect(i.withPower({'mw': 0}).chargeWatts, isNull);
    expect(
      PeerInfo({
        'battery': {'level': 75, 'charging': false, 'mw': 5000},
      }).chargeWatts,
      isNull,
    );
    expect(
      PeerInfo({
        'battery': {'level': 75, 'charging': true},
      }).chargeWatts,
      isNull,
    ); // old phone
  });
}
