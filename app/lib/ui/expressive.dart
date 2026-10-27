import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'dart:ui' as ui show Image;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../remote.dart';
import 'theme.dart';

/// Material 3 Expressive pieces Flutter 3.47 does not ship: spring motion, wavy progress, cookie shape, shape
/// morphing; plus the glass panel used only on floating elements (ADR-0008).

/// Spring as a [Curve], so implicit animations (AnimatedContainer…) move like M3 Expressive.
/// Stiffness/damping from the M3 Expressive motion scheme (REPORTADO: values mirrored by community ports of
/// Compose's MotionScheme; not on an official page we could read).
class Spring extends Curve {
  const Spring(this.stiffness, this.damping);
  final double stiffness, damping;

  /// Default spatial (position, size, shape): stiffness 380, damping 0.8.
  static const spatial = Spring(380, 0.8);

  /// Fast spatial (small elements: buttons, chips): stiffness 800, damping 0.6.
  static const fast = Spring(800, 0.6);

  /// Effects (color, opacity): no bounce.
  static const effects = Spring(1600, 1);

  /// How long the spring takes to settle, used as the animation duration.
  Duration get settle => Duration(milliseconds: (4000 / math.sqrt(stiffness) / damping).round().clamp(150, 700));

  static final _sims = <(double, double), SpringSimulation>{};

  @override
  double transformInternal(double t) {
    final d = settle.inMilliseconds / 1000;
    final s = _sims.putIfAbsent(
      (stiffness, damping),
      () => SpringSimulation(SpringDescription.withDampingRatio(mass: 1, stiffness: stiffness, ratio: damping), 0, 1, 0),
    );
    return s.x(t * d);
  }
}

/// Animation length, or zero when the system asks for reduced motion.
Duration motion(BuildContext c, Duration d) => MediaQuery.of(c).disableAnimations ? Duration.zero : d;

/// Wavy linear progress (M3 Expressive). The wave travels while active; still with reduced motion.
class WavyProgress extends StatefulWidget {
  const WavyProgress({super.key, this.value, this.label = '', this.height = 12});
  final double? value;
  final String label;
  final double height;

  @override
  State<WavyProgress> createState() => _WavyProgressState();
}

class _WavyProgressState extends State<WavyProgress> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.of(context).disableAnimations;
    if (still) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final v = widget.value;
    return Semantics(
      label: widget.label,
      value: v == null ? null : '${(v * 100).round()} %',
      child: RepaintBoundary(
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: CustomPaint(painter: _Wave(v, _c, p.signal, p.alt)),
        ),
      ),
    );
  }
}

class _Wave extends CustomPainter {
  _Wave(this.value, this.phase, this.color, this.track) : super(repaint: phase);
  final double? value;
  final Animation<double> phase;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size s) {
    final mid = s.height / 2;
    const stroke = 4.0, gap = 4.0, wl = 20.0;
    final amp = (s.height - stroke) / 3;
    final v = (value ?? 0.3).clamp(0.0, 1.0);
    final ph = phase.value;
    final end = s.width * v;
    final start = value == null ? (s.width + end) * ph - end : 0.0;
    final from = start.clamp(0.0, s.width), to = (start + end).clamp(0.0, s.width);
    final paint = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final wave = Path();
    for (var x = from; x <= to; x += 1.5) {
      final y = mid + amp * math.sin((x / wl - (value == null ? 0 : ph)) * 2 * math.pi);
      x == from ? wave.moveTo(x, y) : wave.lineTo(x, y);
    }
    canvas.drawPath(wave, paint);
    final t = Paint()
      ..color = track
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    if (to + gap < s.width - stroke) {
      canvas.drawLine(Offset(to + gap + stroke, mid), Offset(s.width - stroke / 2, mid), t);
    }
    if (value == null && from - gap > stroke) {
      canvas.drawLine(Offset(stroke / 2, mid), Offset(from - gap - stroke, mid), t);
    }
    // Stop indicator at the end of the track (M3 accessibility marker).
    canvas.drawCircle(Offset(s.width - stroke / 2, mid), stroke / 2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Wave o) => o.value != value || o.color != color || o.track != track;
}

/// Frosted panel for floating UI only (nav bar, mini player, sheets). Solid with high contrast enabled.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = Radii.card, this.padding = EdgeInsets.zero});
  final Widget child;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final solid = MediaQuery.of(context).highContrast;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final br = BorderRadius.circular(radius);
    final body = Container(
      padding: padding,
      foregroundDecoration: solid ? null : _Rim(radius, dark),
      decoration: BoxDecoration(
        borderRadius: br,
        color: solid ? s.surfaceContainer : null,
        gradient: solid
            ? null
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.lerp(s.surfaceContainerHigh, Colors.white, dark ? 0.08 : 0.5)!.withValues(alpha: 0.72),
                  s.surfaceContainer.withValues(alpha: 0.62),
                ],
              ),
        border: solid ? Border.all(color: s.outlineVariant) : null,
      ),
      child: child,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.35 : 0.10),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: br,
        child: solid
            ? body
            : BackdropFilter(
                // Blur plus a saturation lift: what is behind the glass keeps its color, like Liquid Glass.
                filter: ImageFilter.compose(
                  outer: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                  inner: const ColorFilter.matrix(<double>[
                    1.25, -0.12, -0.02, 0, 0, //
                    -0.05, 1.18, -0.02, 0, 0,
                    -0.05, -0.12, 1.28, 0, 0,
                    0, 0, 0, 1, 0,
                  ]),
                ),
                child: body,
              ),
      ),
    );
  }
}

/// A thin light along the edge, brighter at the top-left, as if lit from above (the rim of Liquid Glass).
class _Rim extends Decoration {
  const _Rim(this.radius, this.dark);
  final double radius;
  final bool dark;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _RimPainter(radius, dark);
}

class _RimPainter extends BoxPainter {
  _RimPainter(this.radius, this.dark);
  final double radius;
  final bool dark;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration c) {
    final r = offset & c.size!;
    canvas.drawRRect(
      RRect.fromRectAndRadius(r.deflate(0.6), Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: dark ? 0.38 : 0.9),
            Colors.white.withValues(alpha: dark ? 0.04 : 0.15),
            Colors.white.withValues(alpha: dark ? 0.18 : 0.5),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(r),
    );
  }
}

/// M3 Expressive "cookie" shape: a circle with soft scallops.
class CookieBorder extends OutlinedBorder {
  const CookieBorder({this.lobes = 9, this.depth = 0.07, super.side});
  final int lobes;
  final double depth;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => getOuterPath(rect);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final c = rect.center, r = rect.shortestSide / 2;
    final path = Path();
    for (var i = 0; i <= 360; i += 2) {
      final a = i * math.pi / 180;
      final rr = r * (1 - depth + depth * math.cos(lobes * a));
      final o = c + Offset(math.cos(a), math.sin(a)) * rr;
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;

  @override
  OutlinedBorder copyWith({BorderSide? side}) => CookieBorder(lobes: lobes, depth: depth, side: side ?? this.side);
}

/// Expressive button whose corners morph: round at rest, squarer when pressed or "on" (e.g. playing).
class MorphButton extends StatefulWidget {
  const MorphButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.size = 56,
    this.on = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;
  final bool on;

  @override
  State<MorphButton> createState() => _MorphButtonState();
}

class _MorphButtonState extends State<MorphButton> {
  bool _down = false, _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final r = widget.size / (_down ? 5 : (widget.on ? 3.4 : 2));
    final w = widget.size * (widget.on ? 1.3 : 1) * (_down ? 0.94 : 1);
    return Semantics(
      button: true,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTapDown: (_) => setState(() => _down = true),
            onTapCancel: () => setState(() => _down = false),
            onTapUp: (_) => setState(() => _down = false),
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: motion(context, Spring.fast.settle),
              curve: Spring.fast,
              width: w,
              height: widget.size,
              decoration: ShapeDecoration(
                color: widget.onPressed == null
                    ? s.surfaceContainerHighest
                    : Color.lerp(s.primary, s.onPrimary, _hover ? 0.08 : 0),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
              ),
              child: ExcludeSemantics(
                child: Icon(widget.icon, size: widget.size * 0.42, color: s.onPrimary, fill: 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Faithful outline of the connected phone, drawn from the geometry it reports (screen ratio, corner radius,
/// camera cutout) over its real wallpaper: the image the user chose in the phone's settings, else the wallpaper's
/// own colours (Android gives those to any app). No manufacturer artwork: any model, no image rights issues.
class PhoneMockup extends StatefulWidget {
  const PhoneMockup({super.key, this.info, this.wallpaper, this.width = 96, this.online = true});
  final PeerInfo? info;
  final Uint8List? wallpaper;
  final double width;
  final bool online;

  @override
  State<PhoneMockup> createState() => _PhoneMockupState();
}

class _PhoneMockupState extends State<PhoneMockup> {
  ui.Image? _img;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(PhoneMockup o) {
    super.didUpdateWidget(o);
    if (!identical(o.wallpaper, widget.wallpaper)) _decode();
  }

  Future<void> _decode() async {
    final bytes = widget.wallpaper;
    if (bytes == null || bytes.isEmpty) {
      if (_img != null) setState(() => _img = null);
      return;
    }
    try {
      // Decode at the size it is drawn, not the size it was sent.
      final codec = await instantiateImageCodec(bytes, targetWidth: (widget.width * 3).ceil());
      final f = await codec.getNextFrame();
      if (mounted && identical(bytes, widget.wallpaper)) setState(() => _img = f.image);
    } catch (_) {
      // A damaged image falls back to the wallpaper colours.
    }
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final s = info?.screen;
    final ratio = s == null ? 20 / 9 : s.h / s.w;
    return Semantics(
      image: true,
      label: [info?.manufacturer, info?.model].whereType<String>().where((x) => x.isNotEmpty).join(' '),
      // Own layer: the wallpaper is not repainted when the card around it animates.
      child: RepaintBoundary(
        child: SizedBox(
          width: widget.width,
          height: widget.width * ratio,
          child: CustomPaint(
            painter: _Phone(s, Theme.of(context).colorScheme, widget.online, info?.wallpaperColors ?? const [], _img),
          ),
        ),
      ),
    );
  }
}

class _Phone extends CustomPainter {
  _Phone(this.s, this.c, this.online, this.colors, this.image);
  final ScreenShape? s;
  final ColorScheme c;
  final bool online;
  final List<Color> colors;
  final ui.Image? image;

  @override
  void paint(Canvas canvas, Size size) {
    final bezel = size.width * 0.035;
    final body = Offset.zero & size;
    final screen = body.deflate(bezel);
    final k = s == null ? 1.0 : screen.width / s!.w;
    final screenR = s != null && s!.radius > 0 ? s!.radius * k : screen.width * 0.13;
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, Radius.circular(screenR + bezel)),
      Paint()..color = const Color(0xFF1C1C1E),
    );
    final rr = RRect.fromRectAndRadius(screen, Radius.circular(screenR));
    canvas.save();
    canvas.clipRRect(rr);
    if (image != null) {
      paintImage(canvas: canvas, rect: screen, image: image!, fit: BoxFit.cover, filterQuality: FilterQuality.medium);
    } else {
      // The wallpaper's own colours as a soft mesh; the system scheme if the phone sent none.
      final a = colors.isNotEmpty ? colors[0] : c.primaryContainer;
      final b = colors.length > 1 ? colors[1] : c.primary;
      final t = colors.length > 2 ? colors[2] : c.tertiaryContainer;
      canvas.drawRect(
        screen,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [a, Color.lerp(a, b, 0.6)!, b],
          ).createShader(screen),
      );
      canvas.drawCircle(
        Offset(screen.left + screen.width * 0.15, screen.top + screen.height * 0.78),
        screen.width * 0.6,
        Paint()..color = t.withValues(alpha: 0.85),
      );
      canvas.drawCircle(
        Offset(screen.right - screen.width * 0.05, screen.top + screen.height * 0.3),
        screen.width * 0.35,
        Paint()..color = Color.lerp(a, t, 0.5)!.withValues(alpha: 0.8),
      );
    }
    // Offline: the screen goes dim, as if locked.
    if (!online) canvas.drawRect(screen, Paint()..color = c.surface.withValues(alpha: 0.6));
    canvas.restore();
    // Front camera, where the phone says it is.
    final cut = s?.cutout;
    final cam = Paint()..color = Colors.black;
    if (cut != null && s != null) {
      final r = Rect.fromLTWH(screen.left + cut.$1 * k, screen.top + cut.$2 * k, cut.$3 * k, cut.$4 * k);
      if ((r.width - r.height).abs() < r.height * 0.4) {
        canvas.drawCircle(r.center, r.shortestSide * 0.42, cam);
      } else {
        canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(r.height / 2)), cam);
      }
    } else {
      canvas.drawCircle(Offset(screen.center.dx, screen.top + screen.width * 0.07), screen.width * 0.035, cam);
    }
    // Side buttons.
    final btn = Paint()..color = const Color(0xFF2C2C2E);
    for (final (top, bottom) in [(0.22, 0.30), (0.36, 0.50)]) {
      canvas.drawRRect(
        RRect.fromLTRBR(size.width - 1, size.height * top, size.width + 1.5, size.height * bottom, const Radius.circular(1)),
        btn,
      );
    }
  }

  @override
  bool shouldRepaint(_Phone o) =>
      o.s != s || o.c != c || o.online != online || o.image != image || !listEquals(o.colors, colors);
}

/// A computer, for the phone app's view of a paired PC.
class DesktopGlyph extends StatelessWidget {
  const DesktopGlyph({super.key, this.size = 88, required this.icon});
  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(color: s.primaryContainer, shape: const CookieBorder()),
      child: Icon(icon, size: size * 0.42, color: s.onPrimaryContainer),
    );
  }
}
