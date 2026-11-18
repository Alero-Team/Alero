import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/ui/island_panel.dart';

void main() {
  const ctrl = LogicalKeyboardKey.controlLeft;
  const alt = LogicalKeyboardKey.altRight;
  const shift = LogicalKeyboardKey.shiftLeft;
  const win = LogicalKeyboardKey.metaLeft;

  test('modifiers and a key give the string the daemon parses', () {
    expect(hotkeyCombo(LogicalKeyboardKey.keyI, {ctrl, alt}), 'Ctrl+Alt+I');
    expect(hotkeyCombo(LogicalKeyboardKey.f9, {win, shift}), 'Shift+Win+F9');
    expect(hotkeyCombo(LogicalKeyboardKey.digit5, {ctrl}), 'Ctrl+5');
    expect(hotkeyCombo(LogicalKeyboardKey.space, {alt}), 'Alt+Space');
  });

  test('a bare key, a lone modifier or an unsupported key is refused', () {
    expect(hotkeyCombo(LogicalKeyboardKey.keyI, {}), isNull);
    expect(hotkeyCombo(LogicalKeyboardKey.controlLeft, {ctrl}), isNull);
    expect(hotkeyCombo(LogicalKeyboardKey.f13, {ctrl}), isNull);
    expect(hotkeyCombo(LogicalKeyboardKey.arrowUp, {ctrl}), isNull);
  });
}
