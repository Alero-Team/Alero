import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../desktop_workspace.dart';
import '../hub.dart';
import '../phone_control.dart';
import '../scrcpy.dart';
import 'desktop_workshop.dart';

/// Alero Desktop: a Windows launcher and controls for a genuine Android
/// secondary display. The live Android image belongs to scrcpy's own SDL
/// window; this Flutter page never pretends to draw Android activities.
/// System window captions (X, minimize, resize) appear *inside* that viewer
/// only on Android versions/virtual displays that enable native freeform.
class AleroDesktopPage extends StatefulWidget {
  const AleroDesktopPage({
    super.key,
    required this.hub,
    required this.serial,
    required this.deviceName,
    this.peerId,
  });

  final Hub hub;
  final String serial;
  final String deviceName;
  final String? peerId;

  @override
  State<AleroDesktopPage> createState() => _AleroDesktopPageState();
}

class _AleroDesktopPageState extends State<AleroDesktopPage> {
  final _search = TextEditingController();
  final _opened = <String>{};
  final _pins = <String>{};
  List<String> _apps = [];
  List<DesktopDisplay> _displays = [];
  Map<String, int> _tasks = {};
  Desktop _support = Desktop.unsupported;
  DesktopLayout _layout = DesktopLayout.floating;
  String _size = '1920x1080/160';
  String _status = 'Conecta tu Pixel con depuración USB autorizada.';
  int? _displayId;
  bool _loading = true, _busy = false, _flex = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    PhoneSessions.instance.addListener(_sessionChanged);
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_busy && PhoneSessions.instance.running(widget.serial)) {
        _refreshDisplays();
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    PhoneSessions.instance.removeListener(_sessionChanged);
    _search.dispose();
    super.dispose();
  }

  void _sessionChanged() {
    if (!mounted) return;
    setState(() {
      if (!PhoneSessions.instance.running(widget.serial)) {
        _displayId = null;
        _tasks = {};
        _opened.clear();
      }
    });
  }

  Future<File> _pinsFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}alero-desktop-pins.json');
  }

  Future<void> _loadPins() async {
    try {
      final file = await _pinsFile();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is List) {
        _pins.addAll(raw.whereType<String>().where(validAndroidPackage).take(12));
      }
    } catch (_) {
      // Corrupt pin state must not prevent desktop startup.
    }
  }

  Future<void> _savePins() async {
    final file = await _pinsFile();
    await file.writeAsString(jsonEncode(_pins.toList()), flush: true);
  }

  Future<void> _load() async {
    try {
      await _loadPins();
      final apps = await Scrcpy.installedApps(widget.serial);
      final support = await Scrcpy.desktop(widget.serial);
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _pins.removeWhere((p) => !apps.contains(p));
        _support = support;
        _loading = false;
        _status = switch (support) {
          Desktop.ready => 'Android declara ventanas libres; comprueba sus controles en el visor.',
          Desktop.needsSetting => 'La pantalla virtual puede abrirse, pero Android no confirma las ventanas libres.',
          Desktop.unsupported => 'Android no anuncia ventanas libres. Se intentará usar una pantalla secundaria.',
        };
      });
      await _refreshDisplays();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = 'No se pudo consultar el teléfono: $e';
      });
    }
  }

  Future<void> _refreshDisplays() async {
    try {
      final displays = await Scrcpy.displays(widget.serial);
      if (!mounted) return;
      setState(() {
        _displays = displays;
        if (_displayId != null && !displays.any((d) => d.id == _displayId)) {
          _displayId = null;
          _tasks = {};
        }
      });
      await _refreshTasks();
    } catch (_) {
      // ADB is not always available while scrcpy is starting up.
    }
  }

  Future<void> _refreshTasks() async {
    final id = _displayId;
    if (id == null || id == 0 || !PhoneSessions.instance.running(widget.serial)) {
      return;
    }
    try {
      final tasks = await Scrcpy.desktopTasks(widget.serial, id);
      if (mounted) setState(() => _tasks = tasks);
    } catch (_) {
      if (mounted) setState(() => _tasks = {});
    }
  }

  Future<void> _perform(String title, Future<void> Function() task) async {
    if (_busy) return;
    setState(() { _busy = true; _status = title; });
    try {
      await task();
    } catch (e) {
      if (mounted) setState(() => _status = 'No se pudo completar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() async {
    await _perform('Creando el escritorio virtual de Android…', () async {
      // Compare before/after displays; never assume a new virtual display ID
      // and accidentally send tasks to the phone's physical display.
      final before = await Scrcpy.displays(widget.serial);
      await widget.hub.startControl(
        widget.serial,
        'Alero Desktop · ${widget.deviceName}',
        SessionOptions(
          desktop: true,
          desktopSize: _size,
          flexDisplay: _flex,
          maxSize: 0,
          bitRate: 16,
          maxFps: 60,
          startApp: 'com.android.settings',
        ),
        peerId: widget.peerId,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      if (!PhoneSessions.instance.running(widget.serial)) {
        throw StateError('El visor cerró la sesión. Comprueba las opciones de desarrollo y la compatibilidad de scrcpy.');
      }
      final after = await Scrcpy.displays(widget.serial);
      final oldIds = before.map((d) => d.id).toSet();
      final created = after.where((d) => d.id != 0 && !oldIds.contains(d.id)).toList();
      if (!mounted) return;
      setState(() {
        _displays = after;
        _displayId = created.length == 1 ? created.single.id : null;
        _opened.clear();
        _tasks = {};
        _status = _displayId == null
          ? 'Se abrió el visor. Elige la nueva pantalla Android en el selector; no se enviarán apps a la pantalla física automáticamente.'
          : 'Alero Desktop listo en la pantalla ${_displayId!}. Las ventanas nativas dependen del Pixel.';
      });
      await _refreshTasks();
    });
  }

  Future<void> _openApp(String package) async {
    if (_displayId == null || _displayId == 0) {
      setState(() => _status = 'Selecciona primero la pantalla virtual creada por Alero Desktop.');
      return;
    }
    await _perform('Abriendo $package…', () async {
      final out = await Scrcpy.launchApp(
        widget.serial, package,
        displayId: _displayId!,
        freeform: _support == Desktop.ready,
      );
      if (out.contains('Error:') || out.contains('Exception') ||
          out.contains('unable to resolve Intent')) {
        throw StateError('Android rechazó el inicio: $out');
      }
      if (!mounted) return;
      setState(() {
        _opened.add(package);
        _status = 'Android recibió la solicitud de abrir $package en la pantalla ${_displayId!}.';
      });
      await _refreshTasks();
    });
  }

  Future<void> _showDesktop() async {
    if (_displayId == null) return;
    await _perform('Mostrando el escritorio…', () async {
      await Scrcpy.displayKey(widget.serial, _displayId!, Keys.home);
      if (mounted) {
        setState(() => _status =
          'Inicio enviado a la pantalla secundaria. En modo escritorio nativo puedes minimizar cada ventana desde su barra.');
      }
    });
  }

  Future<void> _arrange() async {
    final display = _displays.where((d) => d.id == _displayId).firstOrNull;
    if (display == null || _tasks.length < 2 || _tasks.length > 4) {
      setState(() => _status = 'Abre de 2 a 4 apps visibles y selecciona su pantalla para organizarlas.');
      return;
    }
    await _perform('Organizando ventanas…', () async {
      final count = await Scrcpy.arrangeWindows(
        widget.serial, display, _tasks.keys.toList(), _layout,
      );
      if (mounted) {
        setState(() =>
          _status = 'Android aceptó $count solicitudes de tamaño. Comprueba el resultado en el visor.');
      }
    });
  }

  Future<void> _maximize(String package, int task) async {
    final display = _displays.where((d) => d.id == _displayId).firstOrNull;
    if (display?.resolution == null) {
      setState(() => _status = 'La pantalla no anuncia resolución; no se puede redimensionar esa tarea.');
      return;
    }
    await _perform('Maximizando $package…', () async {
      await Scrcpy.resizeDesktopTask(widget.serial, task, display!);
      if (mounted) {
        setState(() =>
          _status = 'Android recibió la orden de maximizar $package.');
      }
    });
  }

  Future<void> _closeApp(String package) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forzar detención de la aplicación'),
        content: Text(
          'Android no permite cerrar una ventana específica mediante ADB en todos los modelos. '
          'Forzar la detención de $package cerrará también sus actividades en el teléfono '
          'y puede interrumpir sus notificaciones. ¿Continuar?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Forzar cierre')),
        ],
      ),
    ) ?? false;
    if (!approved || !mounted) return;
    await _perform('Cerrando $package…', () async {
      if (!_apps.contains(package)) {
        throw StateError('Por seguridad solo se pueden detener aplicaciones instaladas por el usuario.');
      }
      await Scrcpy.forceStopUserApp(widget.serial, package);
      if (mounted) {
        setState(() {
          _opened.remove(package);
          _status = '$package detenida por Android.';
        });
      }
      await _refreshTasks();
    });
  }

  Future<void> _togglePin(String package) async {
    setState(() {
      if (!_pins.remove(package) && _pins.length < 12) _pins.add(package);
    });
    await _savePins();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final live = PhoneSessions.instance.running(widget.serial);
    final filtered = _apps.where((p) =>
      p.toLowerCase().contains(_search.text.toLowerCase().trim())).toList();
    final pinList = _pins.where(_apps.contains).toList();
    final canLaunch = live && !_busy && _displayId != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alero Desktop'),
        actions: [
          IconButton(
            tooltip: 'Actualizar pantallas y aplicaciones',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Detener escritorio',
            onPressed: live ? () => PhoneSessions.instance.stop(widget.serial) : null,
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        ],
      ),
      body: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth > 850;
        final left = _launcher(context, filtered, pinList, canLaunch);
        final right = _workspace(context, live, canLaunch);
        return Column(children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      gradient: LinearGradient(colors: [
                        scheme.primaryContainer,
                        scheme.tertiaryContainer,
                      ]),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Tu Pixel, como escritorio', style:
                          Theme.of(context).textTheme.headlineMedium),
                        const SizedBox(height: 8),
                        Text('Apps Android en una pantalla secundaria. El visor se abre '
                          'en una ventana aparte; los controles nativos de minimizar, '
                          'cerrar y redimensionar aparecen allí solo si Android los ofrece.'),
                        const SizedBox(height: 16),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          FilledButton.icon(
                            onPressed: _busy || _loading || live ? null : _start,
                            icon: const Icon(Icons.desktop_windows_rounded),
                            label: Text(live ? 'Escritorio abierto' : 'Iniciar Alero Desktop'),
                          ),
                          OutlinedButton.icon(
                            onPressed: live ? () => PhoneSessions.instance.stop(widget.serial) : null,
                            icon: const Icon(Icons.stop_rounded),
                            label: const Text('Detener'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => Navigator.push(context,
                              MaterialPageRoute<void>(builder: (_) =>
                                DesktopWorkshopPage(serial: widget.serial))),
                            icon: const Icon(Icons.dashboard_customize_outlined),
                            label: const Text('Espacios guardados'),
                          ),
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (wide)
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(flex: 3, child: left),
                      const SizedBox(width: 14),
                      Expanded(flex: 4, child: right),
                    ])
                  else ...[left, const SizedBox(height: 14), right],
                  const SizedBox(height: 14),
                  Text(_status, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
          ),
          Container(
            color: scheme.surfaceContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Row(children: [
              Icon(Icons.apps_rounded, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final app in pinList)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ActionChip(
                          avatar: const Icon(Icons.android_rounded, size: 18),
                          label: Text(app.split('.').last),
                          onPressed: canLaunch ? () => _openApp(app) : null,
                        ),
                      ),
                    if (pinList.isEmpty)
                      const Text('Fija tus aplicaciones favoritas para verlas aquí'),
                  ]),
                ),
              ),
              if (live) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Mostrar escritorio de Android (Inicio)',
                  child: IconButton(
                    onPressed: canLaunch ? _showDesktop : null,
                    icon: const Icon(Icons.minimize_rounded),
                  ),
                ),
              ],
            ]),
          ),
        ]);
      }),
    );
  }

  Widget _launcher(BuildContext context, List<String> filtered,
    List<String> pinned, bool canLaunch) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Lanzador de aplicaciones', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'Buscar por identificador de paquete',
            ),
          ),
          const SizedBox(height: 8),
          if (_loading) const LinearProgressIndicator(),
          SizedBox(
            height: 310,
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, i) {
                final pkg = filtered[i];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.android_rounded),
                  title: Text(pkg, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: _pins.contains(pkg) ? 'Quitar de la barra' : 'Fijar en la barra',
                      onPressed: () => _togglePin(pkg),
                      icon: Icon(_pins.contains(pkg)
                        ? Icons.push_pin_rounded : Icons.push_pin_outlined),
                    ),
                    IconButton(
                      tooltip: 'Abrir en el escritorio virtual',
                      onPressed: canLaunch ? () => _openApp(pkg) : null,
                      icon: const Icon(Icons.open_in_new_rounded),
                    ),
                  ]),
                );
              },
            ),
          ),
          Text('${filtered.length} aplicaciones · ${pinned.length} favoritas'),
        ]),
      ),
    );
  }

  Widget _workspace(BuildContext context, bool live, bool canLaunch) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Pantallas y ventanas', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          const Text('El contenido Android se controla en el visor de scrcpy. '
            'La pantalla física del Pixel permanece independiente mientras Android lo permita.'),
          const SizedBox(height: 10),
          DropdownButton<String>(
            isExpanded: true,
            value: _size,
            items: const [
              DropdownMenuItem(value: '1280x720/160', child: Text('HD · 1280 × 720')),
              DropdownMenuItem(value: '1600x900/160', child: Text('HD+ · 1600 × 900')),
              DropdownMenuItem(value: '1920x1080/160', child: Text('Full HD · 1920 × 1080')),
              DropdownMenuItem(value: '2560x1440/200', child: Text('QHD · 2560 × 1440')),
            ],
            onChanged: live || _busy ? null : (v) => setState(() => _size = v ?? _size),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Adaptar al tamaño de la ventana'),
            subtitle: const Text('Usa --flex-display; disponible si Android lo admite'),
            value: _flex,
            onChanged: live || _busy ? null : (v) => setState(() => _flex = v),
          ),
          const SizedBox(height: 6),
          Text('Ventanas libres: ${switch (_support) {
            Desktop.ready => "Android declara soporte",
            Desktop.needsSetting => "ajuste de escritorio pendiente",
            Desktop.unsupported => "sin compatibilidad confirmada",
          }}'),
          const SizedBox(height: 6),
          DropdownButton<int>(
            isExpanded: true,
            hint: const Text('Seleccionar pantalla virtual de Android'),
            value: _displayId,
            items: [
              for (final d in _displays.where((d) => d.id != 0))
                DropdownMenuItem(value: d.id,
                  child: Text('Pantalla ${d.id} · ${d.description}',
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: !live || _busy ? null : (v) {
              setState(() { _displayId = v; _tasks = {}; });
              _refreshTasks();
            },
          ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: live && !_busy ? _refreshDisplays : null,
              icon: const Icon(Icons.sync_rounded),
              label: const Text('Detectar pantallas'),
            ),
            OutlinedButton.icon(
              onPressed: canLaunch ? _showDesktop : null,
              icon: const Icon(Icons.minimize_rounded),
              label: const Text('Mostrar escritorio'),
            ),
          ]),
          const Divider(height: 30),
          Text('Ventanas detectadas por Android', style:
            Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_tasks.isEmpty)
            const Text('Todavía no hay tareas comprobadas en esta pantalla. '
              'Puedes abrir apps desde el lanzador; el visor muestra los controles nativos cuando estén disponibles.'),
          for (final e in _tasks.entries.where((e) => _apps.contains(e.key)))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.web_asset_rounded),
              title: Text(e.key, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('Tarea ${e.value} · pantalla ${_displayId ?? "-"}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Traer al frente',
                  onPressed: canLaunch ? () => _openApp(e.key) : null,
                  icon: const Icon(Icons.flip_to_front_rounded),
                ),
                IconButton(
                  tooltip: 'Maximizar (si Android lo permite)',
                  onPressed: canLaunch ? () => _maximize(e.key, e.value) : null,
                  icon: const Icon(Icons.crop_square_rounded),
                ),
                IconButton(
                  tooltip: 'Forzar cierre (requiere confirmación)',
                  onPressed: canLaunch ? () => _closeApp(e.key) : null,
                  icon: const Icon(Icons.close_rounded),
                ),
              ]),
            ),
          const SizedBox(height: 10),
          DropdownButton<DesktopLayout>(
            isExpanded: true,
            value: _layout,
            items: const [
              DropdownMenuItem(value: DesktopLayout.floating,
                child: Text('Ventanas libres: conservar posiciones')),
              DropdownMenuItem(value: DesktopLayout.halves,
                child: Text('Dos ventanas: mitades')),
              DropdownMenuItem(value: DesktopLayout.thirds,
                child: Text('Tres ventanas: tercios')),
              DropdownMenuItem(value: DesktopLayout.quarters,
                child: Text('Cuatro ventanas: cuadrícula')),
            ],
            onChanged: !_busy ? (v) => setState(() => _layout = v ?? _layout) : null,
          ),
          FilledButton.tonalIcon(
            onPressed: canLaunch && _layout != DesktopLayout.floating
              ? _arrange : null,
            icon: const Icon(Icons.view_quilt_rounded),
            label: const Text('Organizar ventanas detectadas'),
          ),
          const SizedBox(height: 6),
          Text('Para minimizar o cerrar una sola ventana sin forzar la '
            'detención de toda la app, usa su barra de título Android dentro '
            'del visor. Android determina si esa barra está disponible.',
            style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}
