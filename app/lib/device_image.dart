import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'app_info.dart';

/// Names a phone and finds its picture. Everything here is optional decoration: it never throws, never blocks the
/// connection, and works offline from the cache. Sources (both documented, no scraping):
///  - name: the `Build.*` fields the phone sends; if it has no marketing name, Google's public "Supported devices"
///    list (Retail Branding, Marketing Name, Device, Model) maps device+model to one.
///  - picture: Wikimedia Commons search API; only freely licensed files whose title names this exact model.
/// A file `<key>.png|jpg|webp` dropped in the cache folder wins over both (e.g. an official render).

/// What the phone reports (`ro.product.*` through `android.os.Build`).
class PhoneId {
  const PhoneId({
    this.manufacturer = '',
    this.brand = '',
    this.model = '',
    this.device = '',
    this.product = '',
    this.marketName = '',
  });
  final String manufacturer, brand, model, device, product, marketName;

  /// Stable file-safe identity: two different variants (device/model) never share a cache entry.
  String get key => _slug('$manufacturer $device $model');

  /// Best name without asking anyone: the phone's own marketing name, else its model code.
  String get localName => _compose(
    _cap(manufacturer.isEmpty ? brand : manufacturer),
    marketName.isNotEmpty ? marketName : model,
  );
}

class DeviceLook {
  const DeviceLook(this.name, {this.file, this.credit = ''});
  final String name;

  /// null: no verified picture for this exact model (the UI draws its generic phone).
  final File? file;

  /// Author and license of [file], shown next to it as the license requires.
  final String credit;
}

typedef Fetch = Future<Uint8List> Function(Uri url);

// Wikimedia asks API clients to identify themselves.
final _ua =
    'Alero/$aleroVersion (https://github.com/Alero-Team/Alero; device pictures)';
const _maxBytes = 8 << 20;
const _maxFiles = 60;
const _retryNone = Duration(days: 14);
final _csvUrl = Uri.parse(
  'https://storage.googleapis.com/play_public/supported_devices.csv',
);

Future<Uint8List> httpFetch(Uri url) async {
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..userAgent = _ua;
  try {
    final r = await (await c.getUrl(url))
        .close()
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}');
    final out = BytesBuilder(copy: false);
    await for (final chunk in r) {
      out.add(chunk);
      if (out.length > _maxBytes) throw const HttpException('too large');
    }
    return out.takeBytes();
  } finally {
    c.close(force: true);
  }
}

class DeviceImages {
  DeviceImages(this._dir, {this._fetch = httpFetch, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final Future<Directory> Function() _dir;
  final Fetch _fetch;
  final DateTime Function() _now;
  Map<String, Map<String, Object?>>? _index;
  final _pending = <String, Future<DeviceLook>>{};

  /// Cache first (instant, offline); the network only fills what is missing.
  Future<DeviceLook> look(PhoneId id) =>
      _pending.putIfAbsent(id.key, () => _look(id)).whenComplete(() {
        _pending.remove(id.key);
      });

  Future<DeviceLook> _look(PhoneId id) async {
    try {
      final dir = await _dir();
      final index = _index ??= await _load(dir);
      final e = index[id.key];
      final hit = _cached(dir, id.key);
      if (hit != null) {
        return DeviceLook(
          (e?['name'] as String?) ?? id.localName,
          file: hit,
          credit: (e?['credit'] as String?) ?? '',
        );
      }
      if (e != null && e['file'] == null) {
        final at = DateTime.fromMillisecondsSinceEpoch(
          (e['at'] as num?)?.toInt() ?? 0,
        );
        if (_now().difference(at) < _retryNone) {
          return DeviceLook((e['name'] as String?) ?? id.localName);
        }
      }
      final (name, resolved) = await resolveName(id);
      // A model code ("ZX-1", "SM-S921B") is not a name: searching for it finds unrelated things.
      if (!resolved) return DeviceLook(name);
      final found = await _search(name, id);
      if (found == null) {
        // Search worked but nothing verifiable exists: remember it, so we do not ask again for two weeks.
        await _save(dir, id.key, {'name': name});
        return DeviceLook(name);
      }
      final file = File('${dir.path}/${id.key}.${found.ext}');
      await file.writeAsBytes(found.bytes, flush: true);
      await _save(dir, id.key, {
        'name': name,
        'file': file.uri.pathSegments.last,
        'credit': found.credit,
      });
      await _prune(dir);
      return DeviceLook(name, file: file, credit: found.credit);
    } catch (_) {
      return DeviceLook(id.localName);
    }
  }

  File? _cached(Directory dir, String key) {
    for (final ext in const ['png', 'webp', 'jpg']) {
      final f = File('${dir.path}/$key.$ext');
      if (f.existsSync()) return f;
    }
    return null;
  }

  /// Marketing name: the phone's own, else Google's list; `false` means only the model code is known.
  Future<(String, bool)> resolveName(PhoneId id) async {
    if (id.marketName.isNotEmpty) return (id.localName, true);
    try {
      final csv = await _fetch(_csvUrl);
      final row = await Isolate.run(
        () => lookupSupported(csv, id.device, id.model),
      );
      if (row != null) return (_compose(row.$1, row.$2), true);
    } catch (_) {
      // offline: the model code still names the phone
    }
    return (id.localName, false);
  }

  /// Commons titles often drop the maker ("Moto G54 5G") or the "5G"; try the plainer names too.
  Future<_Found?> _search(String name, PhoneId id) async {
    final brand = nameTokens(
      id.manufacturer.isEmpty ? id.brand : id.manufacturer,
    ).firstOrNull;
    final brands = {
      for (final b in [id.manufacturer, id.brand, name.split(' ').first])
        ...nameTokens(b).take(1),
    };
    final names = {
      name,
      if (brand != null) _dropBrand(name, brand),
    }.where((n) => n.isNotEmpty);
    final wanted = {
      for (final n in names) ...[n, _stripConnectivity(n)],
    }.map(nameTokens).where((t) => t.length >= 2).toList();
    for (final q in names) {
      final found = await _searchCommons(q, wanted, brands);
      if (found != null) return found;
    }
    return null;
  }

  Future<_Found?> _searchCommons(
    String name,
    List<List<String>> wanted,
    Set<String> brands,
  ) async {
    final body = await _fetch(
      Uri.https('commons.wikimedia.org', '/w/api.php', {
        'action': 'query',
        'format': 'json',
        'formatversion': '2',
        'generator': 'search',
        'gsrnamespace': '6',
        'gsrlimit': '20',
        'gsrsearch': name,
        'prop': 'imageinfo',
        'iiprop': 'url|mime|size|extmetadata',
        'iiurlwidth': '480',
      }),
    );
    final pages =
        ((jsonDecode(utf8.decode(body)) as Map)['query'] as Map?)?['pages']
            as List? ??
        const [];
    final ranked = <(int, _Cand)>[];
    for (final p in pages) {
      final c = _Cand.from(p, wanted, brands);
      if (c != null) ranked.add((p['index'] as int? ?? 99, c));
    }
    ranked.sort((a, b) {
      final s = b.$2.score.compareTo(a.$2.score);
      return s != 0 ? s : a.$1.compareTo(b.$1);
    });
    for (final (_, c) in ranked.take(3)) {
      final bytes = await _fetch(
        Uri.parse(c.thumb),
      ); // a network error leaves the cache untouched
      if (bytes.length > 512) {
        return _Found(
          bytes,
          c.thumb.contains('.png') ? 'png' : 'jpg',
          c.credit,
        );
      }
    }
    return null;
  }

  Future<Map<String, Map<String, Object?>>> _load(Directory dir) async {
    try {
      final j = jsonDecode(await File('${dir.path}/index.json').readAsString());
      return {
        for (final e in (j as Map).entries)
          e.key as String: Map<String, Object?>.from(e.value as Map),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Directory dir, String key, Map<String, Object?> e) async {
    final index = _index ??= {};
    index[key] = {...e, 'at': _now().millisecondsSinceEpoch};
    await File('${dir.path}/index.json').writeAsString(jsonEncode(index));
  }

  /// Oldest pictures go first, so the folder never grows without bound.
  Future<void> _prune(Directory dir) async {
    final files = [
      for (final f in dir.listSync().whereType<File>())
        if (!f.path.endsWith('index.json')) f,
    ]..sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    for (final f in files.take(math.max(0, files.length - _maxFiles))) {
      f.deleteSync();
      _index?.removeWhere((_, v) => v['file'] == f.uri.pathSegments.last);
    }
  }
}

class _Found {
  _Found(this.bytes, this.ext, this.credit);
  final Uint8List bytes;
  final String ext, credit;
}

/// One Commons file that passed every check: free license, this exact model, looks like a phone picture.
class _Cand {
  _Cand(this.thumb, this.score, this.credit);
  final String thumb, credit;
  final int score;

  static _Cand? from(
    Object? page,
    List<List<String>> wanted,
    Set<String> brands,
  ) {
    if (page is! Map) return null;
    final title = page['title'] as String? ?? '';
    final info = (page['imageinfo'] as List?)?.firstOrNull;
    if (info is! Map) return null;
    final meta = info['extmetadata'] as Map? ?? const {};
    String m(String k) => ((meta[k] as Map?)?['value'] as String? ?? '')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
    final license = m('LicenseShortName');
    if (!RegExp(
      r'^(CC0|CC[ -]BY|Public domain|PD|GFDL)',
      caseSensitive: false,
    ).hasMatch(license)) {
      return null;
    }
    final tokens = titleTokens(title);
    if (tokens.any(_notAPhonePicture.contains)) return null;
    final hit = wanted.where((w) => matchesModel(tokens, w)).firstOrNull;
    if (hit == null) return null;
    // Some word of the maker must appear in the title, description or categories ("ZX-1.jpg" alone could be anything).
    final evidence = nameTokens(
      '$title ${m('ImageDescription')} ${m('Categories')}',
    );
    if (!brands.any(evidence.contains)) return null;
    // The title can lie: a file named "Galaxy S24" whose description says "series" or whose categories say
    // "Galaxy S24 Ultra" is not known to show this model.
    if (nameTokens(m('ImageDescription')).contains('series')) return null;
    for (final c in m('Categories').split('|')) {
      final ct = nameTokens(c);
      if (wanted.any((w) => _containsSeq(ct, w)) &&
          !wanted.any((w) => matchesModel(ct, w))) {
        return null;
      }
    }
    final mime = info['mime'] as String? ?? '';
    final thumb = info['thumburl'] as String? ?? '';
    if (!thumb.startsWith('https://') || !mime.startsWith('image/')) {
      return null;
    }
    final w = (info['width'] as num?)?.toInt() ?? 0;
    final h = (info['height'] as num?)?.toInt() ?? 0;
    final svg = mime == 'image/svg+xml';
    // Transparent formats first, then portrait views, then explicit front views; short titles are plainer.
    final score =
        (svg || mime == 'image/png' ? 4 : 0) +
        (h > w ? 2 : 0) +
        (tokens.contains('front') ? 1 : 0) -
        tokens.length ~/ 6;
    final author = m('Artist');
    return _Cand(
      thumb,
      score,
      [
        if (author.isNotEmpty) author,
        if (license.isNotEmpty) license,
        'Wikimedia Commons',
      ].join(' · '),
    );
  }
}

/// Words that mean the file is about something else than the phone itself.
const _notAPhonePicture = {
  'event',
  'launch',
  'unboxing',
  'screenshot',
  'screenshots',
  'logo',
  'charger',
  'case',
  'camera',
  'cameras',
  'keynote',
  'advertisement',
  'store',
  'comparison',
  'vs',
  'box',
  'repair',
  'teardown',
};

/// Next word that would turn "Pixel 9" into another phone ("Pixel 9 Pro"); a number (not a "01" file index) could be another year's model.
const _variants = {
  'pro',
  'plus',
  'ultra',
  'max',
  'mini',
  'lite',
  'fe',
  'fold',
  'flip',
  'xl',
  'edge',
  'neo',
  'prime',
  'power',
  'play',
  'turbo',
  'gt',
  'se',
  'note',
  'go',
  'active',
};

List<String> nameTokens(String s) =>
    RegExp(r'[a-z0-9]+')
        .allMatches(s.toLowerCase().replaceAll('+', ' plus '))
        .map((m) => m[0]!)
        .toList();

List<String> titleTokens(String title) => nameTokens(
  title
      .replaceFirst(RegExp(r'^File:', caseSensitive: false), '')
      .replaceFirst(RegExp(r'\.\w{2,4}$'), ''),
);

bool _containsSeq(List<String> t, List<String> n) {
  for (var i = 0; i + n.length <= t.length; i++) {
    if (Iterable<int>.generate(n.length).every((j) => t[i + j] == n[j])) {
      return true;
    }
  }
  return false;
}

/// The model's words must appear in a row in the title and the next word may not name a different variant.
bool matchesModel(List<String> title, List<String> name) {
  for (var i = 0; i + name.length <= title.length; i++) {
    var ok = true;
    for (var j = 0; j < name.length && ok; j++) {
      ok = title[i + j] == name[j];
    }
    if (!ok) continue;
    final next = i + name.length < title.length ? title[i + name.length] : '';
    if (next.isEmpty ||
        !(_variants.contains(next) || RegExp(r'^[1-9]\d*$').hasMatch(next))) {
      return true;
    }
  }
  return false;
}

String _dropBrand(String name, String brand) {
  final t = name.split(RegExp(r'\s+'));
  return t.length > 1 && nameTokens(t.first).firstOrNull == brand
      ? t.skip(1).join(' ')
      : name;
}

String _stripConnectivity(String s) =>
    s.replaceFirst(RegExp(r'\s+(5g|4g|lte|nfc)$', caseSensitive: false), '');

/// Google's list is UTF-16LE with four quoted columns. Returns (Retail Branding, Marketing Name), or null unless
/// the device+model pair is in it (or every row of that device agrees on one name).
(String, String)? lookupSupported(Uint8List csv, String device, String model) {
  final start = csv.length > 1 && csv[0] == 0xFF && csv[1] == 0xFE ? 2 : 0;
  final units = Uint16List.view(
    Uint8List.fromList(csv.sublist(start)).buffer,
    0,
    (csv.length - start) ~/ 2,
  );
  final byDevice = <(String, String)>{};
  for (final line in String.fromCharCodes(units).split('\n')) {
    final f = RegExp(r'"((?:[^"]|"")*)"')
        .allMatches(line)
        .map((m) => m[1]!.replaceAll('""', '"'))
        .toList();
    if (f.length != 4 || f[1].isEmpty) continue;
    if (f[2].toLowerCase() != device.toLowerCase()) continue;
    if (f[3].toLowerCase() == model.toLowerCase()) return (f[0], f[1]);
    byDevice.add((f[0], f[1]));
  }
  return byDevice.length == 1 ? byDevice.first : null;
}

String _compose(String branding, String marketing) {
  final m = marketing.trim();
  if (m.isEmpty) return branding.trim();
  final b = branding.trim();
  return b.isEmpty || m.toLowerCase().startsWith(b.toLowerCase()) ? m : '$b $m';
}

String _cap(String s) => s.isNotEmpty && s == s.toLowerCase()
    ? s[0].toUpperCase() + s.substring(1)
    : s;

String _slug(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-|-$'), '');
