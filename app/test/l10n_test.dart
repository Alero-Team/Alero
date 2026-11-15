import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/l10n.dart';
import 'package:pb_app/l10n_en.dart';

final _slot = RegExp(r'\{(\d*)\}');

/// How many arguments a template takes: the number of `{}` or the highest `{n}` + 1.
int _slots(String s) {
  var plain = 0, highest = -1;
  for (final m in _slot.allMatches(s)) {
    if (m[1]!.isEmpty) {
      plain++;
    } else {
      final i = int.parse(m[1]!);
      if (i > highest) highest = i;
    }
  }
  return plain > highest + 1 ? plain : highest + 1;
}

void main() {
  tearDown(() => L10n.instance.set('es'));

  test('every English entry takes the same arguments as its Spanish key', () {
    final bad = [
      for (final e in kEnglish.entries)
        if (_slots(e.key) != _slots(e.value)) e.key,
    ];
    expect(bad, isEmpty);
  });

  test('Spanish is the source: nothing changes in es', () {
    L10n.instance.set('es');
    expect(tx('Ajustes'), 'Ajustes');
    expect(tr('Renombrado: {}', ['a.txt']), 'Renombrado: a.txt');
  });

  test('English translates, fills slots and falls back to Spanish', () {
    L10n.instance.set('en');
    final es = kEnglish.keys.firstWhere(
      (k) => _slots(k) == 1 && k.contains('{}') && kEnglish[k]!.contains('{}'),
    );
    expect(tr(es, ['x']), kEnglish[es]!.replaceFirst('{}', 'x'));
    expect(tx('texto que no existe en el catálogo'), 'texto que no existe en el catálogo');
  });

  test('text arguments are translated too', () {
    L10n.instance.set('en');
    final key = kEnglish.keys.firstWhere((k) => _slots(k) == 0 && !k.contains('{'));
    expect(tr('{}', [key]), kEnglish[key]);
  });

  test('changing the language notifies and updates the locale', () {
    var calls = 0;
    void f() => calls++;
    L10n.instance.addListener(f);
    L10n.instance.set('en');
    L10n.instance.set('en');
    L10n.instance.set('es');
    L10n.instance.removeListener(f);
    expect(calls, 2);
    expect(L10n.instance.locale, const Locale('es'));
  });

  testWidgets('Text follows the language without a rebuild from outside', (
    tester,
  ) async {
    final es = kEnglish.keys.firstWhere((k) => !k.contains('{') && k.length < 30);
    await tester.pumpWidget(
      MaterialApp(
        locale: L10n.instance.locale,
        home: Scaffold(body: Text(es)),
      ),
    );
    expect(find.text(es), findsOneWidget);
    L10n.instance.set('en');
    await tester.pumpWidget(
      MaterialApp(
        locale: L10n.instance.locale,
        home: Scaffold(body: Text(es)),
      ),
    );
    expect(find.text(kEnglish[es]!), findsOneWidget);
  });
}
