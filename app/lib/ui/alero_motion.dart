import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Orion-inspired motion and the Material MotionScheme.
/// Applied on Windows and Android; respects reduced-motion accessibility.
class AleroMotion {
  const AleroMotion._();

  static Duration duration(BuildContext context, int ms) =>
      MediaQuery.of(context).disableAnimations
          ? Duration.zero
          : Duration(milliseconds: ms);

  static const Curve spatial = _AleroSpring(380, .8);
  static const Curve fastSpatial = _AleroSpring(800, .6);
  static const Curve effects = Curves.easeOutCubic;

  /// Compose's MotionNumber: slide a third of text height and fade each way.
  static Widget number(String text, TextStyle? style) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: effects,
        switchOutCurve: Curves.easeInOut,
        transitionBuilder: (child, animation) => ClipRect(
          child: FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1 / 3),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
        ),
        child: Text(text, key: ValueKey(text), style: style),
      );

  /// Tab changes: 98%-to-100% fade and a reversed leaving view.
  static Widget tab(
    Widget child,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final incoming = animation.drive(
      CurveTween(curve: Curves.easeOutCubic),
    );
    final leaving = secondaryAnimation.drive(
      CurveTween(curve: Curves.easeOutCubic),
    );
    return IgnorePointer(
      ignoring: secondaryAnimation.value > 0,
      child: FadeTransition(
        opacity: incoming,
        child: FadeTransition(
          opacity: ReverseAnimation(leaving),
          child: ScaleTransition(
            scale: Tween<double>(begin: .98, end: 1).animate(incoming),
            child: ScaleTransition(
              scale: Tween<double>(begin: 1, end: .98).animate(leaving),
              child: RepaintBoundary(child: child),
            ),
          ),
        ),
      ),
    );
  }

  /// Card entrance: initial rows reveal with +24 px and 40 ms stagger.
  static Widget reveal(BuildContext context, int index, Widget child) {
    if (MediaQuery.of(context).disableAnimations || index > 8) return child;
    final delay = (index.clamp(0, 8)) * 40;
    return TweenAnimationBuilder<double>(
      key: ValueKey('alero-reveal-$index'),
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 370 + delay),
      curve: const _AleroDelayedSpring(380, .8, .38),
      builder: (_, v, c) => Opacity(
        opacity: v.clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, (1 - v) * 24),
          child: c,
        ),
      ),
      child: child,
    );
  }
}

/// Native press bounce (0.955) instead of the old 0.94 effect.
class AleroPress extends StatefulWidget {
  const AleroPress({
    super.key,
    required this.child,
    required this.onTap,
    this.radius = 16,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double radius;

  @override
  State<AleroPress> createState() => _AleroPressState();
}

class _AleroPressState extends State<AleroPress> {
  bool _down = false;

  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(widget.radius),
          onHighlightChanged: (down) {
            if (mounted) setState(() => _down = down);
          },
          child: AnimatedScale(
            scale: _down ? .955 : 1,
            duration: AleroMotion.duration(context, 240),
            curve: AleroMotion.fastSpatial,
            child: widget.child,
          ),
        ),
      );
}

/// Activity-only 850ms pulse. Never runs while idle or when reduced
/// motion is enabled.
class AleroPulse extends StatefulWidget {
  const AleroPulse({super.key, required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<AleroPulse> createState() => _AleroPulseState();
}

class _AleroPulseState extends State<AleroPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant AleroPulse old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.active && !MediaQuery.of(context).disableAnimations) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _pulse,
        builder: (_, child) => Opacity(
          opacity: widget.active ? .65 + _pulse.value * .35 : 1,
          child: child,
        ),
        child: widget.child,
      );
}

class _AleroSpring extends Curve {
  const _AleroSpring(this.stiffness, this.damping);
  final double stiffness, damping;

  @override
  double transformInternal(double t) => SpringSimulation(
        SpringDescription.withDampingRatio(
          mass: 1,
          stiffness: stiffness,
          ratio: damping,
        ),
        0,
        1,
        0,
      ).x(t * .36).clamp(0, 1);
}

class _AleroDelayedSpring extends Curve {
  const _AleroDelayedSpring(this.stiffness, this.damping, this.delay);
  final double stiffness, damping, delay;

  @override
  double transformInternal(double t) => t <= delay
      ? 0
      : _AleroSpring(stiffness, damping)
          .transform(((t - delay) / (1 - delay)).clamp(0, 1));
}
