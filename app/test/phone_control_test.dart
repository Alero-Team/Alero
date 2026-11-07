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

  test(
    'camera window: no control, so no stay-awake (scrcpy rejects the pair)',
    () {
      final cam = scrcpyArgs(
        'S',
        't',
        const SessionOptions(camera: 'back', audio: false),
      );
      expect(
        cam,
        containsAll([
          '--video-source=camera',
          '--camera-facing=back',
          '--no-control',
          '--no-audio',
        ]),
      );
      expect(cam, isNot(contains('--stay-awake')));
      expect(
        scrcpyArgs('S', 't', const SessionOptions()),
        contains('--stay-awake'),
      );
    },
  );

  test('screen recording writes a file with no window and no control', () {
    final rec = scrcpyArgs(
      'S',
      't',
      const SessionOptions(record: r'C:\Alero\Grabacion.mkv'),
    );
    expect(
      rec,
      containsAll([
        r'--record=C:\Alero\Grabacion.mkv',
        '--no-window',
        '--no-control',
      ]),
    );
    // scrcpy exits at once with --stay-awake and --no-control together.
    expect(rec, isNot(contains('--stay-awake')));
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

  test('scrcpy camera failures are explained, not swallowed', () {
    expect(
      sessionError(['Server connection failed'], camera: true),
      contains('ocupada'),
    );
    expect(
      sessionError(['Camera disconnected'], camera: true),
      contains('ocupada'),
    );
    expect(sessionError(['Something else']), 'Something else');
    expect(sessionError([]), contains('error'));
  });

  test('camera frames are turned upright for the phone as it is held', () {
    // Pixel-like mounting: back sensor at 90, front at 270.
    expect(
      cameraTurn(90, 0, 'back'),
      90,
    ); // upright: the landscape sensor needs a quarter turn
    expect(cameraTurn(90, 90, 'back'), 0); // turned left: already level
    expect(
      cameraTurn(90, 270, 'back'),
      180,
    ); // turned right: upside down without correction
    expect(cameraTurn(270, 0, 'front'), 270);
    expect(cameraTurn(270, 90, 'front'), 0);
    expect(cameraTurn(270, 270, 'front'), 180);
  });

  test('screen rotation is read from the dumps Android versions print', () {
    expect(
      displayRotation('  mCurrentRotation=ROTATION_90 mLastOrientation=-1'),
      90,
    );
    expect(
      displayRotation('DisplayRotation{#0 mRotation=3 mDeferredRotation...'),
      270,
    );
    expect(displayRotation('    SurfaceOrientation: 2'), 180);
    expect(
      displayRotation(
        'Viewport INTERNAL: displayId=0, uniqueId=local:1, port=0, orientation=1, logicalFrame=[0, 0, 2424, 1080]',
      ),
      90,
    );
    expect(displayRotation(''), 0);
    expect(displayRotation('garbage'), 0);
  });

  test('sensor mounting comes from media.camera, with the usual fallback', () {
    const dump = """
== Camera HAL device device@1.1/internal/0 (v1.1) static information: ==
  Facing: BACK, Orientation: 90
== Camera HAL device device@1.1/internal/1 (v1.1) static information: ==
  Facing: FRONT, Orientation: 270
""";
    expect(sensorOrientation(dump, 'back'), 90);
    expect(sensorOrientation(dump, 'front'), 270);
    expect(
      sensorOrientation('Facing: Back\n    Orientation: 270', 'back'),
      270,
    );
    expect(sensorOrientation('', 'back'), 90);
    expect(sensorOrientation('', 'front'), 270);
  });

  test('a camera session rotates its window with --orientation', () {
    final args = scrcpyArgs(
      's',
      'Cámara',
      const SessionOptions(camera: 'back', orientation: 90),
    );
    expect(args, contains('--video-source=camera'));
    expect(args, contains('--orientation=90'));
  });
}
