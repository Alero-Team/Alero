import 'package:flutter/material.dart';

import '../fs_client.dart';
import '../hub.dart';
import '../pc_files.dart';

/// Browse folders the Windows owner explicitly selected, over Alero's
/// authenticated peer channel. ADB and external servers are not involved.
Future<void> openPcFiles(
  BuildContext context,
  Hub hub,
  String peer,
  String name,
) => Navigator.of(context).push(MaterialPageRoute<void>(
  builder: (_) => PcFilesPage(hub, peer, name),
));

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
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renombrar archivo de Windows'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 180,
          decoration: const InputDecoration(labelText: 'Nuevo nombre'),
          onSubmitted: (s) => Navigator.pop(ctx, s),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
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
    final consent = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar archivo del ordenador'),
        content: Text('Esta acción elimina permanentemente «' + entry.name +
            '» del ordenador. No se envía a la papelera. ¿Continuar?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (consent == true) fs.delete(entry);
  }

  Widget _file(FsEntry entry) {
    final date = entry.mtime;
    return Card(
      child: ListTile(
        leading: Icon(entry.dir ? Icons.folder_rounded : Icons.insert_drive_file_rounded),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(entry.dir
            ? 'Carpeta'
            : (entry.size / 1024).toStringAsFixed(1) + ' KB · ' +
              date.day.toString() + '/' + date.month.toString() + '/' + date.year.toString()),
        onTap: () {
          if (entry.dir) {
            fs.enter(entry);
          } else {
            fs.download(entry);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Se solicitó el archivo al ordenador.')),
            );
          }
        },
        trailing: entry.dir
            ? const Icon(Icons.chevron_right_rounded)
            : PopupMenuButton<String>(
                tooltip: 'Opciones de archivo',
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
                  const PopupMenuItem(value: 'download', child: Text('Descargar')),
                  if (fs.writable) ...[
                    const PopupMenuItem(value: 'rename', child: Text('Renombrar')),
                    const PopupMenuItem(value: 'delete', child: Text('Eliminar permanentemente')),
                  ],
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: fs,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text('Archivos de ' + widget.name),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: () => fs.root == null ? fs.open(widget.peer) : fs.list(),
            icon: const Icon(Icons.refresh_rounded),
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
            if (fs.loading) const LinearProgressIndicator(),
            if (fs.error != null)
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(fs.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (fs.root != null) ...[
              Row(
                children: [
                  IconButton(
                    tooltip: 'Volver',
                    onPressed: fs.up,
                    icon: const Icon(Icons.arrow_back_rounded),
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
              for (final entry in fs.entries) _file(entry),
              if (fs.total > 0)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(fs.entries.length.toString() + ' de ' + fs.total.toString() + ' elementos'),
                ),
            ] else ...[
              if (!fs.loading && fs.roots.isEmpty && fs.error == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No hay carpetas compartidas por el ordenador.')),
                ),
              for (final root in fs.roots)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder_shared_rounded),
                    title: Text(root.name),
                    subtitle: const Text('Carpeta aprobada en Windows'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => fs.selectRoot(root.id),
                  ),
                ),
            ],
            if (fs.writable)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('El propietario de Windows ha permitido también renombrar y eliminar archivos.'),
              ),
          ],
        ),
      ),
    ),
  );
}
