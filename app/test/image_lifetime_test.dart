import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/ui/expressive.dart';

void main() {
  testWidgets('phone preview releases replaced, cleared and detached images', (
    tester,
  ) async {
    final bytes = File('android/app/src/main/res/mipmap-mdpi/ic_launcher.png')
        .readAsBytesSync();
    final key = GlobalKey();
    ui.Image? drawnImage() {
      final finder = find.descendant(
        of: find.byType(PhoneMockup),
        matching: find.byType(CustomPaint),
      );
      if (finder.evaluate().isEmpty) return null;
      return (tester.widget<CustomPaint>(finder).painter as dynamic).image
          as ui.Image?;
    }

    Future<void> show(Uint8List? data) async {
      final previous = drawnImage();
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneMockup(key: key, wallpaper: data),
        ),
      );
      // ImageDescriptor and getNextFrame each finish outside the test's fake clock.
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (data == null ? drawnImage() == null : drawnImage() != previous) {
          return;
        }
      }
      fail('Preview did not finish decoding');
    }

    await show(bytes);
    final first = drawnImage()!;
    await show(bytes.sublist(0));
    expect(first.debugDisposed, isTrue);
    final second = drawnImage()!;
    await show(null);
    expect(second.debugDisposed, isTrue);
    await show(bytes);
    final third = drawnImage()!;
    await tester.pumpWidget(const SizedBox());
    expect(third.debugDisposed, isTrue);
  });
}
