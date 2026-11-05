import 'package:pb_app/phone_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adb devices -l: state, model and transport', () {
    final d = parseDevices('''List of devices attached
* daemon started successfully *
ABCD1234EFGH56         device product:tegu model:Pixel_9a device:tegu transport_id:3
192.0.2.29:41257     device product:tegu model:Pixel_9a device:tegu transport_id:4
R58M12ABCDE            unauthorized usb:1-1 transport_id:5
emulator-5554          offline

''');
    expect(d.map((x) => x.serial), [
      'ABCD1234EFGH56',
      '192.0.2.29:41257',
      'R58M12ABCDE',
      'emulator-5554',
    ]);
    expect(d[0].name, 'Pixel 9a');
    expect(d[0].ready && !d[0].wifi, isTrue);
    expect(d[1].wifi, isTrue);
    expect(d[2].unauthorized, isTrue);
    expect(d[2].name, 'R58M12ABCDE'); // no model before authorisation
    expect(d[3].ready, isFalse);
    expect(parseDevices('List of devices attached\n'), isEmpty);
  });

  test('camera window: no control, so no stay-awake (scrcpy rejects the pair)', () {
    final cam = scrcpyArgs('S', 't', const SessionOptions(camera: 'back', audio: false));
    expect(cam, containsAll(['--video-source=camera', '--camera-facing=back', '--no-control', '--no-audio']));
    expect(cam, isNot(contains('--stay-awake')));
    expect(scrcpyArgs('S', 't', const SessionOptions()), contains('--stay-awake'));
  });

  test('desktop mode only where Android really offers it', () {
    expect(
      desktopSupport(sdk: 37, freeform: true, forced: true),
      Desktop.ready,
    );
    expect(
      desktopSupport(sdk: 37, freeform: true, forced: false),
      Desktop.ready,
    );
    expect(
      desktopSupport(sdk: 35, freeform: true, forced: false),
      Desktop.needsSetting,
    );
    expect(
      desktopSupport(sdk: 37, freeform: false, forced: true),
      Desktop.unsupported,
    );
    expect(
      desktopSupport(sdk: 28, freeform: true, forced: true),
      Desktop.unsupported,
    );
  });

  test('scrcpy arguments follow the options', () {
    final normal = scrcpyArgs('S1', 'Pixel · Alero', const SessionOptions());
    expect(normal, containsAllInOrder(['-s', 'S1']));
    expect(normal, contains('--max-size=1600'));
    expect(normal, contains('--video-bit-rate=8M'));
    expect(normal.any((a) => a.startsWith('--new-display')), isFalse);

    final custom = scrcpyArgs(
      'S1',
      't',
      const SessionOptions(
        maxSize: 0,
        audio: false,
        fullscreen: true,
        orientation: 90,
        screenOff: true,
      ),
    );
    expect(custom.any((a) => a.startsWith('--max-size')), isFalse);
    expect(
      custom,
      containsAll([
        '--no-audio',
        '--fullscreen',
        '--orientation=90',
        '--turn-screen-off',
      ]),
    );

    // Desktop: a virtual display; the phone's own screen is left alone.
    final desk = scrcpyArgs(
      'S1',
      't',
      const SessionOptions(desktop: true, screenOff: true),
    );
    expect(desk, contains('--new-display=1920x1080'));
    expect(desk, isNot(contains('--turn-screen-off')));
  });
}
