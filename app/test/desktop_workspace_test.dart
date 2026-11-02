import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/desktop_workspace.dart';
import 'package:pb_app/phone_control.dart';

void main() {
  test('Dextop-inspired displays enumerate only real Android display IDs', () {
    final d = DesktopDisplay.parse(
      'List of displays:\n --display-id=2 (1920x1080)\n --display-id=0 (1080x2400)\n',
    );
    expect(d.map((v) => v.id), [0, 2]);
    expect(DesktopDisplay.parse('no displays'), isEmpty);
  });

  test('catalog ignores invalid packages and does not duplicate entries', () {
    expect(DesktopApps.parse(
      'package:com.example.alpha\npackage:org.mozilla.firefox\n'
      'package:org.mozilla.firefox\nerror\n',
    ), ['com.example.alpha', 'org.mozilla.firefox']);
    expect(validAndroidPackage('evil; rm -rf /'), isFalse);
  });

  test('workspaces survive JSON import and reject malformed input', () {
    const p = DesktopWorkspace(
      name: 'Estudio',
      packages: ['org.mozilla.firefox', 'com.example.notes'],
      layout: DesktopLayout.halves,
      displayId: 2,
    );
    final json = DesktopWorkspace.exportAll([p]);
    final restored = DesktopWorkspace.importAll(json);
    expect(restored.single.name, 'Estudio');
    expect(restored.single.layout, DesktopLayout.halves);
    expect(restored.single.displayId, 2);
    expect(restored.single.packages, ['org.mozilla.firefox', 'com.example.notes']);
    expect(() => DesktopWorkspace.importAll('{"schema":2}'), throwsFormatException);
    expect(() => DesktopWorkspace.fromJson({
      'name': 'X', 'packages': ['bad;ls']
    }), throwsFormatException);
  });

  test('diagnostics extract real battery, thermal and memory readings', () {
    final s = DesktopDiagnostics.parse(
      'level: 87\ntemperature: 317\n',
      'MemTotal:       8064000 kB\nMemAvailable:   4024000 kB\n',
    );
    expect(s.batteryPercent, 87);
    expect(s.temperatureC, 31.7);
    expect(s.totalMemoryMb, 7875);
    expect(s.availableMemoryMb, 3929);
    expect(DesktopDiagnostics.parse('', '').batteryPercent, isNull);
  });

  test('freeform geometry and task probe refuse unrelated displays', () {
    final bounds = desktopWindowBounds(DesktopLayout.quarters, 1920, 1080, 4);
    expect(bounds, hasLength(4));
    expect([bounds[0].left, bounds[0].top, bounds[0].right, bounds[0].bottom],
      [0, 0, 960, 540]);
    expect(desktopWindowBounds(DesktopLayout.thirds, 1920, 1080, 3),
      hasLength(3));
    expect(desktopWindowBounds(DesktopLayout.floating, 1920, 1080, 3),
      isEmpty);
    expect(desktopWindowBounds(DesktopLayout.quarters, 1920, 1080, 5),
      isEmpty);

    final taskDump = 'TASK 10174:com.example.a id=63 userId=0 displayId=2(type=VIRTUAL)\n'
      'TASK 10174:com.example.b id=64 userId=0 displayId=0(type=INTERNAL)\n';
    final selected = parseDesktopTasks(taskDump, 2);
    expect(selected['com.example.a'], 63);
    expect(selected.containsKey('com.example.b'), isFalse);
    expect(const DesktopDisplay(2, 'External (1920x1080)').resolution,
      (1920, 1080));
  });

  test('independent desktop launches must never target display zero', () {
    expect(desktopAppLaunchArgs('org.mozilla.firefox', 2),
      containsAllInOrder(['--display','2','-f','0x18000000']));
    expect(() => desktopAppLaunchArgs('org.mozilla.firefox', 0), throwsFormatException);
    expect(desktopHomeLaunchArgs(2), contains('dev.alero.app/.DesktopHomeActivity'));
    expect(() => desktopHomeLaunchArgs(0), throwsFormatException);
    expect(desktopLaunchRejected('Permission Denial'), isTrue);
  });

  test('scrcpy can start supported virtual desktops and select real screens', () {
    final virtual = scrcpyArgs('ABC', 'Alero',
      const SessionOptions(desktop: true, desktopSize: '2560x1440',
        flexDisplay: true, startApp: 'org.mozilla.firefox'));
    expect(virtual, contains('--new-display=2560x1440'));
    expect(virtual, contains('--flex-display'));
    expect(virtual, contains('--keep-active'));
    expect(virtual, contains('--display-ime-policy=local'));
    expect(virtual, contains('--start-app=org.mozilla.firefox'));
    expect(virtual.any((v) => v.startsWith('--display-id=')), isFalse);

    final physical = scrcpyArgs('ABC', 'Alero',
      const SessionOptions(displayId: 2));
    expect(physical, contains('--display-id=2'));
    expect(physical.any((v) => v.startsWith('--new-display=')), isFalse);
  });
}
