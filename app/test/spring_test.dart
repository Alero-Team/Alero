import 'package:pb_app/ui/expressive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('springs land on 1 without a snap at the end', () {
    for (final s in [Spring.spatial, Spring.fast, Spring.effects]) {
      expect(s.transform(0.999), closeTo(1, 0.005));
      expect(s.transform(0.5), greaterThan(0.5));
    }
  });
}
