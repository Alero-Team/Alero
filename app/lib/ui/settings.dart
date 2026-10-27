import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../hub.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen(this.hub, {super.key});
  final Hub hub;

  /// The engine reports `local address: <ip>` among its diagnostics.
  String get _ip => hub.diagnostics
      .firstWhere((l) => l.startsWith('local address: '), orElse: () => 'local address: —')
      .substring('local address: '.length);

  Future<void> _rename(BuildContext context) async {
    final c = TextEditingController(text: hub.name);
    final n = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nombre de este dispositivo'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(labelText: 'Nombre', helperText: 'Así te verán los otros dispositivos.'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Guardar')),
        ],
      ),
    );
    if (n != null) await hub.setName(n);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pal;
    final t = Theme.of(context).textTheme;
    final muted = t.bodySmall?.copyWith(color: c.muted);
    return ScreenFrame(
      title: 'Ajustes',
      children: [
        const SectionHeader('Este dispositivo'),
        Card(
          child: Column(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
                title: const Text('Nombre'),
                subtitle: Text(hub.name, style: muted),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _rename(context),
              ),
              const Divider(indent: Gap.l, endIndent: Gap.l),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
                title: const Text('Dirección en la red'),
                subtitle: Text(_ip, style: muted),
              ),
            ],
          ),
        ),
        const SectionHeader('Recepción'),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
                title: const Text('Aceptar archivos sin preguntar'),
                subtitle: Text('Solo de dispositivos emparejados.', style: muted),
                value: hub.autoAccept,
                onChanged: hub.setAutoAccept,
              ),
              const Divider(indent: Gap.l, endIndent: Gap.l),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
                title: const Text('Carpeta de recepción'),
                subtitle: Text(hub.downloads, style: muted),
              ),
            ],
          ),
        ),
        const SectionHeader('Diagnóstico'),
        Card(
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            shape: const Border(),
            tilePadding: const EdgeInsets.symmetric(horizontal: Gap.l),
            title: const Text('Detalles técnicos'),
            subtitle: Text('Para resolver problemas de conexión.', style: muted),
            childrenPadding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                'ID: ${hub.myId}\n${hub.diagnostics.join('\n')}',
                style: t.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.6),
              ),
              const SizedBox(height: Gap.s),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: 'ID: ${hub.myId}\n${hub.diagnostics.join('\n')}'));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Diagnóstico copiado')));
                  }
                },
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Copiar'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
