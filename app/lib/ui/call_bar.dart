import 'package:flutter/material.dart' hide Icon;
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import 'expressive.dart';
import 'theme.dart';
import 'icon.dart';

/// The phone's call, floating over every screen of the computer: answer or decline while it rings, hang up
/// while talking. The voice stays on the phone (or its headset).
class CallBar extends StatelessWidget {
  const CallBar(this.hub, {super.key});
  final Hub hub;

  @override
  Widget build(BuildContext context) {
    final entry = hub.calls.entries.firstOrNull;
    return AnimatedSwitcher(
      duration: motion(context, Spring.spatial.settle),
      switchInCurve: Spring.spatial,
      transitionBuilder: (c, a) => SizeTransition(
        sizeFactor: a,
        alignment: Alignment.topCenter,
        child: FadeTransition(opacity: a, child: c),
      ),
      child: entry == null
          ? const SizedBox(key: ValueKey('none'), width: double.infinity)
          : _Card(hub, entry.key, key: ValueKey(entry.value.ringing)),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card(this.hub, this.peerId, {super.key});
  final Hub hub;
  final String peerId;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final c = hub.calls[peerId]!;
    final who = c.name.isEmpty ? 'Número desconocido' : c.name;
    return Semantics(
      liveRegion: true,
      label: c.ringing ? 'Llamada entrante de $who' : 'En llamada con $who',
      child: Container(
        margin: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, 0),
        padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
        decoration: BoxDecoration(
          color: s.tertiaryContainer,
          borderRadius: BorderRadius.circular(Radii.pill),
          boxShadow: [
            BoxShadow(
              color: s.shadow.withValues(alpha: 0.2),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              c.ringing ? Symbols.ring_volume_rounded : Symbols.call_rounded,
              fill: 1,
              color: s.onTertiaryContainer,
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      who,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleMedium?.copyWith(
                        color: s.onTertiaryContainer,
                      ),
                    ),
                    Text(
                      c.ringing
                          ? 'Llamada entrante en el teléfono'
                          : (c.text.isEmpty ? 'En llamada' : c.text),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(
                        color: s.onTertiaryContainer.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (c.ringing) ...[
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: s.error,
                  foregroundColor: s.onError,
                ),
                onPressed: () => hub.callCmd(peerId, 'decline'),
                icon: const Icon(Symbols.call_end_rounded, size: 18),
                label: const Text('Rechazar'),
              ),
              if (c.canAnswer) ...[
                const SizedBox(width: Gap.s),
                FilledButton.icon(
                  onPressed: () => hub.callCmd(peerId, 'answer'),
                  icon: const Icon(Symbols.call_rounded, size: 18),
                  label: const Text('Contestar'),
                ),
              ],
            ] else
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: s.error,
                  foregroundColor: s.onError,
                ),
                onPressed: () => hub.callCmd(peerId, 'hangup'),
                icon: const Icon(Symbols.call_end_rounded, size: 18),
                label: const Text('Colgar'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Asks the phone to call [initial] (or a number typed here).
Future<void> dialDialog(
  BuildContext context,
  Hub hub,
  String peerId, [
  String initial = '',
]) async {
  final c = TextEditingController(text: initial);
  final number = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Llamar desde el teléfono'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: c,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Número'),
            onSubmitted: (v) => Navigator.pop(d, v),
          ),
          const SizedBox(height: Gap.s),
          const Text(
            'El teléfono marca y hablas por él o por sus auriculares.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(d, c.text),
          icon: const Icon(Symbols.call_rounded, size: 18),
          label: const Text('Llamar'),
        ),
      ],
    ),
  );
  if (number != null && number.trim().isNotEmpty) {
    await hub.dial(peerId, number);
  }
}
