import 'alero_motion.dart';

import 'package:flutter/material.dart' hide Icon, Text;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../hub.dart';
import 'notifications.dart' show ago;
import 'theme.dart';
import 'widgets.dart';
import 'icon.dart';
import '../l10n.dart';

Future<void> openClipboard(BuildContext context, Hub hub, String peerId) =>
    showModalBottomSheet<void>(
      sheetAnimationStyle: sheetMotion(context),
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
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xl),
            children: [
              Text('Portapapeles', style: t.titleLarge),
              const SizedBox(height: Gap.xs),
              Text(
                'Envía lo que copiaste en este dispositivo, o vuelve a copiar algo del historial.',
                style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
              ),
              const SizedBox(height: Gap.l),
              FilledButton.icon(
                onPressed: () => hub.sendClipboard(peerId),
                icon: const Icon(FluentIcons.clipboard_arrow_right_24_regular, size: 18),
                label: const Text('Enviar mi portapapeles'),
              ),
              const SizedBox(height: Gap.l),
              Text('Historial', style: t.titleSmall),
              const SizedBox(height: Gap.xs),
              MotionFade(
                child: hub.clips.isEmpty
                    ? Text(
                        'Aún no hay nada reciente.',
                        key: const ValueKey('empty'),
                        style: t.bodyMedium?.copyWith(
                          color: s.onSurfaceVariant,
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('has')),
              ),
              // New copies grow in at the top; the list is at most 30 long, so it is built whole.
              MotionList(
                children: [
                  for (final c in hub.clips)
                    SettingTile(
                      key: ObjectKey(c),
                      leading: Icon(
                        c.incoming
                            ? FluentIcons.arrow_down_left_24_regular
                            : FluentIcons.arrow_up_right_24_regular,
                        size: 20,
                        color: s.onSurfaceVariant,
                      ),
                      title: c.text.replaceAll('\n', ' '),
                      subtitle:
                          '${c.incoming ? 'De' : 'A'} ${c.peerName} · ${ago(c.time)}',
                      trailing: IconButton(
                        tooltip: tx('Copiar'),
                        icon: const Icon(
                          FluentIcons.copy_24_regular,
                          size: 18,
                        ),
                        onPressed: () => hub.copy(c.text),
                      ),
                      onTap: () => hub.copy(c.text),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
