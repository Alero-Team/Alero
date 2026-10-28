import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'clipboard.dart';
import 'pc_control.dart';
import 'pc_screen.dart';
import 'remote_ui.dart';
import 'theme.dart';
import 'widgets.dart';

/// Four things you do all day with a connected computer, one tap each. Fixed-size tiles: the row never changes
/// height, so nothing below it moves.
class QuickActions extends StatelessWidget {
  const QuickActions(this.hub, this.peer, {super.key});
  final Hub hub;
  final pb.Peer peer;

  @override
  Widget build(BuildContext context) {
    final online = peer.state == pb.PeerState.connected;
    final info = hub.info[peer.id];
    final canShot = online && info != null && info.remoteAllowed && info.canScreen;
    return Row(
      children: [
        Expanded(
          child: _Tile(Symbols.upload_rounded, 'Enviar', online ? () => hub.send(peer.id) : null),
        ),
        const SizedBox(width: Gap.s),
        Expanded(
          child: _Tile(Symbols.content_paste_go_rounded, 'Portapapeles', online ? () => openClipboard(context, hub, peer.id) : null),
        ),
        const SizedBox(width: Gap.s),
        Expanded(
          child: _Tile(
            Symbols.screenshot_monitor_rounded,
            'Captura',
            canShot ? () => _shot(context) : null,
            hint: online && !canShot ? 'Requiere control remoto' : null,
          ),
        ),
        const SizedBox(width: Gap.s),
        Expanded(
          child: _Tile(
            Symbols.cast_rounded,
            'Pantalla',
            canShot ? () => openPcScreen(context, hub, peer.id, peer.name) : null,
            hint: online && !canShot ? 'Requiere control remoto' : null,
          ),
        ),
      ],
    );
  }

  void _shot(BuildContext context) {
    hub.remote.shot(peer.id);
    hub.messages.add('Pidiendo la captura a ${peer.name}…');
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.icon, this.label, this.onTap, {this.hint});
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
        color: s.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.tile + 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.tile + 4),
          onTap: onTap,
          child: SizedBox(
            height: 84,
            child: ExcludeSemantics(
              child: Opacity(
                opacity: on ? 1 : 0.45,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: s.secondaryContainer, borderRadius: BorderRadius.circular(Radii.pill)),
                      child: Icon(icon, size: 22, color: s.onSecondaryContainer),
                    ),
                    const SizedBox(height: 6),
                    Text(label, style: t.labelMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
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

/// Entry to the remote (touchpad, clicks, keyboard) on its own screen. When the computer has not allowed
/// control (its owner decides, in its own Settings) the card says so instead of showing dead buttons.
class ControlCard extends StatelessWidget {
  const ControlCard(this.hub, this.peer, {super.key});
  final Hub hub;
  final pb.Peer peer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final online = peer.state == pb.PeerState.connected;
    final info = hub.info[peer.id];
    final blocker = remoteBlocker(info, online);
    return Panel(
      title: 'Controlar ${peer.name}',
      icon: Symbols.mouse_rounded,
      child: blocker != null
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.s),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(online ? Symbols.lock_rounded : Symbols.link_off_rounded, size: 20, color: s.onSurfaceVariant),
                  const SizedBox(width: Gap.m),
                  Expanded(child: Text(blocker, style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant))),
                ],
              ),
            )
          : FilledButton.icon(
              onPressed: () => openPcControl(context, hub, peer.id, peer.name),
              icon: const Icon(Symbols.mouse_rounded, size: 20),
              label: const Text('Controlar'),
            ),
    );
  }
}
