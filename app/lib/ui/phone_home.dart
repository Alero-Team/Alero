import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Icon, Text;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'clipboard.dart';
import 'expressive.dart' show Spring, motion;
import 'pc_control.dart';
import 'pc_files.dart';
import 'pc_screen.dart';
import 'qollqe_motion.dart';
import 'remote_ui.dart';
import 'theme.dart';
import 'widgets.dart' show FitLabel;
import 'icon.dart';
import '../l10n.dart';

/// The four things you do all day with the computer, as small equal buttons in one row of the device card.
/// M3 Expressive connected group: the button under the finger widens a little and its neighbours make room.
class QuickActions extends StatefulWidget {
  const QuickActions(this.hub, this.peer, {super.key});
  final Hub hub;
  final pb.Peer peer;

  @override
  State<QuickActions> createState() => _QuickActionsState();
}

class _QuickActionsState extends State<QuickActions> {
  int _down = -1;
  Hub get hub => widget.hub;
  pb.Peer get peer => widget.peer;

  void _press(int i) {
    if (_down != i) setState(() => _down = i);
  }

  @override
  Widget build(BuildContext context) {
    final online = peer.state == pb.PeerState.connected;
    final info = hub.info[peer.id];
    final canShot =
        online && info != null && info.remoteAllowed && info.canScreen;
    const remoteHint = 'Requiere activar el control remoto en el ordenador';
    final tiles = [
      _Small(
        FluentIcons.arrow_upload_24_regular,
        'Enviar',
        online ? () => hub.send(peer.id) : null,
        primary: true,
      ),
      _Small(
        FluentIcons.clipboard_arrow_right_24_regular,
        'Portapapeles',
        online ? () => openClipboard(context, hub, peer.id) : null,
        // The Fluent arrow sticks out to the right: its ink sits 1.49/24 right of its box's center.
        nudge: isPhone ? 0 : -1.49 / 24,
      ),
      _Small(
        FluentIcons.cast_24_regular,
        'Pantalla',
        canShot ? () => openPcScreen(context, hub, peer.id, peer.name) : null,
        hint: online && !canShot ? remoteHint : null,
      ),
      _Small(
        FluentIcons.screenshot_24_regular,
        'Captura',
        canShot ? _shot : null,
        hint: online && !canShot ? remoteHint : null,
      ),
    ];
    return Row(
      children: [
        for (final (i, tile) in tiles.indexed) ...[
          if (i > 0) const SizedBox(width: Gap.s),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: i == _down ? 1.25 : 1.0),
            duration: motion(context, Spring.fast.settle),
            curve: Spring.fast,
            builder: (_, w, child) =>
                Expanded(flex: (w * 100).round(), child: child!),
            child: Listener(
              onPointerDown: (_) => _press(i),
              onPointerUp: (_) => _press(-1),
              onPointerCancel: (_) => _press(-1),
              child: tile,
            ),
          ),
        ],
      ],
    );
  }

  void _shot() {
    hub.remote.shot(peer.id);
    hub.messages.add(tr('Pidiendo la captura a {}…', [peer.name]));
  }
}

/// A small button: icon over a one-line name. [primary] fills it with the accent. [nudge] shifts the icon
/// sideways, as a fraction of its size, for glyphs whose ink is not centered in their box. A name too long for
/// the tile shrinks to fit instead of being cut with an ellipsis.
class _Small extends StatelessWidget {
  const _Small(
    this.icon,
    this.label,
    this.onTap, {
    this.hint,
    this.primary = false,
    this.nudge = 0,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? hint;
  final bool primary;
  final double nudge;

  static const _iconSize = 19.0;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final fg = primary ? s.onPrimary : s.onSurface;
    return Tooltip(
      message: tx(hint ?? label),
      child: Semantics(
        button: true,
        enabled: onTap != null,
        label: hint == null ? tx(label) : '${tx(label)}. ${tx(hint!)}',
        child: Material(
          color: primary ? s.primary : s.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.tile),

          ),
          child: QollqePress(
            radius: Radii.tile,
            onTap: onTap,
            child: SizedBox(
              height: 60,
              child: ExcludeSemantics(
                child: Opacity(
                  opacity: onTap == null ? 0.45 : 1,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Transform.translate(
                        offset: Offset(nudge * _iconSize, 0),
                        child: Icon(icon, size: _iconSize, color: fg),
                      ),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            label,
                            maxLines: 1,
                            softWrap: false,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: fg),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Control remoto": use the computer from the phone (mouse and keyboard), with its shared files inside.
class RemoteCard extends StatelessWidget {
  const RemoteCard(this.hub, this.peer, {super.key});
  final Hub hub;
  final pb.Peer peer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final online = peer.state == pb.PeerState.connected;
    final blocker = remoteBlocker(hub.info[peer.id], online);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.m, Gap.m, Gap.m, Gap.s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _RemotePreview(
              name: peer.name,
              wallpaper: hub.wallpaper[peer.id],
              onOpen: blocker == null
                  ? () => openPcControl(context, hub, peer.id, peer.name)
                  : null,
            ),
            ArcExpand(
              expanded: blocker != null,
              child: Padding(
                padding: const EdgeInsets.only(top: Gap.s),
                child: Text(
                  blocker ?? '',
                  style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                ),
              ),
            ),
            const SizedBox(height: Gap.s),
            Divider(color: s.outlineVariant),
            ListTile(
              contentPadding: EdgeInsets.zero,
              enabled: online,
              leading: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: s.surfaceContainer,
                  borderRadius: BorderRadius.circular(Radii.chip),
                ),
                child: const Icon(FluentIcons.folder_24_regular, size: 18),
              ),
              title: Text('Archivos del ordenador', style: t.titleSmall),
              subtitle: Text(
                'Carpetas que compartiste en el PC',
                style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
              ),
              trailing: const Icon(FluentIcons.chevron_right_24_regular),
              onTap: () => openPcFiles(context, hub, peer.id, peer.name),
            ),
          ],
        ),
      ),
    );
  }
}

/// The way into "Control remoto", as a picture of what it is: the computer's screen (its wallpaper) drifting
/// slowly, and a fingertip that taps on it now and then, like on the touchpad. Tapping it opens the touchpad. It
/// is a drawing, not the live screen: watching the real one always starts from inside, where the computer shows
/// its notice.
class _RemotePreview extends StatefulWidget {
  const _RemotePreview({required this.name, this.wallpaper, this.onOpen});
  final String name;
  final Uint8List? wallpaper;
  final VoidCallback? onOpen;

  @override
  State<_RemotePreview> createState() => _RemotePreviewState();
}

class _RemotePreviewState extends State<_RemotePreview>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_RemotePreview old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.onOpen == null || MediaQuery.of(context).disableAnimations) {
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
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final on = widget.onOpen != null;
    final paper = widget.wallpaper;
    return Semantics(
      button: true,
      enabled: on,
      label: tr('Control remoto de {}: ratón y teclado', [widget.name]),
      child: Opacity(
        opacity: on ? 1 : .55,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.tile),
          child: AspectRatio(
            aspectRatio: 16 / 7,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The screen drifts: a slow push in and back, panning a little (one loop, no jump at its seam).
                AnimatedBuilder(
                  animation: _c,
                  builder: (_, child) {
                    final a = _c.value * 2 * math.pi;
                    final k = .5 - .5 * math.cos(a);
                    return Transform.scale(
                      scale: 1.04 + .08 * k,
                      alignment: Alignment(-.6 + 1.2 * k, -.2 * math.sin(a)),
                      child: child,
                    );
                  },
                  child: MotionFade(
                    child: SizedBox.expand(
                      key: ValueKey(paper == null ? 0 : identityHashCode(paper)),
                      child: paper != null
                          ? Image.memory(
                              paper,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              cacheWidth: 720,
                              excludeFromSemantics: true,
                              errorBuilder: (_, _, _) =>
                                  ColoredBox(color: s.primaryContainer),
                            )
                          : DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    s.primaryContainer,
                                    s.tertiaryContainer,
                                  ],
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
                // Text stays readable on any wallpaper.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x1A000000), Color(0xB3000000)],
                    ),
                  ),
                ),
                // A fingertip taps twice every four seconds, in a different spot each time.
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _Taps(_c, s.primary),
                    child: const SizedBox.expand(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(Gap.m),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Control remoto',
                              style: t.titleMedium?.copyWith(
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              tr('Ratón y teclado de {}', [widget.name]),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.bodySmall?.copyWith(
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: Gap.s),
                      IgnorePointer(
                        child: FilledButton.tonalIcon(
                          onPressed: on ? () {} : null,
                          icon: const Icon(FluentIcons.cursor_click_24_regular, size: 18),
                          label: const FitLabel('Abrir'),
                        ),
                      ),
                    ],
                  ),
                ),
                // One touch target for the whole picture, with its ripple on top.
                QollqePress(
                  onTap: widget.onOpen,
                  radius: Radii.tile,
                  child: const SizedBox.expand(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The touches of [_RemotePreview]: a fingertip that comes down, taps twice (a ring spreads from each tap), and
/// lifts; each of the four taps of a loop lands somewhere else, clear of the text at the bottom.
class _Taps extends CustomPainter {
  _Taps(this.c, this.tint) : super(repaint: c);
  final Animation<double> c;
  final Color tint;

  static const _spots = [
    Offset(.68, .30),
    Offset(.36, .24),
    Offset(.80, .18),
    Offset(.52, .38),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final t = c.value * _spots.length;
    final spot = _spots[t.floor() % _spots.length];
    final at = Offset(spot.dx * size.width, spot.dy * size.height);
    // Where this tap's four seconds are (0..1).
    final f = t - t.floor();
    for (final start in const [.10, .22]) {
      final k = (f - start) / .22;
      if (k < 0 || k > 1) continue;
      canvas.drawCircle(
        at,
        10 + 22 * Curves.easeOutCubic.transform(k),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white.withValues(alpha: .7 * (1 - k)),
      );
    }
    final shown =
        ((f - .05) / .08).clamp(0.0, 1.0) *
        (1 - ((f - .40) / .10).clamp(0.0, 1.0));
    if (shown > 0) {
      final press = (f > .10 && f < .14) || (f > .22 && f < .26) ? .82 : 1.0;
      canvas.drawCircle(
        at,
        11 * press,
        Paint()..color = Colors.white.withValues(alpha: .28 * shown),
      );
      canvas.drawCircle(
        at,
        6 * press,
        Paint()..color = tint.withValues(alpha: .9 * shown),
      );
    }
  }

  @override
  bool shouldRepaint(_Taps old) => old.tint != tint || old.c != c;
}
