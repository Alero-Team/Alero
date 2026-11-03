import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/phone_control.dart';
import 'package:pb_app/scrcpy.dart';

void main() {
  test('an app window is a bare virtual display that starts the app', () {
    final a = scrcpyArgs(
      'S',
      'WhatsApp',
      const SessionOptions(appWindow: true, startApp: 'com.whatsapp'),
    );
    expect(
      a,
      containsAll([
        '--new-display',
        '--no-vd-system-decorations',
        '--start-app=com.whatsapp',
      ]),
    );
    expect(a.any((v) => v.startsWith('--new-display=')), isFalse);
    expect(a, isNot(contains('--turn-screen-off')));
  });

  test(
    'the camera window shows a camera, without control or screen options',
    () {
      final a = scrcpyArgs(
        'S',
        'Cam',
        const SessionOptions(
          camera: 'front',
          audio: false,
          desktop: true,
          screenOff: true,
        ),
      );
      expect(
        a,
        containsAll([
          '--video-source=camera',
          '--camera-facing=front',
          '--no-control',
          '--no-audio',
        ]),
      );
      expect(
        a.any((v) => v.startsWith('--new-display') || v == '--turn-screen-off'),
        isFalse,
      );
    },
  );

  test(
    'scrcpy --list-apps output becomes (name, package), system and user apps',
    () {
      const out = '''
[server] INFO: List of apps:
 * Chrome                         com.android.chrome
 - WhatsApp                       com.whatsapp
 - Mi App Con Espacios            org.example.app
 garbage line
''';
      expect(parseListApps(out), [
        ('Chrome', 'com.android.chrome'),
        ('Mi App Con Espacios', 'org.example.app'),
        ('WhatsApp', 'com.whatsapp'),
      ]);
    },
  );
}
