import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/phone_control.dart';

void main() {
  test(
    'the camera window shows a camera, without control or screen options',
    () {
      final a = scrcpyArgs(
        'S',
        'Cam',
        const SessionOptions(
          camera: 'front',
          audio: false,
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
}
