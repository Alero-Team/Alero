import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'expressive.dart';
import 'theme.dart';

/// Approved identity: congruent paths rotated 180 degrees around (59, 48).
/// Source: branding/alero_symbol.svg; Android and desktop icons use the same geometry.
class AleroMark extends StatelessWidget {
  const AleroMark({super.key, this.size = 40, this.color, this.draw = 1});
  final double size;
  final Color? color;

  /// 0..1: how much of each stroke is drawn (animate it for a draw-on entrance).
  final double draw;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Alero',
    image: true,
    child: SizedBox(
      width: size,
      height: size * 70 / 92,
      child: CustomPaint(
        painter: _Mark(color ?? Theme.of(context).colorScheme.onSurface, draw),
      ),
    ),
  );
}

class _Mark extends CustomPainter {
  _Mark(this.color, this.draw);
  final Color color;
  final double draw;

  // The two paths in SVG units (x 18..100, y 18..78), stroke 10 => the mark spans 13..105 by 13..83.
  static Path _p1() => Path()
    ..moveTo(18, 78)
    ..lineTo(18, 30)
    ..quadraticBezierTo(18, 18, 30, 18)
    ..lineTo(47, 18)
    ..quadraticBezierTo(59, 18, 59, 30)
    ..lineTo(59, 42)
    ..quadraticBezierTo(59, 54, 71, 54)
    ..lineTo(100, 54);

  static Path _p2() => _p1().transform(
    Float64List.fromList([-1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 118, 96, 0, 1]),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 92;
    canvas.scale(k);
    canvas.translate(-13, -13);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final p in [_p1(), _p2()]) {
      if (draw >= 1) {
        canvas.drawPath(p, pen);
        continue;
      }
      for (final m in p.computeMetrics()) {
        canvas.drawPath(m.extractPath(0, m.length * draw.clamp(0, 1)), pen);
      }
    }
  }

  @override
  bool shouldRepaint(_Mark o) => o.color != color || o.draw != draw;
}

/// Mark plus the lowercase wordmark, as in the identity sheet.
class AleroLogo extends StatelessWidget {
  const AleroLogo({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(child: AleroMark(size: size)),
        SizedBox(width: size * 0.3),
        Text(
          'alero',
          style: weight(
            t.titleLarge?.copyWith(
              fontSize: size * 0.85,
              letterSpacing: -size * 0.04,
            ),
            500,
          ),
        ),
      ],
    );
  }
}

/// Draws the mark on once when it first appears (empty states, first run).
class AleroIntro extends StatelessWidget {
  const AleroIntro({super.key, this.size = 64});
  final double size;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: motion(context, const Duration(milliseconds: 900)),
    curve: Curves.easeInOutCubic,
    builder: (_, v, _) => AleroMark(
      size: size,
      draw: v,
      color: Theme.of(context).colorScheme.primary,
    ),
  );
}
