import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/ui/qollqe_motion.dart';

Widget host(Widget c) => MaterialApp(home: Scaffold(body: c));

void main() {
  testWidgets('MotionList keeps a removed item until its exit ends', (t) async {
    Widget list(List<String> ids) => host(
      MotionList(children: [for (final i in ids) Text(i, key: ValueKey(i))]),
    );
    await t.pumpWidget(list(['a', 'b']));
    await t.pumpWidget(list(['b']));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('a'), findsOneWidget);
    await t.pumpAndSettle();
    expect(find.text('a'), findsNothing);
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('SlidingSelection moves its highlight to the new selection', (
    t,
  ) async {
    Widget sel(int i) => host(
      SlidingSelection(
        selected: i,
        color: Colors.red,
        children: const [SizedBox(height: 40), SizedBox(height: 40)],
      ),
    );
    double top() =>
        t.widget<AnimatedPositioned>(find.byType(AnimatedPositioned)).top!;
    await t.pumpWidget(sel(0));
    await t.pump();
    expect(top(), 0);
    await t.pumpWidget(sel(1));
    await t.pump();
    await t.pumpAndSettle();
    expect(top(), 40);
  });

  testWidgets('ArcExpand keeps its child mounted while collapsed', (t) async {
    await t.pumpWidget(
      host(const ArcExpand(expanded: false, child: Text('x'))),
    );
    expect(find.text('x', skipOffstage: false), findsOneWidget);
    expect(t.getSize(find.byType(ArcExpand)).height, 0);
  });
}
