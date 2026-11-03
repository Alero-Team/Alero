import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/hub.dart';
import 'package:pb_app/native.dart';

void main() {
  test('a picked folder becomes its files named Folder/sub/file; files stay as they are', () {
    final tmp = Directory.systemTemp.createTempSync('alero-folder');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final root = Directory('${tmp.path}${Platform.pathSeparator}Viaje')
      ..createSync();
    File('${root.path}/a.txt').writeAsStringSync('a');
    Directory('${root.path}/día 1').createSync();
    File('${root.path}/día 1/b.jpg').writeAsStringSync('b');
    final loose = File('${tmp.path}/suelto.pdf')..writeAsStringSync('c');

    final out = Hub.expandFolders([
      Picked(root.path, null),
      Picked(loose.path, null),
    ]);
    expect(out.map((p) => p.name).toSet(), {
      'Viaje/a.txt',
      'Viaje/día 1/b.jpg',
      null,
    });
    expect(out.where((p) => p.name == null).single.path, loose.path);
  });
}
