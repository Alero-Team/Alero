import 'dart:convert';

/// Ideas adapted from the Dextop workspace, app-catalog and capability design.
/// No privileged Android APIs are required for these data models.
/// Alero invokes Android's public adb/scrcpy commands after user authorization.
final _packagePattern = RegExp(
  r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$',
);

bool validAndroidPackage(String value) => _packagePattern.hasMatch(value);

class DesktopDisplay {
  const DesktopDisplay(this.id, this.description);
  final int id;
  final String description;

  (int, int)? get resolution {
    final m = RegExp(r'(\d+)x(\d+)').firstMatch(description);
    final w = int.tryParse(m?.group(1) ?? '');
    final h = int.tryParse(m?.group(2) ?? '');
    return w != null && h != null && w > 0 && h > 0 ? (w, h) : null;
  }

  static List<DesktopDisplay> parse(String output) {
    final ids = <int, DesktopDisplay>{};
    for (final line in output.split('\n')) {
      final match = RegExp(r'--display-id=(\d+)').firstMatch(line);
      if (match == null) continue;
      final id = int.tryParse(match.group(1)!);
      if (id == null) continue;
      ids[id] = DesktopDisplay(id, line.trim());
    }
    return ids.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }
}

class DesktopApps {
  /// ADB package manager exposes package IDs without requiring an extra permission.
  static List<String> parse(String output) {
    final values = <String>{};
    for (final line in output.split('\n')) {
      final package = line.trim().replaceFirst(RegExp(r'^package:'), '');
      if (validAndroidPackage(package)) values.add(package);
    }
    return values.toList()..sort();
  }
}

/// Dextop-inspired layout presets. Exact native window bounds require vendor
/// freeform capabilities; they are never promised by the ADB fallback.
enum DesktopLayout { floating, halves, thirds, quarters }

class DesktopWorkspace {
  const DesktopWorkspace({
    required this.name,
    required this.packages,
    this.layout = DesktopLayout.floating,
    this.displayId = 0,
  });

  final String name;
  final List<String> packages;
  final DesktopLayout layout;
  final int displayId;

  Map<String, Object> toJson() => {
    'name': name,
    'packages': packages,
    'layout': layout.name,
    'displayId': displayId,
  };

  factory DesktopWorkspace.fromJson(Map<String, dynamic> value) {
    final name = value['name'] is String
        ? (value['name'] as String).trim()
        : '';
    final raw = value['packages'];
    final packages = raw is List
        ? raw.whereType<String>().where(validAndroidPackage).toSet().toList()
        : <String>[];
    final layout =
        DesktopLayout.values
            .where((v) => v.name == value['layout'])
            .firstOrNull ??
        DesktopLayout.floating;
    final displayId = value['displayId'] is int ? value['displayId'] as int : 0;
    if (name.isEmpty ||
        name.length > 72 ||
        packages.isEmpty ||
        packages.length > 12 ||
        displayId < 0 ||
        displayId > 255) {
      throw const FormatException('Espacio de trabajo inválido');
    }
    return DesktopWorkspace(
      name: name,
      packages: packages,
      layout: layout,
      displayId: displayId,
    );
  }

  static String exportAll(List<DesktopWorkspace> workspaces) =>
      const JsonEncoder.withIndent('  ').convert({
        'schema': 1,
        'workspaces': workspaces.map((w) => w.toJson()).toList(),
      });

  static List<DesktopWorkspace> importAll(String json) {
    final data = jsonDecode(json);
    if (data is! Map || data['schema'] != 1 || data['workspaces'] is! List) {
      throw const FormatException('Formato de espacios no compatible');
    }
    final values = data['workspaces'] as List;
    if (values.length > 32) throw const FormatException('Demasiados espacios');
    return values.map((e) {
      if (e is! Map) throw const FormatException('Espacio inválido');
      return DesktopWorkspace.fromJson(Map<String, dynamic>.from(e));
    }).toList();
  }
}

/// Window geometry follows the rectangular layout patterns in Dextop's
/// WorkspaceLayoutEngine. Only the optional ADB fallback applies bounds:
/// OEMs may reject it or enforce minimum window dimensions.
class DesktopWindowBounds {
  const DesktopWindowBounds(this.left, this.top, this.right, this.bottom);
  final int left, top, right, bottom;
}

List<DesktopWindowBounds> desktopWindowBounds(
  DesktopLayout layout,
  int width,
  int height,
  int count,
) {
  if (width < 400 ||
      height < 400 ||
      count < 1 ||
      count > 4 ||
      layout == DesktopLayout.floating) {
    return [];
  }
  final cx = width ~/ 2, cy = height ~/ 2, third = width ~/ 3;
  if (count == 1) {
    return [DesktopWindowBounds(0, 0, width, height)];
  }
  if (layout == DesktopLayout.halves || count == 2) {
    return [
      DesktopWindowBounds(0, 0, cx, height),
      DesktopWindowBounds(cx, 0, width, height),
    ];
  }
  if (layout == DesktopLayout.thirds && count == 3) {
    return [
      DesktopWindowBounds(0, 0, third, height),
      DesktopWindowBounds(third, 0, third * 2, height),
      DesktopWindowBounds(third * 2, 0, width, height),
    ];
  }
  if (layout == DesktopLayout.quarters && count >= 3) {
    final cells = [
      DesktopWindowBounds(0, 0, cx, cy),
      DesktopWindowBounds(cx, 0, width, cy),
      DesktopWindowBounds(0, cy, cx, height),
      DesktopWindowBounds(cx, cy, width, height),
    ];
    return cells.take(count).toList();
  }
  return [];
}

/// One visible task from `dumpsys activity top`. AOSP prints
/// `TASK <uid:affinity> id=N userId=U displayId=D(type=…)` and then
/// `ACTIVITY <package>/<class> …`; only visible root tasks are listed.
class TopTask {
  const TopTask(this.package, this.id, this.display);
  final String package;
  final int id, display;
}

final _taskLine = RegExp(
  r'^\s*TASK (?:\d+:)?(\S+) id=(\d+)\s+userId=\d+\s+displayId=(\d+)',
);
final _activityLine = RegExp(r'^\s*ACTIVITY ([A-Za-z0-9_.]+)/');

/// The package comes from the task's first ACTIVITY line (its affinity can be
/// anything an app declares), falling back to the affinity.
List<TopTask> parseTopTasks(String dump) {
  final tasks = <TopTask>[];
  var named = true;
  for (final line in dump.split('\n')) {
    final t = _taskLine.firstMatch(line);
    if (t != null) {
      final id = int.tryParse(t[2]!), display = int.tryParse(t[3]!);
      named = true;
      if (id != null && id > 0 && id < 100000000 && display != null) {
        tasks.add(TopTask(t[1]!, id, display));
        named = false;
      }
      continue;
    }
    final a = _activityLine.firstMatch(line);
    if (a != null && !named) {
      final last = tasks.removeLast();
      tasks.add(TopTask(a[1]!, last.id, last.display));
      named = true;
    }
  }
  return tasks.where((t) => validAndroidPackage(t.package)).toList();
}

/// Task IDs on one display. Never resize a task unless package and display match.
Map<String, int> parseDesktopTasks(String dump, int displayId) => {
  for (final t in parseTopTasks(dump))
    if (t.display == displayId) t.package: t.id,
};

/// Where Android actually put an app after a launch aimed at a virtual display.
enum DesktopLaunch {
  /// Only on the virtual display.
  desktop,

  /// Android moved the window the phone was showing (one instance per app).
  movedFromPhone,

  /// On the virtual display, and a new window also appeared on the phone.
  alsoOnPhone,

  /// Android sent it to the phone screen instead.
  phone,

  /// Android did not show it anywhere visible (yet).
  unconfirmed,
}

/// Compares the visible tasks before and after `am start`. Display 0 is the
/// phone's own screen.
DesktopLaunch judgeDesktopLaunch(
  String package,
  int displayId,
  List<TopTask> before,
  List<TopTask> after, {
  String amOutput = '',
}) {
  final phoneBefore = {
    for (final t in before)
      if (t.package == package && t.display == 0) t.id,
  };
  final mine = after.where((t) => t.package == package).toList();
  final onDesk = mine.where((t) => t.display == displayId).toList();
  final onPhone = mine.where((t) => t.display == 0).toList();
  final newOnPhone = onPhone.any((t) => !phoneBefore.contains(t.id));
  if (onDesk.isEmpty) {
    final broughtUp =
        onPhone.isNotEmpty && amOutput.contains('brought to the front');
    return newOnPhone || broughtUp
        ? DesktopLaunch.phone
        : DesktopLaunch.unconfirmed;
  }
  if (newOnPhone) return DesktopLaunch.alsoOnPhone;
  if (onDesk.any((t) => phoneBefore.contains(t.id))) {
    return DesktopLaunch.movedFromPhone;
  }
  return DesktopLaunch.desktop;
}

/// `dumpsys display` lists each logical display as `mDisplayId=N`. Null when
/// the dump has no such lines (unknown format): callers then ask scrcpy.
bool? displayListed(String dump, int displayId) {
  final ids = RegExp(
    r'^\s*mDisplayId=(\d+)\s*$',
    multiLine: true,
  ).allMatches(dump).map((m) => int.parse(m[1]!)).toSet();
  return ids.isEmpty ? null : ids.contains(displayId);
}

class DesktopDiagnostics {
  const DesktopDiagnostics({
    this.batteryPercent,
    this.temperatureC,
    this.availableMemoryMb,
    this.totalMemoryMb,
  });

  final int? batteryPercent;
  final double? temperatureC;
  final int? availableMemoryMb;
  final int? totalMemoryMb;

  static DesktopDiagnostics parse(String battery, String meminfo) {
    int? matchedInt(String pattern, String source) {
      final m = RegExp(
        pattern,
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(source);
      return m == null ? null : int.tryParse(m.group(1)!);
    }

    final level = matchedInt(r'^\s*level:\s*(\d+)', battery);
    final temp = matchedInt(r'^\s*temperature:\s*(\d+)', battery);
    final total = matchedInt(r'^MemTotal:\s*(\d+)', meminfo);
    final available = matchedInt(r'^MemAvailable:\s*(\d+)', meminfo);
    return DesktopDiagnostics(
      batteryPercent: level != null && level <= 100 ? level : null,
      temperatureC: temp == null ? null : temp / 10,
      totalMemoryMb: total == null ? null : total ~/ 1024,
      availableMemoryMb: available == null ? null : available ~/ 1024,
    );
  }
}
