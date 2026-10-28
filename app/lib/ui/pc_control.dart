import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'pc_screen.dart';
import 'remote_ui.dart';
import 'theme.dart';

/// Full-screen remote for a paired computer: a large touch area (the gestures of [Touchpad]), a scroll strip,
/// both clicks and the keyboard. Volume/playback and the screen view are one tap away. Back returns to Home.
Future<void> openPcControl(BuildContext context, Hub hub, String peer, String name) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PcControlPage(hub, peer, name)));

class PcControlPage extends StatelessWidget {
  const PcControlPage(this.hub, this.peer, this.name, {super.key});
  final Hub hub;
  final String peer, name;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final online = hub.peers.any((p) => p.id == peer && p.state == pb.PeerState.connected);
        final info = hub.info[peer];
        final blocker = remoteBlocker(info, online);
        return Scaffold(
          appBar: AppBar(
            title: Text(name),
            actions: blocker != null
                ? null
                : [
                    if (info?.canScreen ?? false)
                      IconButton(
                        tooltip: 'Ver pantalla',
                        icon: const Icon(Symbols.cast_rounded),
                        onPressed: () => openPcScreen(context, hub, peer, name),
                      ),
                    IconButton(
                      tooltip: 'Volumen y reproducción',
                      icon: const Icon(Symbols.volume_up_rounded),
                      onPressed: () => showModalBottomSheet<void>(
                        context: context,
                        showDragHandle: true,
                        builder: (_) => Padding(
                          padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xl),
                          child: PcMediaControls(hub, peer),
                        ),
                      ),
                    ),
                  ],
          ),
          body: SafeArea(
            child: blocker != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.xxl),
                      child: Text(blocker, textAlign: TextAlign.center, style: t.bodyLarge?.copyWith(color: s.onSurfaceVariant)),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(Gap.m),
                    child: Column(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (_, box) => Touchpad(hub, peer, height: box.maxHeight, gain: 2.4),
                                ),
                              ),
                              const SizedBox(width: Gap.s),
                              _ScrollStrip(hub, peer),
                            ],
                          ),
                        ),
                        const SizedBox(height: Gap.m),
                        Row(
                          children: [
                            Expanded(child: _Big('Clic izquierdo', Symbols.mouse_rounded, () => hub.remote.click(peer))),
                            const SizedBox(width: Gap.s),
                            Expanded(child: _Big('Clic derecho', Symbols.right_click_rounded, () => hub.remote.click(peer, button: 'right'))),
                            const SizedBox(width: Gap.s),
                            Expanded(child: _Big('Teclado', Symbols.keyboard_rounded, () => openKeyboard(context, hub, peer))),
                          ],
                        ),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _Big extends StatelessWidget {
  const _Big(this.label, this.icon, this.onTap);
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FilledButton.tonal(
    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64), padding: const EdgeInsets.symmetric(horizontal: Gap.s)),
    onPressed: () {
      HapticFeedback.selectionClick();
      onTap();
    },
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [Icon(icon, size: 22), const SizedBox(height: 2), Text(label, style: Theme.of(context).textTheme.labelMedium, maxLines: 1)],
    ),
  );
}

/// Drag up or down along the edge to scroll the computer's window (same direction as the finger).
class _ScrollStrip extends StatelessWidget {
  const _ScrollStrip(this.hub, this.peer);
  final Hub hub;
  final String peer;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Franja de desplazamiento. Desliza arriba o abajo.',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => hub.remote.scroll(peer, dy: d.delta.dy / 30),
        child: Container(
          width: 56,
          decoration: BoxDecoration(
            color: s.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.tile + 4),
            border: Border.all(color: s.outlineVariant),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(padding: const EdgeInsets.only(top: Gap.m), child: Icon(Symbols.keyboard_arrow_up_rounded, color: s.onSurfaceVariant)),
              Icon(Symbols.swap_vert_rounded, color: s.onSurfaceVariant),
              Padding(padding: const EdgeInsets.only(bottom: Gap.m), child: Icon(Symbols.keyboard_arrow_down_rounded, color: s.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
