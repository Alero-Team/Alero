import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/ui/media.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cover dimensions distinguish wide thumbnails from square covers',
    () async {
      for (final size in [(24, 12), (12, 24), (12, 12)]) {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder);
        final picture = recorder.endRecording();
        final image = await picture.toImage(size.$1, size.$2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        expect(
          await mediaAspectRatio(bytes!.buffer.asUint8List()),
          size.$1 / size.$2,
        );
      }
    },
  );

  test('invalid covers fail without retaining a decoded image', () async {
    await expectLater(
      mediaAspectRatio(Uint8List.fromList([1, 2, 3])),
      throwsException,
    );
  });
}
