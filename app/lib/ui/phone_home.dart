import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Icon;
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'clipboard.dart';
import 'pc_control.dart';
import 'pc_files.dart';
import 'pc_screen.dart';
import 'remote_ui.dart';
import 'theme.dart';
import 'widgets.dart' show FitLabel;
import 'icon.dart';

/// The four things you do all day with the computer, as small equal buttons in one row of the device card.
class QuickActions extends StatelessWidget {
  const QuickActions(this.hub, this.peer, {super.key});
  final Hub hub;
  final pb.Peer peer;

  @override
  Widget build(BuildContext context) {
    final online = peer.state == pb.PeerState.connected;
    final info = hub.info[peer.id];
    final canShot =
        online && info != null && info.remoteAllowed && info.canScreen;
    const remoteHint = 'Requiere activar el control remoto en el ordenador';
    final tiles = [
      _Small(
        Symbols.upload_rounded,
        'Enviar',
        online ? () => hub.send(peer.id) : null,
        primary: true,
      ),
      _Small(
        Symbols.content_paste_go_rounded,
        'Portapapeles',
        online ? () => openClipboard(context, hub, peer.id) : null,
      ),
      _Small(
        Symbols.cast_rounded,
        'Pantalla',
        canShot ? () => openPcScreen(context, hub, peer.id, peer.name) : null,
        hint: online && !canShot ? remoteHint : null,
      ),
      _Small(
        Symbols.screenshot_monitor_rounded,
        'Captura',
        canShot ? _shot : null,
        hint: online && !canShot ? remoteHint : null,
      ),
    ];
    return Row(
      children: [
        for (final (i, tile) in tiles.indexed) ...[
          if (i > 0) const SizedBox(width: Gap.s),
          Expanded(child: tile),
        ],
      ],
    );
  }

  void _shot() {
    hub.remote.shot(peer.id);
    hub.messages.add('Pidiendo la captura a ${peer.name}…');
  }
}

/// A small button: icon over a one-line name. [primary] fills it with the accent.
class _Small extends StatelessWidget {
  const _Small(
    this.icon,
    this.label,
    this.onTap, {
    this.hint,
    this.primary = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? hint;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final fg = primary ? s.onPrimary : s.onSurface;
    return Tooltip(
      message: hint ?? label,
      child: Semantics(
        button: true,
        enabled: onTap != null,
        label: hint == null ? label : '$label. $hint',
        child: Material(
          color: primary ? s.primary : s.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.tile),
            side: primary
                ? BorderSide.none
                : BorderSide(color: s.outlineVariant),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.tile),
            onTap: onTap,
            child: SizedBox(
              height: 60,
              child: ExcludeSemantics(
                child: Opacity(
                  opacity: onTap == null ? 0.45 : 1,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 19, color: fg),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: fg),
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
            if (blocker != null) ...[
              const SizedBox(height: Gap.s),
              Text(
                blocker,
                style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
              ),
            ],
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
                  border: Border.all(color: s.outlineVariant),
                ),
                child: const Icon(Symbols.folder_rounded, size: 18),
              ),
              title: Text('Archivos del ordenador', style: t.titleSmall),
              subtitle: Text(
                'Carpetas que compartiste en el PC',
                style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
              ),
              trailing: const Icon(Symbols.chevron_right_rounded),
              onTap: () => openPcFiles(context, hub, peer.id, peer.name),
            ),
          ],
        ),
      ),
    );
  }
}

/// The way into "Control remoto", as a picture of what it is: the computer's screen (its wallpaper) with a
/// pointer wandering over it. Tapping it opens the touchpad. It is a drawing, not the live screen: watching the
/// real one always starts from inside, where the computer shows its notice.
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
    duration: const Duration(seconds: 7),
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
      label: 'Control remoto de ${widget.name}: ratón y teclado',
      child: Opacity(
        opacity: on ? 1 : .55,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.tile),
          child: AspectRatio(
            aspectRatio: 16 / 7,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (paper != null)
                  Image.memory(
                    paper,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: 720,
                    excludeFromSemantics: true,
                    errorBuilder: (_, _, _) =>
                        ColoredBox(color: s.primaryContainer),
                  )
                else
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [s.primaryContainer, s.tertiaryContainer],
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
                // The pointer drifts along a slow figure of eight in the upper part.
                RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _c,
                    builder: (_, child) {
                      final a = _c.value * 2 * math.pi;
                      return Align(
                        alignment: Alignment(
                          .55 * math.sin(a),
                          -.35 + .3 * math.sin(2 * a),
                        ),
                        child: child,
                      );
                    },
                    child: const Icon(
                      Symbols.arrow_selector_tool_rounded,
                      size: 22,
                      fill: 1,
                      color: Colors.white,
                    ),
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
                              'Ratón y teclado de ${widget.name}',
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
                          icon: const Icon(Symbols.mouse_rounded, size: 18),
                          label: const FitLabel('Abrir'),
                        ),
                      ),
                    ],
                  ),
                ),
                // One touch target for the whole picture, with its ripple on top.
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(onTap: widget.onOpen),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
