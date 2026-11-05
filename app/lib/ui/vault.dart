import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../native.dart';
import '../vault.dart';

/// A local vault on each device, deliberately separate from normal Alero
/// transfers. Encryption keys stay in Android Keystore or Windows DPAPI.
class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final _vault = VaultStore();
  List<VaultEntry> _items = const [];
  bool _busy = false, _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _items = const [];
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    try {
      final items = await _vault.list();
      if (mounted) setState(() { _items = items; _error = null; });
    } catch (_) {
      if (mounted) setState(() {
        _error = 'No se pudo descifrar la bóveda de este dispositivo. No se eliminó ningún dato.';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _act(Future<void> Function() work) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await work();
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = e is FormatException
          ? e.message
          : 'No se pudo completar la operación. Los elementos existentes permanecen cifrados.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _note([VaultEntry? existing]) async {
    final title = TextEditingController(text: existing?.name ?? '');
    final body = TextEditingController(text: existing?.data ?? '');
    try {
      final save = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(existing == null ? 'Nueva nota cifrada' : 'Editar nota cifrada'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    maxLength: 180,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Título'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: body,
                    minLines: 5,
                    maxLines: 12,
                    decoration: const InputDecoration(
                      labelText: 'Contenido',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () => title.text.trim().isEmpty
                  ? null
                  : Navigator.pop(ctx, true),
              child: const Text('Guardar cifrada'),
            ),
          ],
        ),
      );
      if (save == true) {
        await _act(() async {
          await _vault.saveNote(title.text, body.text, existing: existing);
        });
      }
    } finally {
      title.dispose();
      body.dispose();
    }
  }

  Future<void> _importFiles() => _act(() async {
    final picked = await Native.pickFiles();
    for (final item in picked) {
      Uint8List bytes;
      try {
        if (item.fd case final int fd) {
          bytes = await Native.readVaultPicked(fd);
        } else {
          final file = File(item.path);
          if (await file.length() > VaultStore.maxFileBytes) {
            throw const FormatException('Archivo demasiado grande (máximo 8 MB).');
          }
          bytes = await file.readAsBytes();
        }
      } finally {
        if (item.fd case final int fd) Native.closeFd(fd);
      }
      await _vault.saveFile(
        item.name ?? item.path.split(Platform.pathSeparator).last,
        bytes,
      );
    }
  });

  Future<void> _export(VaultEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Exportar sin cifrado'),
        content: const Text(
          'El archivo exportado se guardará fuera de Alero Vault SIN cifrado. '
          'Cualquier aplicación con acceso al archivo podrá leerlo.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Exportar')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _act(() async {
      final filename = entry.name.replaceAll(RegExp(r'[\\/]'), '_');
      if (Platform.isAndroid) {
        final root = await getApplicationSupportDirectory();
        final dir = await Directory(root.path + '/incoming').create(recursive: true);
        final file = File(dir.path + '/' + (filename.isEmpty ? 'archivo' : filename));
        await file.writeAsBytes(entry.fileBytes, flush: true);
        await Native.publish(file.path);
      } else {
        final location = await getSaveLocation(suggestedName: filename);
        if (location == null) return;
        await File(location.path).writeAsBytes(entry.fileBytes, flush: true);
      }
    });
  }

  Future<void> _delete(VaultEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar de Alero Vault'),
        content: Text('¿Eliminar «' + entry.name + '» de este dispositivo? No se puede deshacer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok == true) await _act(() => _vault.remove(entry));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alero Vault'),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Tus archivos y notas privados', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Cifrados en este dispositivo: Android Keystore o Windows DPAPI. '
              'La bóveda no se sincroniza ni se comparte con el ordenador. '
              'Conserva el acceso al perfil de este dispositivo; desinstalar '
              'Alero o restablecer el sistema puede hacer imposible recuperar los datos.',
              style: theme.textTheme.bodyMedium?.copyWith(color: color.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : () => _note(),
                  icon: const Icon(Icons.note_add_rounded),
                  label: const Text('Nueva nota'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _importFiles,
                  icon: const Icon(Icons.add_to_drive_rounded),
                  label: const Text('Proteger archivos'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_error!, style: TextStyle(color: color.error)),
              ),
            if (_loading || _busy) const LinearProgressIndicator(),
            if (!_loading && _items.isEmpty && _error == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: Text('Tu bóveda está vacía.')),
              ),
            for (final entry in _items)
              Card(
                child: ListTile(
                  leading: Icon(entry.isNote ? Icons.lock_rounded : Icons.insert_drive_file_rounded),
                  title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(entry.isNote ? 'Nota cifrada' : 'Archivo cifrado · hasta 8 MB'),
                  onTap: _busy
                      ? null
                      : entry.isNote
                          ? () => _note(entry)
                          : () => _export(entry),
                  trailing: IconButton(
                    tooltip: 'Eliminar',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: _busy ? null : () => _delete(entry),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
