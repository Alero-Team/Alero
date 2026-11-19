import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;

import 'expressive.dart';
import 'theme.dart';
import '../l10n.dart';

/// Approved identity: congruent paths rotated 180 degrees around (59, 48).
/// Source: branding/alero_symbol.svg; Android and desktop icons use the same geometry.
class AleroMark extends StatelessWidget {
  const AleroMark({
    super.key,
    this.size = 40,
    this.color,
    this.draw = 1,
    this.sweep = 0,
    this.dim = 0,
  });
  final double size;
  final Color? color;

  /// 0..1: how much of each stroke is drawn (animate it for a draw-on entrance).
  final double draw;

  /// Loading: [dim] 0..1 fades the strokes back while a bright trace runs along them, at [sweep] 0..1.
  final double sweep, dim;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Alero',
    image: true,
    child: SizedBox(
      width: size,
      height: size * 70 / 92,
      child: CustomPaint(
        painter: _Mark(
          color ?? Theme.of(context).colorScheme.onSurface,
          draw,
          sweep,
          dim,
        ),
      ),
    ),
  );
}

class _Mark extends CustomPainter {
  _Mark(this.color, this.draw, this.sweep, this.dim);
  final Color color;
  final double draw, sweep, dim;
  static const _trace = .4; // the running trace's share of each stroke

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
      if (dim > 0) {
        canvas.drawPath(
          p,
          Paint.from(pen)
            ..color = color.withValues(alpha: color.a * (1 - .72 * dim)),
        );
        for (final m in p.computeMetrics()) {
          final a = (sweep * (1 + _trace) - _trace) * m.length;
          canvas.drawPath(
            m.extractPath(
              a.clamp(0, m.length),
              (a + _trace * m.length).clamp(0, m.length),
            ),
            pen,
          );
        }
        continue;
      }
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
  bool shouldRepaint(_Mark o) =>
      o.color != color || o.draw != draw || o.sweep != sweep || o.dim != dim;
}

/// Mark plus the wordmark. The trade name is always written "Alero".
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
          'Alero',
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

/// Base length of [AleroSplash]; main holds the first screen at least this long (scaled like every animation).
const splashBase = Duration(milliseconds: 650);

/// Start-up screen on every launch. On Android it continues the native splash (res/drawable/alero_splash.xml:
/// same centre, same ~41 dp mark, same colour), so the mark starts complete and only the wordmark and tint
/// appear; elsewhere there is no native splash, so the mark is drawn on. After that entrance, and until main
/// swaps it for the app, the mark dims and a trace runs along its strokes (never with reduced motion).
class AleroSplash extends StatefulWidget {
  const AleroSplash({super.key});

  @override
  State<AleroSplash> createState() => _AleroSplashState();
}

class _AleroSplashState extends State<AleroSplash>
    with TickerProviderStateMixin {
  static const _size = 41.0;
  late final _in = AnimationController(vsync: this);
  late final _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );
  late final _dim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _in.duration = motion(context, splashBase);
    if (_in.duration == Duration.zero) {
      _in.value = 1;
      return;
    }
    _in.forward().whenCompleteOrCancel(() {
      if (!mounted) return;
      _dim.forward();
      _loop.repeat();
    });
  }

  @override
  void dispose() {
    _in.dispose();
    _loop.dispose();
    _dim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge([_in, _loop, _dim]),
      builder: (context, _) {
        final v = Curves.easeInOutCubic.transform(_in.value);
        final name = const Interval(.4, 1, curve: Curves.easeOut).transform(v);
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            AleroMark(
              size: _size,
              draw: isPhone ? 1 : const Interval(0, .7).transform(v),
              color: Color.lerp(s.onSurface, s.primary, v),
              sweep: Curves.easeInOutSine.transform(_loop.value),
              dim: Curves.easeOut.transform(_dim.value),
            ),
            Transform.translate(
              offset: Offset(0, 38 + (1 - name) * 8),
              child: Opacity(
                opacity: name,
                child: ExcludeSemantics(
                  child: Text(
                    'Alero',
                    style: weight(
                      Theme.of(context).textTheme.titleLarge
                          ?.copyWith(letterSpacing: -.9),
                      500,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
