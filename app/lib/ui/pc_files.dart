import 'package:flutter/material.dart' hide Icon, Text;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../fs_client.dart';
import '../hub.dart';
import '../pc_files.dart';
import 'icon.dart';
import '../l10n.dart';
import 'expressive.dart';
import 'qollqe_motion.dart';
import 'controls.dart' show Presence;

/// Browse folders the Windows owner explicitly selected, over Alero's
/// authenticated peer channel. ADB and external servers are not involved.
Future<void> openPcFiles(
  BuildContext context,
  Hub hub,
  String peer,
  String name,
) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => PcFilesPage(hub, peer, name)));

class PcFilesPage extends StatefulWidget {
  const PcFilesPage(this.hub, this.peer, this.name, {super.key});
  final Hub hub;
  final String peer;
  final String name;

  @override
  State<PcFilesPage> createState() => _PcFilesPageState();
}

class _PcFilesPageState extends State<PcFilesPage> {
  PcFilesClient get fs => widget.hub.pcFs;
  // Entering a folder slides forward, going up slides back.
  int _depth = 0;
  bool _forward = true;

  @override
  void initState() {
    super.initState();
    fs.open(widget.peer);
  }

  @override
  void dispose() {
    fs.close();
    super.dispose();
  }

  Future<void> _rename(FsEntry entry) async {
    final controller = TextEditingController(text: entry.name);
    final name = await showAleroDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renombrar archivo de Windows'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 180,
          decoration: InputDecoration(labelText: tx('Nuevo nombre')),
          onSubmitted: (s) => Navigator.pop(ctx, s),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Renombrar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || name == entry.name) return;
    fs.rename(entry, name.trim());
  }

  Future<void> _delete(FsEntry entry) async {
    final consent = await showAleroDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar archivo del ordenador'),
        content: Text(
          tr(
            'Esta acción elimina permanentemente «{}» del ordenador. No se envía a la papelera. ¿Continuar?',
            [entry.name],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (consent == true) fs.delete(entry);
  }

  Widget _file(FsEntry entry) {
    final date = entry.mtime;
    return Card(
      child: QollqePress(
        onTap: () {
          if (entry.dir) {
            fs.enter(entry);
          } else {
            fs.download(entry);
            ScaffoldMessenger.of(context).showToast(
              const SnackBar(
                content: Text('Se solicitó el archivo al ordenador.'),
              ),
            );
          }
        },
        child: ListTile(
          leading: Icon(
            entry.dir
                ? FluentIcons.folder_24_regular
                : FluentIcons.document_24_regular,
          ),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            entry.dir
                ? 'Carpeta'
                : '${(entry.size / 1024).toStringAsFixed(1)} KB · ${L10n.instance.en ? '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}' : '${date.day}/${date.month}/${date.year}'}',
          ),
          trailing: entry.dir
              ? const Icon(FluentIcons.chevron_right_24_regular)
              : PopupMenuButton<String>(
                  popUpAnimationStyle: popUpMotion(context),
                  tooltip: tx('Opciones de archivo'),
                  onSelected: (action) {
                    switch (action) {
                      case 'download':
                        fs.download(entry);
                      case 'rename':
                        _rename(entry);
                      case 'delete':
                        _delete(entry);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'download',
                      child: Text('Descargar'),
                    ),
                    if (fs.writable) ...[
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('Renombrar'),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Eliminar permanentemente'),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (fs.root != null) ...[
        Row(
          children: [
            IconButton(
              tooltip: tx('Volver'),
              onPressed: fs.up,
              icon: const Icon(FluentIcons.arrow_left_24_regular),
            ),
            Expanded(
              child: Text(
                fs.crumbs.isEmpty
                    ? 'Carpeta compartida'
                    : fs.crumbs.map((e) => e.$1).join(' / '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (!fs.loading && fs.entries.isEmpty && fs.error == null)
          const Padding(
            padding: EdgeInsets.all(30),
            child: Center(child: Text('Carpeta vacía')),
          ),
        for (final (i, entry) in fs.entries.indexed)
          QollqeMotion.reveal(context, i, _file(entry)),
        if (fs.total > 0)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              tr('{} de {} elementos', [fs.entries.length, fs.total]),
            ),
          ),
      ] else ...[
        if (!fs.loading && fs.roots.isEmpty && fs.error == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text('No hay carpetas compartidas por el ordenador.'),
            ),
          ),
        for (final (i, root) in fs.roots.indexed)
          QollqeMotion.reveal(
            context,
            i,
            Card(
              child: QollqePress(
                onTap: () => fs.selectRoot(root.id),
                child: ListTile(
                  leading: const Icon(FluentIcons.folder_people_24_regular),
                  title: Text(root.name),
                  subtitle: const Text('Carpeta aprobada en Windows'),
                  trailing: const Icon(FluentIcons.chevron_right_24_regular),
                ),
              ),
            ),
          ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: fs,
    builder: (context, _) {
      final depth = fs.root == null ? 0 : 1 + fs.crumbs.length;
      if (depth != _depth) {
        _forward = depth > _depth;
        _depth = depth;
      }
      return _page(context);
    },
  );

  Widget _page(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr('Archivos de {}', [widget.name])),
      actions: [
        IconButton(
          tooltip: tx('Actualizar'),
          onPressed: () => fs.root == null ? fs.open(widget.peer) : fs.list(),
          icon: const Icon(FluentIcons.arrow_clockwise_24_regular),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(
            'Acceso por red local a las carpetas autorizadas en Alero para Windows. '
            'Solo los dispositivos emparejados pueden abrirlas. '
            'Para añadir o quitar carpetas, utiliza Ajustes en el ordenador.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Presence(child: fs.loading ? const LinearProgressIndicator() : null),
          Presence(
            child: fs.error == null
                ? null
                : Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      fs.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
          ),
          MotionSwitch(
            forward: _forward,
            child: KeyedSubtree(
              key: ValueKey(
                '${fs.root}|${fs.crumbs.map((e) => e.$1).join('/')}|${fs.entries.isEmpty}|${fs.roots.isEmpty}',
              ),
              child: _content(context),
            ),
          ),
          Presence(
            child: fs.writable
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'El propietario de Windows ha permitido también renombrar y eliminar archivos.',
                    ),
                  )
                : null,
          ),
        ],
      ),
    ),
  );
}
