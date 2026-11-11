import 'dart:math' as math;

import 'package:flutter/material.dart' as m;
import 'package:flutter/material.dart' hide Icon;

import 'expressive.dart' show motion;

/// Alero's `Icon`: Flutter's, plus a short spring when the control it sits in is tapped (it swells, tilts and
/// fills in for an instant). Files import this one and hide Flutter's, so every icon in the app answers a tap
/// without each call site asking for it. Decorative icons outside a tappable control never move, and nothing
/// moves when the system asks for reduced motion.
class Icon extends StatefulWidget {
  const Icon(
    this.icon, {
    super.key,
    this.size,
    this.fill,
    this.color,
    this.semanticLabel,
  });
  final IconData? icon;
  final double? size, fill;
  final Color? color;
  final String? semanticLabel;

  @override
  State<Icon> createState() => _IconState();
}

class _IconState extends State<Icon> {
  int _taps = 0;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    IconTaps.at.addListener(_tapped);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  // Between leaving the tree and being disposed (a closing menu), its ancestors must not be walked.
  bool _inTree = true;

  @override
  void activate() {
    super.activate();
    _inTree = true;
  }

  @override
  void deactivate() {
    _inTree = false;
    super.deactivate();
  }

  @override
  void dispose() {
    IconTaps.at.removeListener(_tapped);
    super.dispose();
  }

  void _tapped() {
    final at = IconTaps.at.value;
    // A page under a dialog or another page keeps its icons still.
    if (at == null || !mounted || !_inTree || !(_route?.isCurrent ?? true)) {
      return;
    }
    RenderObject? control;
    context.visitAncestorElements((e) {
      final w = e.widget;
      final tappable =
          (w is InkResponse && (w.onTap != null || w.onLongPress != null)) ||
          (w is GestureDetector && w.onTap != null);
      if (tappable) control = e.renderObject;
      return !tappable;
    });
    final box = control;
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    if ((box.localToGlobal(Offset.zero) & box.size).contains(at)) {
      setState(() => _taps++);
    }
  }

  Widget _icon([double? fill]) => m.Icon(
    widget.icon,
    size: widget.size,
    fill: fill ?? widget.fill,
    color: widget.color,
    semanticLabel: widget.semanticLabel,
  );

  @override
  Widget build(BuildContext context) {
    final length = motion(context, const Duration(milliseconds: 380));
    if (_taps == 0 || length == Duration.zero) return _icon();
    final base = widget.fill ?? IconTheme.of(context).fill ?? 0;
    return TweenAnimationBuilder<double>(
      key: ValueKey(_taps), // a new tap restarts the spring
      tween: Tween(begin: 0, end: 1),
      duration: length,
      builder: (_, t, _) {
        final fade = 1 - t; // every part dies out by the end
        return Transform.rotate(
          angle: -.2 * math.sin(t * math.pi * 2) * fade,
          child: Transform.scale(
            scale: 1 + .28 * math.sin(t * math.pi * 2.5) * fade,
            // Filled or not, nothing in between: every other fill value is a new glyph to shape and
            // rasterize, one per frame, and that stutters on Windows.
            child: _icon(t < .6 ? 1 : base),
          ),
        );
      },
    );
  }
}

/// Where the last tap landed (global position). The app's root feeds it; every [Icon] listens.
abstract final class IconTaps {
  static final at = _Taps();

  /// Wraps the app: a press that lifts where it began, quickly, is a tap. Drags and long presses are not.
  static Widget listen(Widget child) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (e) {
      _down = e.position;
      _since = e.timeStamp;
    },
    onPointerUp: (e) {
      final from = _down;
      if (from != null &&
          (e.position - from).distance < 18 &&
          e.timeStamp - _since < const Duration(milliseconds: 450)) {
        at.tap(e.position);
      }
    },
    child: child,
  );

  static Offset? _down;
  static var _since = Duration.zero;
}

class _Taps extends ChangeNotifier {
  Offset? value;
  void tap(Offset at) {
    value = at;
    notifyListeners(); // also for two taps on the same spot
  }
}
