import 'package:flutter/material.dart';

import '../hub.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

class TransfersScreen extends StatelessWidget {
  const TransfersScreen(this.hub, {super.key});
  final Hub hub;

  @override
  Widget build(BuildContext context) {
    final c = context.pal;
    final history = hub.history.reversed.take(200).toList();
    return ScreenFrame(
      title: 'Transferencias',
      onRefresh: hub.refresh,
      children: [
        const SectionHeader('En curso'),
        if (hub.active.isEmpty)
          Text('Nada en curso.', style: TextStyle(color: c.muted))
        else
          for (final x in hub.active)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.s),
              child: TransferCard(x, hub),
            ),
        SectionHeader(
          'Historial',
          action: history.isEmpty ? null : 'Borrar historial',
          onAction: () async {
            final ok = await confirm(
              context,
              '¿Borrar el historial?',
              'Se quita la lista de transferencias. Los archivos recibidos no se borran.',
              'Borrar',
            );
            if (ok) await hub.clearHistory();
          },
        ),
        if (history.isEmpty)
          const EmptyState(
            icon: Icons.swap_vert,
            title: 'Sin transferencias todavía',
            body: 'Envía un archivo desde Inicio o desde el otro dispositivo.',
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
              child: Column(
                children: [
                  for (final (i, h) in history.indexed) ...[if (i > 0) const Divider(), HistoryTile(h, hub)],
                ],
              ),
            ),
          ),
        const SizedBox(height: Gap.l),
        Text('Los archivos recibidos se guardan en ${hub.downloads}.', style: TextStyle(color: c.muted)),
      ],
    );
  }
}
