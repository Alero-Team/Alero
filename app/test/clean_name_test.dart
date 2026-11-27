import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/native.dart';

void main() {
  test('provider names become names the Windows receiver accepts', () {
    expect(cleanName('image:1234'), 'image_1234');
    expect(cleanName('a<b>?.jpg'), 'a_b__.jpg');
    expect(cleanName('foto. '), 'foto');
    expect(cleanName('nota .'), 'nota');
    expect(cleanName('aux.txt'), '_aux.txt');
    expect(cleanName(' ... '), 'archivo');
    expect(cleanName('Viaje/día.jpg'), 'Viaje_día.jpg');
  });

  test('long names are cut by UTF-8 bytes and keep their extension', () {
    final n = cleanName('${'ñ' * 300}.mp4');
    expect(utf8.encode(n).length, lessThanOrEqualTo(200));
    expect(n.endsWith('.mp4'), isTrue);
  });
}
