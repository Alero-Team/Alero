import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/ui/present.dart';

void main() {
  group('Alero Present shortcuts', () {
    test('PowerPoint can start a slideshow with F5', () {
      final shortcut = presentationShortcut(
        PresentationMode.powerpoint,
        PresentationAction.start,
      );
      expect(shortcut?.key, 'f5');
      expect(shortcut?.mods, isEmpty);
    });

    test('browser mode never refreshes the active presentation', () {
      expect(
        presentationShortcut(
          PresentationMode.browser,
          PresentationAction.start,
        ),
        isNull,
      );
    });

    for (final mode in PresentationMode.values) {
      test('$mode uses navigation and Escape', () {
        expect(
          presentationShortcut(mode, PresentationAction.next)?.key,
          'right',
        );
        expect(
          presentationShortcut(mode, PresentationAction.previous)?.key,
          'left',
        );
        expect(
          presentationShortcut(mode, PresentationAction.finish)?.key,
          'esc',
        );
      });
    }
  });
}
