import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/ui/remote_ui.dart';

void main() {
  test('typing at the end only adds', () {
    expect(typedChange('hol', 'hola'), (left: 0, back: 0, add: 'a'));
  });

  test('deleting at the end only backspaces', () {
    expect(typedChange('hola', 'ho'), (left: 0, back: 2, add: ''));
  });

  test('a fix in the middle touches only that part', () {
    // "hola mundo" -> "hola nundo" changes one letter: go left past "undo", replace "m".
    expect(typedChange('hola mundo', 'hola nundo'), (left: 4, back: 1, add: 'n'));
  });

  test('autocorrect of the last word replaces just the word', () {
    // Inserting a letter before the last one: one step left, type it, back to the end.
    expect(typedChange('esto es qe', 'esto es que'), (left: 1, back: 0, add: 'u'));
    expect(typedChange('vi un gto', 'vi un gato'), (left: 2, back: 0, add: 'a'));
  });

  test('an emoji is one character', () {
    expect(typedChange('ok 👍🏽', 'ok '), (left: 0, back: 1, add: ''));
  });

  test('no change sends nothing (switching the phone keyboard)', () {
    expect(typedChange('igual', 'igual'), (left: 0, back: 0, add: ''));
  });
}
