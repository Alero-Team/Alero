import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import 'notifications.dart' show ago;
import 'theme.dart';
import 'widgets.dart';

/// Clipboard is an action, not a place: one button of a fixed size that opens a sheet. The sheet holds the
/// send action and the recent items, so nothing on the screen behind it changes size when the history grows
/// (the old split button gained an arrow after the first send and pushed the layout down).
class ClipboardButton extends StatelessWidget {
  const ClipboardButton(this.hub, this.peerId, {super.key, this.enabled = true});
  final Hub hub;
  final String peerId;
  final bool enabled;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: enabled ? () => openClipboard(context, hub, peerId) : null,
    icon: const Icon(Symbols.content_paste_go_rounded, size: 18),
    label: const Text('Portapapeles'),
  );
}

Future<void> openClipboard(BuildContext context, Hub hub, String peerId) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _Sheet(hub, peerId),
);

class _Sheet extends StatelessWidget {
  const _Sheet(this.hub, this.peerId);
  final Hub hub;
  final String peerId;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xl),
            children: [
              Text('Portapapeles', style: t.titleLarge),
              const SizedBox(height: Gap.xs),
              Text(
                'Envía lo que copiaste en este dispositivo, o vuelve a copiar algo reciente.',
                style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
              ),
              const SizedBox(height: Gap.l),
              FilledButton.icon(
                onPressed: () => hub.sendClipboard(peerId),
                icon: const Icon(Symbols.content_paste_go_rounded, size: 18),
                label: const Text('Enviar mi portapapeles'),
              ),
              const SizedBox(height: Gap.l),
              if (hub.clips.isEmpty)
                Text('Aún no hay nada reciente.', style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant))
              else
                for (final c in hub.clips.take(10))
                  SettingTile(
                    leading: Icon(
                      c.incoming ? Symbols.south_west_rounded : Symbols.north_east_rounded,
                      size: 20,
                      color: s.onSurfaceVariant,
                    ),
                    title: c.text.replaceAll('\n', ' '),
                    subtitle: '${c.incoming ? 'De' : 'A'} ${c.peerName} · ${ago(c.time)}',
                    trailing: IconButton(
                      tooltip: 'Copiar',
                      icon: const Icon(Symbols.content_copy_rounded, size: 18),
                      onPressed: () => hub.copy(c.text),
                    ),
                    onTap: () => hub.copy(c.text),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
