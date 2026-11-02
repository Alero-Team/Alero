import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../desktop_workspace.dart';
import '../phone_control.dart';
import '../scrcpy.dart';
import 'theme.dart';
import 'widgets.dart';

/// Desktop tools inspired by Dextop's catalog, layouts, workspaces and HUD.
/// All actions use the user's already-authorized adb connection. No root or
/// hidden Android system-service access is granted by this screen.
class DesktopWorkshopPage extends StatefulWidget {
  const DesktopWorkshopPage({super.key, required this.serial});
  final String serial;

  @override
  State<DesktopWorkshopPage> createState() => _DesktopWorkshopPageState();
}

class _DesktopWorkshopPageState extends State<DesktopWorkshopPage> {
  List<String> _apps = [];
  List<DesktopDisplay> _displays = [const DesktopDisplay(0, 'Pantalla principal')];
  List<DesktopWorkspace> _workspaces = [];
  final _selected = <String>{};
  final _search = TextEditingController();
  final _name = TextEditingController();
  int _display = 0;
  DesktopLayout _layout = DesktopLayout.floating;
  DesktopDiagnostics? _diagnostics;
  Desktop _desktopSupport = Desktop.unsupported;
  String _manufacturer = 'Sin identificar';
  bool _busy = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<File> _workspaceFile() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}alero-workspaces.json');
  }

  Future<void> _readWorkspaces() async {
    final file = await _workspaceFile();
    if (!await file.exists()) return;
    final data = DesktopWorkspace.importAll(await file.readAsString());
    if (mounted) setState(() => _workspaces = data);
  }

  Future<void> _saveWorkspaces() async {
    final file = await _workspaceFile();
    await file.writeAsString(DesktopWorkspace.exportAll(_workspaces), flush: true);
  }

  Future<void> _load() async {
    await _run('Leyendo aplicaciones y pantallas…', () async {
      await _readWorkspaces();
      final apps = await Scrcpy.installedApps(widget.serial);
      List<DesktopDisplay> displays;
      try {
        displays = await Scrcpy.displays(widget.serial);
      } catch (_) {
        displays = [const DesktopDisplay(0, 'Pantalla principal')];
      }
      Desktop desktop = Desktop.unsupported;
      String manufacturer = 'Sin identificar';
      try {
        desktop = await Scrcpy.desktop(widget.serial);
        manufacturer = await Scrcpy.shell(
          widget.serial, 'getprop ro.product.manufacturer');
      } catch (_) {
        // Some OEM builds restrict capability queries: default to unsupported.
      }
      if (!mounted) return;
      setState(() {
        _desktopSupport = desktop;
        _manufacturer = manufacturer.trim().isEmpty
          ? 'Sin identificar' : manufacturer.trim();
        _apps = apps;
        _displays = displays;
        if (!_displays.any((d) => d.id == _display)) _display = 0;
        _selected.removeWhere((p) => !apps.contains(p));
      });
    });
  }

  Future<void> _run(String title, Future<void> Function() task) async {
    if (_busy) return;
    setState(() { _busy = true; _message = title; });
    try {
      await task();
      if (mounted) setState(() => _message = 'Operación finalizada.');
    } catch (e) {
      if (mounted) setState(() => _message = 'No se pudo completar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirmar en Android'),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continuar')),
          ],
        ),
      ) ?? false;

  Future<void> _launch(String package) async {
    if (!await _confirm(
      _display == 0
          ? 'Se abrirá $package en la pantalla del teléfono. ¿Continuar?'
          : 'Se intentará abrir $package en la pantalla $_display. Android puede rechazar las ventanas libres.',
    )) {
      return;
    }
    await _run('Abriendo $package…', () async {
      if (_display > 0) {
        // Verified: throws if Android put it on the phone instead.
        await Scrcpy.launchDesktopApp(widget.serial, package, _display, freeform: true);
        return;
      }
      final out = await Scrcpy.launchApp(widget.serial, package);
      if (out.contains('Error:') || out.contains('Exception:')) {
        throw StateError(out);
      }
    });
  }

  Future<void> _store() async {
    final name = _name.text.trim();
    if (name.isEmpty || _selected.isEmpty) {
      setState(() => _message = 'Escribe un nombre y selecciona aplicaciones.');
      return;
    }
    if (_workspaces.length >= 32) {
      setState(() => _message = 'Máximo 32 espacios de trabajo.');
      return;
    }
    if (_selected.length > 12) {
      setState(() => _message = 'Máximo 12 aplicaciones por espacio.');
      return;
    }
    await _run('Guardando espacio…', () async {
      final preset = DesktopWorkspace(name: name,
        packages: _selected.toList(), layout: _layout, displayId: _display);
      setState(() => _workspaces = [..._workspaces, preset]);
      await _saveWorkspaces();
      _name.clear();
    });
  }

  Future<void> _restore(DesktopWorkspace preset) async {
    if (!await _confirm(
      'Se intentarán abrir ${preset.packages.length} aplicaciones en la '
      'pantalla $_display. Los tamaños y posiciones exactas dependen del '
      'modo de ventanas libres admitido por Android. ¿Continuar?',
    )) {
      return;
    }
    await _run('Restaurando aplicaciones…', () async {
      final errors = <String>[];
      for (final package in preset.packages) {
        try {
          if (_display > 0) {
            await Scrcpy.launchDesktopApp(widget.serial, package, _display, freeform: true);
            continue;
          }
          final result = await Scrcpy.launchApp(widget.serial, package);
          if (result.contains('Error:') || result.contains('Exception:')) {
            errors.add(package);
          }
        } catch (_) {
          errors.add(package);
        }
      }
      if (errors.isNotEmpty) {
        throw StateError('Android no abrió: ${errors.join(', ')}');
      }
      if (_display > 0 && preset.layout != DesktopLayout.floating) {
        final display = _displays.where((d) => d.id == _display).firstOrNull;
        if (display == null) {
          throw StateError('Apps abiertas, pero la pantalla ya no está disponible.');
        }
        // The external display may take a moment to register the new tasks.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        try {
          await Scrcpy.arrangeWindows(
            widget.serial, display, preset.packages, preset.layout,
          );
        } catch (e) {
          throw StateError('Apps abiertas, pero Android no permitió '
            'colocar las ventanas: $e');
        }
      }
    });
  }

  Future<void> _import() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Importar espacios JSON'),
        content: SizedBox(width: 520, child: TextField(
          controller: controller, maxLines: 9,
          decoration: const InputDecoration(hintText: 'Pega los espacios exportados'),
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Importar')),
        ],
      ),
    );
    controller.dispose();
    if (raw == null) return;
    await _run('Importando espacios…', () async {
      final entries = DesktopWorkspace.importAll(raw);
      setState(() => _workspaces = entries);
      await _saveWorkspaces();
    });
  }

  Future<void> _readDiagnostics() async {
    await _run('Leyendo batería y memoria…', () async {
      final value = await Scrcpy.diagnostics(widget.serial);
      if (mounted) setState(() => _diagnostics = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final filtered = _apps.where((p) => p.toLowerCase().contains(
      _search.text.trim().toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Escritorio y aplicaciones')),
      body: ListView(
        padding: const EdgeInsets.all(Gap.l),
        children: [
          Panel(
            title: 'Pantallas de Android',
            icon: Icons.desktop_windows_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Selecciona una pantalla detectada para abrir aplicaciones. '
                  'Para crear una pantalla virtual primero utiliza «Abrir escritorio» '
                  'en el control del teléfono.', style: TextStyle(color: muted)),
                const SizedBox(height: Gap.s),
                DropdownButton<int>(
                  isExpanded: true, value: _displays.any((d) => d.id == _display)
                    ? _display : _displays.first.id,
                  items: [
                    for (final d in _displays)
                      DropdownMenuItem(value: d.id,
                        child: Text(d.description, maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: _busy ? null : (id) => setState(() => _display = id ?? 0),
                ),
                Wrap(spacing: Gap.s, children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _load,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Actualizar'),
                  ),
                ]),
              ],
            ),
          ),
          const SizedBox(height: Gap.m),
          Panel(
            title: 'Compatibilidad del dispositivo',
            icon: Icons.fact_check_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Fabricante: $_manufacturer'),
                Text('Pantallas detectadas: ${_displays.length}'),
                Text(switch (_desktopSupport) {
                  Desktop.ready => 'Ventanas libres: Android declara soporte y tiene el modo escritorio habilitado.',
                  Desktop.needsSetting => 'Ventanas libres: disponible, requiere habilitar modo escritorio en el teléfono.',
                  Desktop.unsupported => 'Ventanas libres: no confirmadas por Android. Se utiliza la pantalla normal.',
                }),
                const SizedBox(height: Gap.s),
                Text('La compatibilidad real varía por Android y fabricante. '
                  'Alero no modifica ajustes de desarrollador ni invoca APIs ocultas.',
                  style: TextStyle(color: muted)),
              ],
            ),
          ),
          const SizedBox(height: Gap.m),
          Panel(
            title: 'Aplicaciones del teléfono',
            icon: Icons.apps_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Catálogo de paquetes de usuario leído directamente '
                  'desde Android. Algunas aplicaciones no tienen pantalla principal.',
                  style: TextStyle(color: muted)),
                const SizedBox(height: Gap.s),
                TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Buscar aplicación por paquete',
                  ),
                ),
                const SizedBox(height: Gap.s),
                SizedBox(
                  height: 240,
                  child: ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) {
                      final app = filtered[i];
                      return CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _selected.contains(app),
                        title: Text(app, maxLines: 1, overflow: TextOverflow.ellipsis),
                        secondary: IconButton(
                          tooltip: 'Abrir $app',
                          icon: const Icon(Icons.open_in_new_rounded),
                          onPressed: _busy ? null : () => _launch(app),
                        ),
                        onChanged: _busy ? null : (v) => setState(() {
                          if (v == true) { _selected.add(app); }
                          else { _selected.remove(app); }
                        }),
                      );
                    },
                  ),
                ),
                Text('${_selected.length} seleccionadas',
                  style: TextStyle(color: muted)),
              ],
            ),
          ),
          const SizedBox(height: Gap.m),
          Panel(
            title: 'Espacios de trabajo',
            icon: Icons.dashboard_customize_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Inspirado en los espacios y distribuciones de Dextop. '
                  'Guarda grupos de aplicaciones y solicita su ubicación en '
                  'dos, tres o cuatro ventanas, si Android permite cambiar '
                  'los límites de sus tareas. Sin ajustes globales ni root.',
                  style: TextStyle(color: muted)),
                const SizedBox(height: Gap.s),
                TextField(controller: _name,
                  maxLength: 72,
                  decoration: const InputDecoration(hintText: 'Nombre del espacio')),
                DropdownButton<DesktopLayout>(
                  isExpanded: true,
                  value: _layout,
                  items: const [
                    DropdownMenuItem(value: DesktopLayout.floating,
                      child: Text('Ventanas libres')),
                    DropdownMenuItem(value: DesktopLayout.halves,
                      child: Text('Dos ventanas (experimental)')),
                    DropdownMenuItem(value: DesktopLayout.thirds,
                      child: Text('Tres ventanas (experimental)')),
                    DropdownMenuItem(value: DesktopLayout.quarters,
                      child: Text('Cuatro ventanas (experimental)')),
                  ],
                  onChanged: (v) => setState(() => _layout = v ?? _layout),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : _store,
                  icon: const Icon(Icons.bookmark_add_rounded),
                  label: const Text('Guardar aplicaciones seleccionadas'),
                ),
                const SizedBox(height: Gap.s),
                for (final (index, preset) in _workspaces.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(preset.name),
                    subtitle: Text('${preset.packages.length} apps · ${preset.layout.name}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'Restaurar',
                        onPressed: _busy ? null : () => _restore(preset),
                        icon: const Icon(Icons.play_arrow_rounded),
                      ),
                      IconButton(
                        tooltip: 'Borrar',
                        onPressed: _busy ? null : () => _run('Borrando…', () async {
                          setState(() => _workspaces.removeAt(index));
                          await _saveWorkspaces();
                        }),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ]),
                  ),
                Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () async {
                      await Clipboard.setData(ClipboardData(
                        text: DesktopWorkspace.exportAll(_workspaces)));
                      if (mounted) setState(() => _message = 'JSON copiado al portapapeles.');
                    },
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Exportar JSON'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.file_open_rounded),
                    label: const Text('Importar JSON'),
                  ),
                ]),
              ],
            ),
          ),
          const SizedBox(height: Gap.m),
          Panel(
            title: 'Diagnóstico en vivo',
            icon: Icons.monitor_heart_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Lectura bajo demanda para reducir consumo. Los FPS '
                  'y vatios no se estiman sin una fuente fiable.',
                  style: TextStyle(color: muted)),
                if (_diagnostics != null) ...[
                  const SizedBox(height: Gap.s),
                  Text('Batería: ${_diagnostics!.batteryPercent?.toString() ?? 'No disponible'} %'),
                  Text('Temperatura: ${_diagnostics!.temperatureC?.toStringAsFixed(1) ?? 'No disponible'} °C'),
                  Text('RAM libre: ${_diagnostics!.availableMemoryMb?.toString() ?? 'No disponible'} MB'),
                  Text('RAM total: ${_diagnostics!.totalMemoryMb?.toString() ?? 'No disponible'} MB'),
                ],
                const SizedBox(height: Gap.s),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _readDiagnostics,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Actualizar diagnóstico'),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.m),
          if (_message.isNotEmpty)
            Semantics(liveRegion: true, child: Text(_message,
              style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
