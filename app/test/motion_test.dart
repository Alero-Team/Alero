import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/ui/expressive.dart';

/// The shell's section switcher, reduced to what the transition does.
Widget host(String page, {bool reduceMotion = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduceMotion),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Builder(
      builder: (context) => PageTransitionSwitcher(
        duration: motion(context, const Duration(milliseconds: 320)),
        layoutBuilder: (e) => Stack(children: e),
        transitionBuilder: orionTabTransition,
        child: KeyedSubtree(
          key: ValueKey(page),
          child: GestureDetector(
            onTap: () => taps.add(page),
            child: SizedBox.expand(child: Text(page)),
          ),
        ),
      ),
    ),
  ),
);

final taps = <String>[];

/// Product of every FadeTransition above the page's text: what the user actually sees.
double opacityOf(WidgetTester t, String page) {
  var o = 1.0;
  for (final f in t.widgetList<FadeTransition>(
    find.ancestor(of: find.text(page), matching: find.byType(FadeTransition)),
  )) {
    o *= f.opacity.value;
  }
  return o;
}

void main() {
  setUp(taps.clear);

  testWidgets(
    'the leaving page fades out instead of staying opaque underneath',
    (t) async {
      await t.pumpWidget(host('Inicio'));
      await t.pumpWidget(host('Archivos'));
      await t.pump(const Duration(milliseconds: 80));
      expect(opacityOf(t, 'Inicio'), lessThan(1));
      // Gone by a third of the transition, so pages never visibly overlap for long.
      await t.pump(const Duration(milliseconds: 100));
      expect(opacityOf(t, 'Inicio'), 0);
      await t.pumpAndSettle();
      expect(find.text('Inicio'), findsNothing);
      expect(opacityOf(t, 'Archivos'), 1);
    },
  );

  testWidgets(
    'switching quickly across sections ends on the last one, never blank or stacked',
    (t) async {
      await t.pumpWidget(host('Inicio'));
      for (final p in [
        'Archivos',
        'Explorador',
        'Dispositivos',
        'Ajustes',
        'Inicio',
        'Archivos',
      ]) {
        await t.pumpWidget(host(p));
        await t.pump(const Duration(milliseconds: 40));
      }
      // Mid-way, only the arriving page can be fully visible.
      final visible = ['Inicio', 'Explorador', 'Dispositivos', 'Ajustes'].where(
        (p) => find.text(p).evaluate().isNotEmpty && opacityOf(t, p) > 0.5,
      );
      expect(visible, isEmpty);
      await t.pumpAndSettle();
      expect(find.text('Archivos'), findsOneWidget);
      expect(opacityOf(t, 'Archivos'), 1);
      for (final p in ['Inicio', 'Explorador', 'Dispositivos', 'Ajustes']) {
        expect(find.text(p), findsNothing);
      }
    },
  );

  testWidgets('a tap during the transition reaches the arriving page only', (
    t,
  ) async {
    await t.pumpWidget(host('Inicio'));
    await t.pumpWidget(host('Archivos'));
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(const Offset(10, 10));
    expect(taps, ['Archivos']);
    await t.pumpAndSettle();
  });

  testWidgets('reduced motion switches at once', (t) async {
    await t.pumpWidget(host('Inicio', reduceMotion: true));
    await t.pumpWidget(host('Archivos', reduceMotion: true));
    await t.pump();
    expect(find.text('Inicio'), findsNothing);
    expect(opacityOf(t, 'Archivos'), 1);
  });
}
