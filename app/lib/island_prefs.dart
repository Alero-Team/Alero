import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Settings of Alero Island, kept in `island.json` next to the other settings. The daemon (which draws the island)
/// watches the file and applies a change at once, so there is nothing to restart. Keys are the daemon's own.
class IslandPrefs extends ChangeNotifier {
  IslandPrefs(this.file) {
    _load();
  }

  final File file;

  static const modules = [
    'player',
    'send',
    'incoming',
    'notifications',
    'call',
    'clipboard',
    'controls',
    'status',
    'link',
  ];

  static const defaults = <String, Object>{
    'enabled': true,
    'monitor': -1,
    'hide_fullscreen': true,
    'zone_width': 220,
    'open_delay_ms': 120,
    'close_delay_ms': 450,
    'offset_x': 0,
    'hotkey': '',
    'scale': 100,
    'animation': 'normal',
    'respect_reduce_motion': true,
    'color': '#000000',
    'accent': '#FFFFFF',
    'auto_expand': true,
    'event_secs': 6,
    'sound': false,
    // Phone controls of the island, in order (the daemon's `controls`).
    'controls': 'dnd,torch,find,ringer,wifi,bt,rotate,lock',
  };

  final _values = <String, Object>{...defaults};
  final _mods = <String, bool>{for (final m in modules) m: true};
  Timer? _debounce;

  bool flag(String k) => _values[k] as bool;
  int number(String k) => (_values[k] as num).toInt();
  String text(String k) => _values[k] as String;
  bool module(String k) => _mods[k] ?? true;

  void _load() {
    try {
      final j = jsonDecode(file.readAsStringSync());
      if (j is! Map) return;
      defaults.forEach((k, d) {
        final v = j[k];
        if (v != null && v.runtimeType == d.runtimeType) {
          _values[k] = v as Object;
        } else if (v is num && d is int) {
          _values[k] = v.toInt();
        }
      });
      final m = j['modules'];
      if (m is Map) {
        for (final k in modules) {
          if (m[k] is bool) _mods[k] = m[k] as bool;
        }
      }
    } catch (_) {
      // No file yet, or unreadable: the defaults.
    }
  }

  void set(String key, Object value) {
    if (_values[key] == value) return;
    _values[key] = value;
    _changed();
  }

  void setModule(String key, bool on) {
    if (_mods[key] == on) return;
    _mods[key] = on;
    _changed();
  }

  void reset() {
    _values
      ..clear()
      ..addAll(defaults);
    _mods.updateAll((_, _) => true);
    _changed();
  }

  void _changed() {
    notifyListeners();
    // A slider drags through many values: write once it pauses.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), save);
  }

  Map<String, Object> toJson() => {..._values, 'modules': _mods};

  /// Written whole and renamed into place, so the daemon never reads half a file.
  void save() {
    try {
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(toJson()));
      tmp.renameSync(file.path);
    } catch (_) {
      // Read-only data directory: the island keeps its previous settings.
    }
  }

  @override
  void dispose() {
    if (_debounce?.isActive ?? false) save();
    _debounce?.cancel();
    super.dispose();
  }
}

/// "#RRGGBB" (the # is optional) in any case, or null.
String? normalizeHex(String s) {
  final t = s.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(t)) return null;
  return '#${t.toUpperCase()}';
}
