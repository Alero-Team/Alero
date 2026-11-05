import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/vault.dart';

void main() {
  test('encrypted vault record model preserves a note without exposing metadata', () {
    final entry = VaultEntry(
      id: '0123456789abcdefghijklmN',
      name: 'Una nota privada',
      kind: 'note',
      data: 'Texto de prueba',
      created: DateTime.utc(2026, 11, 5),
    );
    final restored = VaultEntry.fromMap(entry.id, entry.toMap());
    expect(restored.name, entry.name);
    expect(restored.data, entry.data);
    expect(restored.isNote, isTrue);
    expect(restored.created, entry.created);
    expect(jsonEncode(entry.toMap()), contains('Una nota privada'));
    // The model is plaintext only in memory: the store must seal it before disk writes.
  });

  test('binary vault entry uses base64 only internally', () {
    final entry = VaultEntry(
      id: '0123456789abcdefghijklmN',
      name: 'imagen.png',
      kind: 'file',
      data: base64Encode([0, 1, 2, 253, 254, 255]),
      created: DateTime.utc(2026, 11, 5),
    );
    expect(entry.fileBytes, [0, 1, 2, 253, 254, 255]);
    expect(entry.isNote, isFalse);
  });

  test('unknown vault record types are rejected', () {
    expect(
      () => VaultEntry.fromMap('x', {
        'kind': 'untrusted',
        'name': 'secret',
        'data': 'foo',
        'created': '2026-11-05T00:00:00Z',
      }),
      throwsFormatException,
    );
  });
}
