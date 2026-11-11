import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/ui/home.dart';

void main() {
  test(
    'Home keeps the user order, hides what is off and never loses a new tile',
    () {
      const all = ['device', 'media', 'controls', 'notifs', 'recent'];
      expect(homeTiles(all, [], {}), all);
      expect(homeTiles(all, ['recent', 'device'], {'media'}), [
        'recent',
        'device',
        'controls',
        'notifs',
      ]);
      // A saved name this device does not have (the phone's "remote") is ignored, repeated ones count once.
      expect(
        homeTiles(all, ['remote', 'notifs', 'notifs'], {}).first,
        'notifs',
      );
      expect(homeTiles(all, [], all.toSet()), isEmpty);
    },
  );

  test('a wide Home puts the first three fifths of the tiles on the left', () {
    expect([for (var n = 1; n <= 6; n++) homeLeftCount(n)], [1, 2, 2, 3, 3, 4]);
  });
}
