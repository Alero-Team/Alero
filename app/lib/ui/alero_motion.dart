import 'package:flutter/material.dart';

import 'expressive.dart';

/// Orion-inspired motion and the Material MotionScheme.
/// Applied on Windows and Android; respects reduced-motion accessibility.
class AleroMotion {
  const AleroMotion._();

  static Duration duration(BuildContext context, int ms) =>
      motion(context, Duration(milliseconds: ms));

  // The old curve clamped the spring to [0, 1], flattening its overshoot into a hard stop.
  static const Curve spatial = Spring.spatial;
  static const Curve fastSpatial = Spring.fast;
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
    final incoming = animation.drive(CurveTween(curve: Curves.easeOutCubic));
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
      duration: Duration(milliseconds: 370 + delay) * motionScale,
      curve: const _AleroDelayedSpring(.38),
      builder: (_, v, c) => Opacity(
        opacity: v.clamp(0.0, 1.0).toDouble(),
        child: Transform.translate(offset: Offset(0, (1 - v) * 24), child: c),
      ),
      // Painted once: the fade and slide move a finished layer instead of repainting the card every frame.
      child: RepaintBoundary(child: child),
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

class _AleroDelayedSpring extends Curve {
  const _AleroDelayedSpring(this.delay);
  final double delay;

  @override
  double transformInternal(double t) => t <= delay
      ? 0
      : Spring.spatial.transform(((t - delay) / (1 - delay)).clamp(0, 1));
}
