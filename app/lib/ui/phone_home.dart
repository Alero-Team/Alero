import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'clipboard.dart';
import 'pc_control.dart';
import 'pc_files.dart';
import 'pc_screen.dart';
import 'remote_ui.dart';
import 'theme.dart';

/// Everything you do with a connected computer, one tap each, inside the device card: send, clipboard,
/// screenshot, remote screen, control and its files. Fixed-size tiles, so nothing below moves.
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
    final blocker = remoteBlocker(info, online);
    final needsRemote = online && blocker != null ? blocker : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ShortcutGrid([
          ShortcutTile(
            Symbols.upload_rounded,
            'Enviar',
            online ? () => hub.send(peer.id) : null,
          ),
          ShortcutTile(
            Symbols.content_paste_go_rounded,
            'Portapapeles',
            online ? () => openClipboard(context, hub, peer.id) : null,
          ),
          ShortcutTile(
            Symbols.folder_open_rounded,
            'Archivos',
            online ? () => openPcFiles(context, hub, peer.id, peer.name) : null,
          ),
          ShortcutTile(
            Symbols.mouse_rounded,
            'Controlar',
            blocker == null
                ? () => openPcControl(context, hub, peer.id, peer.name)
                : null,
            hint: needsRemote,
          ),
          ShortcutTile(
            Symbols.cast_rounded,
            'Pantalla',
            canShot
                ? () => openPcScreen(context, hub, peer.id, peer.name)
                : null,
            hint: online && !canShot ? 'Requiere control remoto' : null,
          ),
          ShortcutTile(
            Symbols.screenshot_monitor_rounded,
            'Captura',
            canShot ? () => _shot(context) : null,
            hint: online && !canShot ? 'Requiere control remoto' : null,
          ),
        ]),
        if (needsRemote != null) ...[
          const SizedBox(height: Gap.s),
          Text(
            needsRemote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  void _shot(BuildContext context) {
    hub.remote.shot(peer.id);
    hub.messages.add('Pidiendo la captura a ${peer.name}…');
  }
}

/// Shortcut tiles in equal columns: 3 on a phone, up to 6 on a wide card.
class ShortcutGrid extends StatelessWidget {
  const ShortcutGrid(this.tiles, {super.key});
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final cols = (box.maxWidth / 104).floor().clamp(3, 6);
      final w = (box.maxWidth - Gap.s * (cols - 1)) / cols;
      return Wrap(
        spacing: Gap.s,
        runSpacing: Gap.s,
        children: [for (final t in tiles) SizedBox(width: w, child: t)],
      );
    },
  );
}

class ShortcutTile extends StatelessWidget {
  const ShortcutTile(this.icon, this.label, this.onTap, {super.key, this.hint});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final on = onTap != null;
    return Semantics(
      button: true,
      enabled: on,
      label: hint == null ? label : '$label. $hint',
      child: Material(
        color: s.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.tile),
          side: BorderSide(color: s.outlineVariant),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.tile),
          onTap: onTap,
          child: SizedBox(
            height: 60,
            child: ExcludeSemantics(
              child: Opacity(
                opacity: on ? 1 : 0.45,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 18, color: s.onSurface),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      style: t.labelSmall?.copyWith(color: s.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
