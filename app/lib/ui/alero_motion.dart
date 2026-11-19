import 'package:flutter/material.dart' hide Text;

import 'expressive.dart';
import '../l10n.dart';

/// Windows 11 Fluent motion tokens. Spatial movement keeps using [Spring]; these are for fades, colors and
/// micro-interactions, which stay quick (Linear/Raycast) and are never multiplied by [motionScale].
class Fluent {
  const Fluent._();
  static const d83 = Duration(milliseconds: 83),
      d167 = Duration(milliseconds: 167),
      d250 = Duration(milliseconds: 250),
      d333 = Duration(milliseconds: 333);

  /// Things arriving: fast start, soft landing.
  static const Curve enter = Cubic(0, 0, 0, 1);

  /// Things leaving: Fluent's accelerate, softer than (1,0,1,1) which cuts off at the end.
  static const Curve exit = Cubic(.7, 0, 1, .5);

  /// Point to point.
  static const Curve point = Cubic(.55, .55, 0, 1);
}

/// Orion-inspired motion and the Material MotionScheme.
/// Applied on Windows and Android; respects reduced-motion accessibility.
class AleroMotion {
  const AleroMotion._();

  static Duration duration(BuildContext context, int ms) =>
      motion(context, Duration(milliseconds: ms));

  /// Micro-interaction length (hover, press, focus, menus, fades): as given, only zeroed by reduced motion.
  static Duration micro(BuildContext context, Duration d) =>
      MediaQuery.of(context).disableAnimations ? Duration.zero : d;

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

/// Linear-style press for cards, rows and buttons: a 120 ms tint and border fade on hover or focus, and 0.97 scale
/// while pressed. Still an InkWell, so keyboard, focus and accessibility work. Usage: `AleroPress(onTap: f, child: c)`.
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
  bool _down = false, _lit = false;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final r = BorderRadius.circular(widget.radius);
    final lit = _lit && widget.onTap != null;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: r,
        // The tint below replaces the InkWell's own, which does not fade.
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        onHighlightChanged: (down) {
          if (mounted) setState(() => _down = down);
        },
        onHover: (h) {
          if (mounted) setState(() => _lit = h);
        },
        onFocusChange: (f) {
          if (mounted) setState(() => _lit = f);
        },
        child: AnimatedScale(
          scale: _down ? .97 : 1,
          duration: AleroMotion.micro(context, Fluent.d167),
          curve: Fluent.enter,
          // Painted over the child: cards with their own fill would hide a tint underneath.
          child: AnimatedContainer(
            duration: AleroMotion.micro(
              context,
              const Duration(milliseconds: 120),
            ),
            curve: Curves.easeOut,
            foregroundDecoration: BoxDecoration(
              borderRadius: r,
              color: ink.withValues(alpha: lit ? .06 : 0),
              border: Border.all(color: ink.withValues(alpha: lit ? .10 : 0)),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
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

/// Wraps an AnimatedSwitcher child so the one that is leaving (animation running in reverse) takes no taps, focus or
/// semantics. The wrapper is always the same, only the flags change, so the entering child never remounts.
Widget switcherChild(Animation<double> a, Widget child) => AnimatedBuilder(
  animation: a,
  child: child,
  builder: (_, c) {
    final out = a.status == AnimationStatus.reverse;
    return IgnorePointer(
      ignoring: out,
      child: ExcludeFocus(
        excluding: out,
        child: ExcludeSemantics(excluding: out, child: c),
      ),
    );
  },
);

/// Content change as in Notion Calendar / Spotify: fade-through (the old content leaves in the first half, the new
/// one arrives in the second) with a small slide along [axis]. The child needs a Key that changes with the content;
/// [forward] false reverses the direction. Usage: `MotionSwitch(child: Page(key: ValueKey(i)), forward: i > last)`.
class MotionSwitch extends StatelessWidget {
  const MotionSwitch({
    super.key,
    required this.child,
    this.forward = true,
    this.axis = Axis.horizontal,
    this.distance = 12,
  });
  final Widget child;
  final bool forward;
  final Axis axis;
  final double distance;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: motion(context, Fluent.d250),
    switchInCurve: Fluent.enter,
    switchOutCurve: Fluent.enter,
    transitionBuilder: (c, a) {
      // The leaving child's animation runs 1 -> 0 and its key is no longer the current one.
      final dir = (forward ? 1 : -1) * (c.key == child.key ? 1 : -1);
      return FadeTransition(
        opacity: a.drive(CurveTween(curve: const Interval(.5, 1))),
        child: AnimatedBuilder(
          animation: a,
          child: switcherChild(a, c),
          builder: (_, c) {
            final d = (1 - a.value) * distance * dir;
            return Transform.translate(
              offset: axis == Axis.horizontal ? Offset(d, 0) : Offset(0, d),
              child: c,
            );
          },
        ),
      );
    },
    child: child,
  );
}

/// Plain crossfade for covers, images and text whose content changes (key the child by its content).
/// Usage: `MotionFade(child: Image(key: ValueKey(url)))`.
class MotionFade extends StatelessWidget {
  const MotionFade({super.key, required this.child, this.layoutBuilder});
  final Widget child;
  final AnimatedSwitcherLayoutBuilder? layoutBuilder;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: AleroMotion.micro(context, Fluent.d250),
    switchInCurve: Fluent.enter,
    switchOutCurve: Fluent.exit,
    layoutBuilder: layoutBuilder ?? AnimatedSwitcher.defaultLayoutBuilder,
    transitionBuilder: (c, a) =>
        FadeTransition(opacity: a, child: switcherChild(a, c)),
    child: child,
  );
}

/// Arc-style expand and collapse for sections, panels and details: the height follows the spring and the content
/// fades. The child stays mounted (keeps its state) while collapsed, but takes no taps, focus or semantics.
/// Usage: `ArcExpand(expanded: open, child: Details())`.
class ArcExpand extends StatelessWidget {
  const ArcExpand({super.key, required this.expanded, required this.child});
  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedSize(
      alignment: Alignment.topCenter,
      duration: motion(context, Spring.spatial.settle),
      curve: Spring.spatial,
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: expanded ? null : 0,
        child: ExcludeFocus(
          excluding: !expanded,
          child: IgnorePointer(
            ignoring: !expanded,
            child: ExcludeSemantics(
              excluding: !expanded,
              child: AnimatedOpacity(
                opacity: expanded ? 1 : 0,
                duration: AleroMotion.micro(context, Fluent.d167),
                curve: Fluent.enter,
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// An item that grows in (height and fade) when it mounts and shrinks out when [show] turns false, then calls
/// [onGone]. Replays on every mount, so use it for lists changed by the user, not for scrolling builders.
/// Usage: `SizeFade(child: Row())`; for whole lists use [MotionList].
class SizeFade extends StatefulWidget {
  const SizeFade({
    super.key,
    required this.child,
    this.show = true,
    this.animateIn = true,
    this.onGone,
  });
  final Widget child;
  final bool show, animateIn;
  final VoidCallback? onGone;

  @override
  State<SizeFade> createState() => _SizeFadeState();
}

class _SizeFadeState extends State<SizeFade> {
  // Decided once, like Entrance: switching structure later would remount the child.
  late final double _from =
      !widget.animateIn ||
          Entrance.quiet ||
          MediaQuery.of(context).disableAnimations
      ? 1
      : 0;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: _from, end: widget.show ? 1 : 0),
    duration: AleroMotion.micro(context, Fluent.d250),
    curve: Fluent.enter,
    onEnd: () {
      if (!widget.show) widget.onGone?.call();
    },
    builder: (_, v, c) => ClipRect(
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: v,
        child: Opacity(opacity: v, child: c),
      ),
    ),
    child: widget.child,
  );
}

/// A column whose members grow in when added and shrink out when removed. Every child needs a unique Key.
/// Usage: `MotionList(children: [for (final t in items) Tile(key: ValueKey(t.id), t)])`.
class MotionList extends StatefulWidget {
  const MotionList({
    super.key,
    required this.children,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });
  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  State<MotionList> createState() => _MotionListState();
}

class _Row {
  _Row(this.child, {required this.fresh});
  Widget child;
  bool fresh, leaving = false;
}

class _MotionListState extends State<MotionList> {
  final _byKey = <Key, _Row>{};
  List<Key> _order = [];

  @override
  void initState() {
    super.initState();
    _sync(initial: true);
  }

  @override
  void didUpdateWidget(MotionList o) {
    super.didUpdateWidget(o);
    _sync(initial: false);
  }

  void _sync({required bool initial}) {
    final keys = [for (final c in widget.children) c.key!];
    for (final c in widget.children) {
      final r = _byKey[c.key!];
      if (r == null) {
        _byKey[c.key!] = _Row(c, fresh: !initial);
      } else {
        r.child = c;
        r.leaving = false;
      }
    }
    // Removed items stay where they were until their exit ends.
    final next = [...keys];
    for (var i = 0; i < _order.length; i++) {
      final k = _order[i];
      if (!keys.contains(k)) {
        _byKey[k]!.leaving = true;
        next.insert(i.clamp(0, next.length), k);
      }
    }
    _order = next;
  }

  void _gone(Key k) {
    if (!mounted || _byKey[k]?.leaving != true) return;
    setState(() {
      _byKey.remove(k);
      _order.remove(k);
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: widget.crossAxisAlignment,
    children: [
      for (final k in _order)
        SizeFade(
          key: k,
          show: !_byKey[k]!.leaving,
          animateIn: _byKey[k]!.fresh,
          onGone: () => _gone(k),
          child: _byKey[k]!.child,
        ),
    ],
  );
}

/// A highlight that glides to the selected child of a vertical list instead of fading in place. The selected
/// child draws no background of its own. [selected] indexes [children] (-1 for none); [inset] trims the measured
/// box (spacing a child carries). Measured after layout, so the very first frame shows no highlight.
/// Usage: `SlidingSelection(selected: i, color: c, children: [...])`.
class SlidingSelection extends StatefulWidget {
  const SlidingSelection({
    super.key,
    required this.selected,
    required this.children,
    required this.color,
    this.radius = 10,
    this.inset = EdgeInsets.zero,
  });
  final int selected;
  final List<Widget> children;
  final Color color;
  final double radius;
  final EdgeInsets inset;

  @override
  State<SlidingSelection> createState() => _SlidingSelectionState();
}

class _SlidingSelectionState extends State<SlidingSelection> {
  final _stack = GlobalKey();
  final _keys = <GlobalKey>[];
  Rect? _rect;
  bool _glide = false;

  void _measure() {
    if (!mounted) return;
    final i = widget.selected;
    final stack = _stack.currentContext?.findRenderObject() as RenderBox?;
    final box = i < 0 || i >= _keys.length
        ? null
        : _keys[i].currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || box == null || !stack.attached || !box.attached) {
      return;
    }
    final r = widget.inset.deflateRect(
      box.localToGlobal(Offset.zero, ancestor: stack) & box.size,
    );
    final old = _rect;
    if (old != null &&
        (old.top - r.top).abs() < .5 &&
        (old.height - r.height).abs() < .5) {
      return;
    }
    // The first measurement places the highlight; later ones move it.
    setState(() {
      _glide = old != null;
      _rect = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    while (_keys.length < widget.children.length) {
      _keys.add(GlobalKey());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final r = _rect;
    return Stack(
      key: _stack,
      children: [
        AnimatedPositioned(
          left: 0,
          right: 0,
          top: r?.top ?? 0,
          height: widget.selected < 0 ? 0 : r?.height ?? 0,
          duration: _glide
              ? motion(context, Spring.fast.settle)
              : Duration.zero,
          curve: Spring.fast,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(widget.radius),
              ),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.children.length; i++)
              KeyedSubtree(key: _keys[i], child: widget.children[i]),
          ],
        ),
      ],
    );
  }
}

/// A number that tweens to its new value (progress, percentage, counter) instead of jumping.
/// Usage: `TweenValue(p, builder: (_, v) => Text('${(v * 100).round()} %'))`.
class TweenValue extends StatelessWidget {
  const TweenValue(this.value, {super.key, required this.builder});
  final double value;
  final Widget Function(BuildContext, double) builder;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: value),
    duration: AleroMotion.micro(context, Fluent.d333),
    curve: Fluent.enter,
    builder: (c, v, _) => builder(c, v),
  );
}

/// [LinearProgressIndicator] whose value glides; null stays indeterminate. Usage: `MotionProgress(p)`.
class MotionProgress extends StatelessWidget {
  const MotionProgress(this.value, {super.key});
  final double? value;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: value ?? 0),
    duration: AleroMotion.micro(context, Fluent.d333),
    curve: Fluent.enter,
    builder: (_, v, _) =>
        LinearProgressIndicator(value: value == null ? null : v),
  );
}

/// Raycast-style pop for custom menus and popovers: grows from 96 % while fading in, about 150 ms, from
/// [origin] (the anchor side). Plays when it mounts. Usage: `PopIn(origin: Alignment.topRight, child: Menu())`.
/// Material's own popup menus get their timing from the theme instead (see withMotion in theme.dart).
class PopIn extends StatelessWidget {
  const PopIn({
    super.key,
    required this.child,
    this.origin = Alignment.topCenter,
  });
  final Widget child;
  final Alignment origin;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: AleroMotion.micro(context, const Duration(milliseconds: 150)),
    curve: Fluent.enter,
    builder: (_, v, c) => Opacity(
      opacity: v,
      child: Transform.scale(scale: .96 + .04 * v, alignment: origin, child: c),
    ),
    child: RepaintBoundary(child: child),
  );
}

/// Toasts slide up and fade (250 ms in, 167 ms out) instead of Material's default timing. Use instead of
/// `showSnackBar`: `ScaffoldMessenger.of(context).showToast(SnackBar(...))`.
extension ToastMotion on ScaffoldMessengerState {
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showToast(
    SnackBar bar,
  ) => showSnackBar(
    bar,
    snackBarAnimationStyle: MediaQuery.of(context).disableAnimations
        ? AnimationStyle.noAnimation
        : AnimationStyle(
            duration: Fluent.d250,
            reverseDuration: Fluent.d167,
            curve: Fluent.enter,
            reverseCurve: Fluent.exit,
          ),
  );
}

/// Popup menus (PopupMenuButton, showMenu): 150 ms in, 83 ms out, Fluent curves; Material scales and fades them from
/// the anchor but exposes the timing only per call, not in the theme. Usage: `PopupMenuButton(popUpAnimationStyle: popUpMotion(context))`.
AnimationStyle popUpMotion(BuildContext c) => MediaQuery.of(c).disableAnimations
    ? AnimationStyle.noAnimation
    : AnimationStyle(
        duration: const Duration(milliseconds: 150),
        reverseDuration: Fluent.d83,
        curve: Fluent.enter,
        reverseCurve: Fluent.exit,
      );

/// Bottom sheets: 250 ms up, 167 ms down. Usage: `showModalBottomSheet(sheetAnimationStyle: sheetMotion(context), ...)`.
AnimationStyle sheetMotion(BuildContext c) => MediaQuery.of(c).disableAnimations
    ? AnimationStyle.noAnimation
    : AnimationStyle(
        duration: motion(c, Fluent.d250),
        reverseDuration: Fluent.d167,
        curve: Fluent.enter,
        reverseCurve: Fluent.exit,
      );
