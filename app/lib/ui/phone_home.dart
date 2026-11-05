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
        Wrap(
          spacing: Gap.s,
          runSpacing: Gap.s,
          children: [
            FilledButton.icon(
              onPressed: online ? () => hub.send(peer.id) : null,
              icon: const Icon(Symbols.upload_rounded, size: 18),
              label: const Text('Enviar archivos'),
            ),
            FilledButton.tonalIcon(
              onPressed: online
                  ? () => openClipboard(context, hub, peer.id)
                  : null,
              icon: const Icon(Symbols.content_paste_go_rounded, size: 18),
              label: const Text('Portapapeles'),
            ),
            OutlinedButton.icon(
              onPressed: online
                  ? () => openPcFiles(context, hub, peer.id, peer.name)
                  : null,
              icon: const Icon(Symbols.folder_open_rounded, size: 18),
              label: const Text('Archivos'),
            ),
            OutlinedButton.icon(
              onPressed: blocker == null
                  ? () => openPcControl(context, hub, peer.id, peer.name)
                  : null,
              icon: const Icon(Symbols.mouse_rounded, size: 18),
              label: const Text('Controlar'),
            ),
            OutlinedButton.icon(
              onPressed: canShot
                  ? () => openPcScreen(context, hub, peer.id, peer.name)
                  : null,
              icon: const Icon(Symbols.cast_rounded, size: 18),
              label: const Text('Pantalla'),
            ),
            OutlinedButton.icon(
              onPressed: canShot ? () => _shot(context) : null,
              icon: const Icon(Symbols.screenshot_monitor_rounded, size: 18),
              label: const Text('Captura'),
            ),
          ],
        ),
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
