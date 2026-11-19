import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' hide Icon, Text;
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';

import '../native.dart';
import '../vault.dart';
import 'icon.dart';
import 'theme.dart';
import '../l10n.dart';
import 'expressive.dart';
import 'alero_motion.dart';
import 'controls.dart' show Presence;

/// A local vault on each device, deliberately separate from normal Alero
/// transfers. Encryption keys stay in Android Keystore or Windows DPAPI.
class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> with WidgetsBindingObserver {
  final _vault = VaultStore();
  final _key = TextEditingController(), _again = TextEditingController();
  List<VaultEntry> _items = const [];
  bool _busy = false, _loading = false;
  String? _error;

  /// Nothing is read or shown until the owner proves who they are, every time the vault is opened.
  bool _unlocked = false;

  /// Windows: null until we know whether a vault key exists yet.
  bool? _hasKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (isPhone) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
    } else {
      _vault.hasKey().then((v) {
        if (mounted) setState(() => _hasKey = v);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lock();
    _key.dispose();
    _again.dispose();
    super.dispose();
  }

  /// Leaving the app (or minimising the window) locks the vault again. Not while a picker or the
  /// fingerprint prompt of our own is on top.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_busy) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _lock();
      if (mounted) setState(() {});
    }
  }

  void _lock() {
    _vault.lock();
    _items = const [];
    _unlocked = false;
    _key.clear();
    _again.clear();
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    var ok = false;
    try {
      if (isPhone) {
        ok = await Native.authenticate();
        if (!ok) error = 'No se confirmó tu identidad.';
      } else if (_hasKey == true) {
        ok = await _vault.unlock(_key.text);
        if (!ok) error = 'Clave incorrecta.';
      } else if (_key.text != _again.text) {
        error = 'Las dos claves no coinciden.';
      } else {
        await _vault.createKey(_key.text);
        _hasKey = ok = true;
      }
    } on FormatException catch (e) {
      error = e.message;
    } catch (e) {
      // Android without a screen lock says so in its own words.
      error = e is PlatformException
          ? (e.message ?? 'No se pudo comprobar tu identidad.')
          : 'No se pudo abrir la bóveda.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _unlocked = ok;
      _error = error;
      _key.clear();
      _again.clear();
    });
    if (ok) await _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    try {
      final items = await _vault.list();
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'No se pudo descifrar la bóveda de este dispositivo. No se eliminó ningún dato.';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _act(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
      await _refresh();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is FormatException ? e.message : 'No se pudo completar la operación. Los elementos existentes permanecen cifrados.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _note([VaultEntry? existing]) async {
    final title = TextEditingController(text: existing?.name ?? '');
    final body = TextEditingController(text: existing?.data ?? '');
    try {
      final save = await showAleroDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            existing == null ? 'Nueva nota cifrada' : 'Editar nota cifrada',
          ),
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
                    decoration: InputDecoration(labelText: tx('Título')),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: body,
                    minLines: 5,
                    maxLines: 12,
                    decoration: InputDecoration(
                      labelText: tx('Contenido'),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                if (title.text.trim().isEmpty) {
                  ScaffoldMessenger.of(ctx).showToast(
                    const SnackBar(
                      content: Text('Escribe un título para guardar la nota.'),
                    ),
                  );
                  return;
                }
                Navigator.pop(ctx, true);
              },
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
            throw const FormatException(
              'Archivo demasiado grande (máximo 8 MB).',
            );
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
    final confirmed = await showAleroDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Exportar sin cifrado'),
        content: const Text(
          'El archivo exportado se guardará fuera de Alero Vault SIN cifrado. '
          'Cualquier aplicación con acceso al archivo podrá leerlo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Exportar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _act(() async {
      final filename = entry.name.replaceAll(RegExp(r'[\\/]'), '_');
      if (isPhone) {
        final root = await getApplicationSupportDirectory();
        final dir = await Directory('${root.path}/incoming')
            .create(recursive: true);
        final file = File(
          '${dir.path}/${filename.isEmpty ? 'archivo' : filename}',
        );
        await file.writeAsBytes(entry.fileBytes, flush: true);
        await Native.publish(file.path);
      } else {
        final location = await getSaveLocation(suggestedName: filename);
        if (location == null) return;
        await File(location.path).writeAsBytes(entry.fileBytes, flush: true);
      }
    });
  }

  static bool _isPicture(VaultEntry e) =>
      !e.isNote &&
      RegExp(
        r'\.(jpe?g|png|gif|webp|bmp)$',
        caseSensitive: false,
      ).hasMatch(e.name);

  /// A protected picture is looked at here, decrypted in memory only; nothing is written outside the vault.
  Future<void> _view(VaultEntry entry) => showAleroDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: InteractiveViewer(
                  maxScale: 6,
                  child: Image.memory(
                    entry.fileBytes,
                    fit: BoxFit.contain,
                    semanticLabel: entry.name,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _export(entry);
                  },
                  child: const Text('Exportar'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cerrar'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  /// What stands between anyone holding this device and the vault's contents.
  Widget _gate(ThemeData theme) {
    final android = isPhone;
    final create = !android && _hasKey == false;
    return Center(
      child: SingleChildScrollView(
        // The list takes the primary controller while this one leaves.
        primary: false,
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Symbols.lock_rounded, size: 44),
              const SizedBox(height: 16),
              MotionFade(
                child: Text(
                  create
                      ? 'Crea la clave de tu bóveda'
                      : 'Alero Vault está bloqueado',
                  key: ValueKey(create),
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 8),
              MotionFade(
                child: Text(
                  android
                      ? 'Usa tu huella o el PIN del teléfono para ver lo que guardaste.'
                      : create
                      ? 'Tus notas y archivos se cifran con esta clave y con tu cuenta de Windows. '
                            'Alero no la guarda: si la olvidas, nadie puede recuperar el contenido.'
                      : 'Escribe la clave de tu bóveda.',
                  key: ValueKey(create),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Presence(
                child: !android && _hasKey != null
                    ? Column(
                        children: [
                          TextField(
                            controller: _key,
                            obscureText: true,
                            autofocus: true,
                            enabled: !_busy,
                            decoration: InputDecoration(labelText: tx('Clave')),
                            onSubmitted: (_) => create ? null : _unlock(),
                          ),
                          Presence(
                            child: create
                                ? Padding(
                                    padding: const EdgeInsets.only(top: 10),
                                    child: TextField(
                                      controller: _again,
                                      obscureText: true,
                                      enabled: !_busy,
                                      decoration: InputDecoration(
                                        labelText: tx('Repite la clave'),
                                      ),
                                      onSubmitted: (_) => _unlock(),
                                    ),
                                  )
                                : null,
                          ),
                          const SizedBox(height: 16),
                        ],
                      )
                    : null,
              ),
              Presence(
                child: _error == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      ),
              ),
              MotionFade(
                child: _busy
                    ? const CircularProgressIndicator(key: ValueKey('busy'))
                    : android || _hasKey != null
                    ? FilledButton.icon(
                        key: ValueKey('go-$create'),
                        onPressed: _unlock,
                        icon: const Icon(Symbols.lock_open_rounded, size: 18),
                        label: Text(create ? 'Crear y abrir' : 'Desbloquear'),
                      )
                    : const SizedBox.shrink(key: ValueKey('none')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _delete(VaultEntry entry) async {
    final ok = await showAleroDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar de Alero Vault'),
        content: Text(
          tr('¿Eliminar «{}» de este dispositivo? No se puede deshacer.', [
            entry.name,
          ]),
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
          Presence(
            alignment: Alignment.centerRight,
            child: _unlocked
                ? IconButton(
                    tooltip: tx('Bloquear ahora'),
                    onPressed: _busy ? null : () => setState(_lock),
                    icon: const Icon(Symbols.lock_rounded),
                  )
                : null,
          ),
        ],
      ),
      body: SafeArea(
        child: MotionSwitch(
          axis: Axis.vertical,
          child: KeyedSubtree(
            key: ValueKey(_unlocked),
            child: !_unlocked
                ? _gate(theme)
                : ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text(
                        'Tus archivos y notas privados',
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Solo se ven tras desbloquear, y se vuelven a bloquear al salir de aquí o de Alero. '
                        'Se cifran en este dispositivo y no se sincronizan ni se comparten con el otro. '
                        'Desinstalar Alero o restablecer el sistema puede hacer imposible recuperarlos.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: color.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 12,
                        runSpacing: 10,
                        children: [
                          FilledButton.icon(
                            onPressed: _busy ? null : () => _note(),
                            icon: const Icon(Symbols.note_add_rounded),
                            label: const Text('Nueva nota'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _busy ? null : _importFiles,
                            icon: const Icon(Symbols.add_to_drive_rounded),
                            label: const Text('Proteger fotos y archivos'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Presence(
                        child: _error == null
                            ? null
                            : Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Text(
                                  _error!,
                                  style: TextStyle(color: color.error),
                                ),
                              ),
                      ),
                      Presence(
                        child: _loading || _busy
                            ? const LinearProgressIndicator()
                            : null,
                      ),
                      Presence(
                        child: !_loading && _items.isEmpty && _error == null
                            ? const Padding(
                                padding: EdgeInsets.symmetric(vertical: 32),
                                child: Center(
                                  child: Text('Tu bóveda está vacía.'),
                                ),
                              )
                            : null,
                      ),
                      MotionList(
                        children: [
                          for (final entry in _items)
                            Card(
                              key: ValueKey(entry.id),
                              child: AleroPress(
                                onTap: _busy
                                    ? null
                                    : entry.isNote
                                    ? () => _note(entry)
                                    : _isPicture(entry)
                                    ? () => _view(entry)
                                    : () => _export(entry),
                                child: ListTile(
                                  leading: _isPicture(entry)
                                      ? ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: Image.memory(
                                            entry.fileBytes,
                                            width: 44,
                                            height: 44,
                                            fit: BoxFit.cover,
                                            cacheWidth: 132,
                                            excludeFromSemantics: true,
                                            errorBuilder: (_, _, _) =>
                                                const Icon(
                                                  Symbols.image_rounded,
                                                ),
                                          ),
                                        )
                                      : Icon(
                                          entry.isNote
                                              ? Symbols.sticky_note_2_rounded
                                              : Symbols
                                                    .insert_drive_file_rounded,
                                        ),
                                  title: Text(
                                    entry.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    entry.isNote
                                        ? 'Nota cifrada'
                                        : _isPicture(entry)
                                        ? 'Foto cifrada · toca para verla'
                                        : 'Archivo cifrado · toca para exportarlo',
                                  ),
                                  trailing: IconButton(
                                    tooltip: tx('Eliminar'),
                                    icon: const Icon(
                                      Symbols.delete_outline_rounded,
                                    ),
                                    onPressed: _busy
                                        ? null
                                        : () => _delete(entry),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
