import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

class TransfersScreen extends StatelessWidget {
  const TransfersScreen(this.hub, {super.key});
  final Hub hub;

  @override
  Widget build(BuildContext context) {
    final history = hub.history.take(200).toList();
    return ScreenFrame(
      title: 'Archivos',
      onRefresh: hub.refresh,
      trailing: FilledButton.tonalIcon(
        onPressed: hub.openDownloads,
        icon: const Icon(Symbols.folder_open_rounded, size: 18),
        label: const Text('Abrir carpeta'),
      ),
      children: [
        if (hub.active.isNotEmpty) ...[
          Panel(
            title: 'En curso',
            icon: Symbols.sync_rounded,
            child: Column(children: [for (final x in hub.active) TransferRow(x, hub)]),
          ),
          const SizedBox(height: Gap.l),
        ],
        Panel(
          title: 'Historial',
          icon: Symbols.history_rounded,
          action: history.isEmpty
              ? null
              : TextButton(
                  onPressed: () async {
                    final ok = await confirm(
                      context,
                      '¿Borrar el historial?',
                      'Se quita la lista de transferencias. Los archivos recibidos no se borran.',
                      'Borrar',
                    );
                    if (ok) await hub.clearHistory();
                  },
                  child: const Text('Borrar'),
                ),
          child: history.isEmpty
              ? EmptyState(
                  card: false,
                  icon: Symbols.folder_rounded,
                  title: 'Sin transferencias todavía',
                  body: Platform.isAndroid
                      ? 'Envía un archivo desde Inicio o compártelo desde cualquier app.'
                      : 'Envía un archivo desde Inicio o suéltalo sobre esta ventana.',
                )
              : Column(children: [for (final h in history) HistoryTile(h, hub)]),
        ),
        const SizedBox(height: Gap.m),
        Text(
          'Los archivos recibidos se guardan en ${hub.downloads}.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.pal.muted),
        ),
      ],
    );
  }
}
