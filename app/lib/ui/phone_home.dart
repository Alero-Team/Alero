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
        padding: const EdgeInsets.fromLTRB(Gap.l + 4, Gap.l, Gap.l + 4, Gap.s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Symbols.mouse_rounded,
                  size: 20,
                  color: s.onSurfaceVariant,
                ),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text('Control remoto', style: t.titleMedium),
                      ),
                      Text(
                        peer.name,
                        style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.m),
            FilledButton.icon(
              onPressed: blocker == null
                  ? () => openPcControl(context, hub, peer.id, peer.name)
                  : null,
              icon: const Icon(Symbols.mouse_rounded, size: 18),
              label: const Text('Ratón y teclado'),
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
