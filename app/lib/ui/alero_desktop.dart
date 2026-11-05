import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../desktop_workspace.dart';
import '../hub.dart';
import '../phone_control.dart';
import '../scrcpy.dart';
import 'apps_screen.dart' show AppTile;
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
    this.embedded = false,
  });

  final Hub hub;
  final String serial;
  final String deviceName;
  final String? peerId;

  /// Shown as the Alero Desktop section of the computer's side menu (no page bar of its own).
  final bool embedded;

  @override
  State<AleroDesktopPage> createState() => _AleroDesktopPageState();
}

class _AleroDesktopPageState extends State<AleroDesktopPage> {
  final _search = TextEditingController();
  final _opened = <String>{};
  final _pins = <String>{};
  List<String> _apps = [];
  Map<String, String> _names = {};
  String _name(String pkg) => _names[pkg] ?? pkg.split('.').last;
  List<DesktopDisplay> _displays = [];
  Map<String, int> _tasks = {};
  Desktop _support = Desktop.unsupported;
  DesktopLayout _layout = DesktopLayout.floating;
  String _size = '1920x1080/160';
  String _status = 'Autoriza la depuración USB o inalámbrica del teléfono.';
  int? _displayId;
  bool _loading = true, _busy = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    PhoneSessions.instance.addListener(_sessionChanged);
    widget.hub.addListener(_iconsChanged);
    _load();
    // Only the cheap task dump: listing displays starts a scrcpy server on the phone.
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_busy && PhoneSessions.instance.running(widget.serial)) {
        _refreshTasks();
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    PhoneSessions.instance.removeListener(_sessionChanged);
    widget.hub.removeListener(_iconsChanged);
    _search.dispose();
    super.dispose();
  }

  int _iconCount = 0;

  /// Icons arrive from the phone a few at a time; repaint only when there are new ones.
  void _iconsChanged() {
    if (mounted && widget.hub.appIcons.length != _iconCount) {
      setState(() => _iconCount = widget.hub.appIcons.length);
    }
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
        _pins.addAll(
          raw.whereType<String>().where(validAndroidPackage).take(12),
        );
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
      final named = await Scrcpy.appsWithNames(widget.serial);
      final apps = [for (final a in named) a.$2];
      final missing = apps.where((p) => !widget.hub.appIcons.containsKey(p));
      if (widget.peerId != null &&
          missing.isNotEmpty &&
          widget.hub.connectedPhone?.id == widget.peerId) {
        widget.hub.phoneCmd(widget.peerId!, 'icons', {
          'pkgs': missing.toList(),
        });
      }
      final support = await Scrcpy.desktop(widget.serial);
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _names = {for (final a in named) a.$2: a.$1};
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
    if (id == null ||
        id == 0 ||
        !PhoneSessions.instance.running(widget.serial)) {
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
    setState(() {
      _busy = true;
      _status = title;
    });
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
          maxSize: 0,
          bitRate: 16,
          maxFps: 60,
          // No --start-app: an app the phone already shows would be moved off the phone.
        ),
        peerId: widget.peerId,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      if (!PhoneSessions.instance.running(widget.serial)) {
        throw StateError(
          'El visor cerró la sesión. Comprueba las opciones de desarrollo y la compatibilidad de scrcpy.',
        );
      }
      final after = await Scrcpy.displays(widget.serial);
      final oldIds = before.map((d) => d.id).toSet();
      final created = after
          .where((d) => d.id != 0 && !oldIds.contains(d.id))
          .toList();
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
      if (_displayId != null) {
        try {
          await Scrcpy.openDesktopHome(widget.serial, _displayId!);
          if (mounted) {
            setState(
              () => _status =
                  'Inicio independiente abierto en pantalla ${_displayId!}.',
            );
          }
        } catch (e) {
          if (mounted) {
            setState(
              () => _status =
                  'Pantalla creada, pero Inicio no está disponible: $e',
            );
          }
        }
      }
      await _refreshTasks();
    });
  }

  Future<void> _openApp(String package) async {
    if (_displayId == null || _displayId == 0) {
      setState(
        () => _status =
            'Selecciona primero la pantalla virtual creada por Alero Desktop.',
      );
      return;
    }
    final displayId = _displayId!;
    List<TopTask> before;
    try {
      before = await Scrcpy.topTasks(widget.serial);
    } catch (e) {
      setState(() => _status = 'No se pudo consultar el teléfono: $e');
      return;
    }
    // Most apps allow one window: Android would move the phone's one here.
    if (before.any((t) => t.package == package && t.display == 0)) {
      if (!mounted) return;
      final go =
          await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('La app está abierta en el teléfono'),
              content: Text(
                '$package se está mostrando en la pantalla del teléfono. '
                'Si la app solo admite una ventana, Android la moverá al escritorio virtual '
                'y dejará de verse en el teléfono. ¿Abrirla aquí?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Abrir aquí'),
                ),
              ],
            ),
          ) ??
          false;
      if (!go || !mounted) return;
    }
    await _perform('Abriendo $package…', () async {
      final verdict = await Scrcpy.launchDesktopApp(
        widget.serial,
        package,
        displayId,
        freeform: _support == Desktop.ready,
        before: before,
      );
      if (!mounted) return;
      setState(() {
        _opened.add(package);
        _status = desktopLaunchMessage(verdict, package, displayId);
      });
      await _refreshTasks();
    });
  }

  Future<void> _showDesktop() async {
    if (_displayId == null) return;
    await _perform('Mostrando el escritorio…', () async {
      await Scrcpy.openDesktopHome(widget.serial, _displayId!);
      if (mounted) {
        setState(
          () => _status =
              'Inicio de Alero abierto en la pantalla ${_displayId!}. '
              'El botón Inicio del propio visor abre el inicio del sistema, no el de Alero.',
        );
      }
    });
  }

  Future<void> _arrange() async {
    final display = _displays.where((d) => d.id == _displayId).firstOrNull;
    if (display == null || _tasks.length < 2 || _tasks.length > 4) {
      setState(
        () => _status = 'Abre de 2 a 4 apps visibles y selecciona su pantalla para organizarlas.',
      );
      return;
    }
    await _perform('Organizando ventanas…', () async {
      final count = await Scrcpy.arrangeWindows(
        widget.serial,
        display,
        _tasks.keys.toList(),
        _layout,
      );
      if (mounted) {
        setState(
          () => _status =
              'Android aceptó $count solicitudes de tamaño. Comprueba el resultado en el visor.',
        );
      }
    });
  }

  Future<void> _maximize(String package, int task) async {
    final display = _displays.where((d) => d.id == _displayId).firstOrNull;
    if (display?.resolution == null) {
      setState(
        () => _status = 'La pantalla no anuncia resolución; no se puede redimensionar esa tarea.',
      );
      return;
    }
    await _perform('Maximizando $package…', () async {
      await Scrcpy.resizeDesktopTask(widget.serial, task, display!);
      if (mounted) {
        setState(
          () => _status = 'Android recibió la orden de maximizar $package.',
        );
      }
    });
  }

  Future<void> _closeApp(String package, int task) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cerrar $package'),
        content: const Text(
          'Cerrar ventana quita solo esta ventana del escritorio virtual, como deslizarla en Recientes; '
          'la app sigue abierta en el teléfono si también está allí. '
          'Forzar detención cierra la app en todas las pantallas y puede interrumpir sus notificaciones.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'stop'),
            child: const Text('Forzar detención'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'close'),
            child: const Text('Cerrar ventana'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'close') {
      await _perform('Cerrando la ventana de $package…', () async {
        await Scrcpy.closeDesktopTask(
          widget.serial,
          package,
          task,
          _displayId ?? 0,
        );
        if (mounted) {
          setState(() {
            _opened.remove(package);
            _status =
                'Android cerró la ventana de $package en el escritorio virtual.';
          });
        }
        await _refreshTasks();
      });
      return;
    }
    await _perform('Cerrando $package…', () async {
      if (!_apps.contains(package)) {
        throw StateError(
          'Por seguridad solo se pueden detener aplicaciones instaladas por el usuario.',
        );
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
    final live = PhoneSessions.instance.running(widget.serial);
    final q = _search.text.toLowerCase().trim();
    final filtered = _apps
        .where(
          (p) =>
              q.isEmpty ||
              p.toLowerCase().contains(q) ||
              _name(p).toLowerCase().contains(q),
        )
        .toList();
    final pinList = _pins.where(_apps.contains).toList();
    final canLaunch = live && !_busy && _displayId != null;
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 900;
        final left = _launcher(context, filtered, pinList, canLaunch);
        final right = _workspace(context, live, canLaunch);
        return Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(widget.embedded ? 0 : 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _hero(context, live, canLaunch),
                    const SizedBox(height: 16),
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 3, child: left),
                          const SizedBox(width: 16),
                          Expanded(flex: 2, child: right),
                        ],
                      )
                    else ...[
                      left,
                      const SizedBox(height: 16),
                      right,
                    ],
                    const SizedBox(height: 12),
                    Text(_status, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _dock(context, pinList, canLaunch, live),
          ],
        );
      },
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: const Text('Alero Desktop')),
            body: body,
          );
  }

  /// The big panel on top: what Alero Desktop is and its screen size before it starts; its state and the main
  /// actions while it runs.
  Widget _hero(BuildContext context, bool live, bool canLaunch) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    const sizes = [
      ('1280x720/160', 'HD', '1280 × 720'),
      ('1600x900/160', 'HD+', '1600 × 900'),
      ('1920x1080/160', 'Full HD', '1920 × 1080'),
      ('2560x1440/200', 'QHD', '2560 × 1440'),
    ];
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [s.primaryContainer, s.tertiaryContainer],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.desktop_windows_rounded,
                size: 36,
                color: s.onPrimaryContainer,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Alero Desktop',
                      style: t.headlineMedium?.copyWith(
                        color: s.onPrimaryContainer,
                      ),
                    ),
                    Text(
                      live
                          ? (_displayId == null
                                ? 'El escritorio está abierto en otra ventana. Elige su pantalla abajo.'
                                : 'Escritorio activo en la pantalla $_displayId de ${widget.deviceName}. '
                                      'Usa el ratón y el teclado en su ventana.')
                          : '${widget.deviceName} como un ordenador: escritorio propio con barra de tareas, '
                                'menú de apps y ventanas, en una pantalla virtual. El teléfono sigue libre.',
                      style: t.bodyMedium?.copyWith(
                        color: s.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (!live) ...[
            Text(
              'Tamaño del escritorio',
              style: t.labelLarge?.copyWith(color: s.onPrimaryContainer),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final (value, name, px) in sizes)
                  _SizeCard(
                    name: name,
                    pixels: px,
                    selected: _size == value,
                    onTap: _busy ? null : () => setState(() => _size = value),
                  ),
              ],
            ),
            const SizedBox(height: 20),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!live)
                FilledButton.icon(
                  onPressed: _busy || _loading ? null : _start,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Iniciar Alero Desktop'),
                )
              else ...[
                FilledButton.tonalIcon(
                  onPressed: canLaunch ? _showDesktop : null,
                  icon: const Icon(Icons.home_rounded),
                  label: const Text('Ir al escritorio'),
                ),
                FilledButton.tonalIcon(
                  onPressed: canLaunch ? _arrange : null,
                  icon: const Icon(Icons.grid_view_rounded),
                  label: const Text('Organizar ventanas'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: s.error,
                    foregroundColor: s.onError,
                  ),
                  onPressed: () => PhoneSessions.instance.stop(widget.serial),
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Detener'),
                ),
              ],
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              DesktopWorkshopPage(serial: widget.serial),
                        ),
                      ),
                icon: const Icon(Icons.dashboard_customize_outlined),
                label: const Text('Espacios guardados'),
              ),
              IconButton(
                tooltip: 'Actualizar pantallas y aplicaciones',
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Favorites, like a taskbar: one click opens the app on Alero Desktop.
  Widget _dock(
    BuildContext context,
    List<String> pinList,
    bool canLaunch,
    bool live,
  ) {
    final s = Theme.of(context).colorScheme;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: s.inverseSurface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Escritorio',
            onPressed: canLaunch ? _showDesktop : null,
            color: s.onInverseSurface,
            icon: const Icon(Icons.home_rounded),
          ),
          VerticalDivider(
            color: s.onInverseSurface.withValues(alpha: 0.2),
            indent: 14,
            endIndent: 14,
          ),
          Expanded(
            child: pinList.isEmpty
                ? Text(
                    'Fija apps en el lanzador (mantén pulsada una) para tenerlas aquí',
                    style: TextStyle(
                      color: s.onInverseSurface.withValues(alpha: 0.75),
                    ),
                  )
                : ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final app in pinList)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 10,
                          ),
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: s.onInverseSurface,
                            ),
                            onPressed: canLaunch ? () => _openApp(app) : null,
                            icon: widget.hub.appIcons[app] == null
                                ? const Icon(Icons.apps_rounded, size: 18)
                                : Image.memory(
                                    widget.hub.appIcons[app]!,
                                    width: 22,
                                    height: 22,
                                  ),
                            label: Text(_name(app)),
                          ),
                        ),
                    ],
                  ),
          ),
          Icon(
            Icons.circle,
            size: 10,
            color: live
                ? s.inversePrimary
                : s.onInverseSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(width: 6),
          Text(
            live ? 'Activo' : 'Apagado',
            style: TextStyle(color: s.onInverseSurface),
          ),
        ],
      ),
    );
  }

  Widget _launcher(
    BuildContext context,
    List<String> filtered,
    List<String> pinned,
    bool canLaunch,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Aplicaciones',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Text(
                  '${filtered.length} · ${pinned.length} fijadas',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Buscar apps',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              canLaunch
                  ? 'Clic: abrir en Alero Desktop · mantener pulsado o clic derecho: fijar en la barra'
                  : 'Inicia Alero Desktop para abrir apps · mantener pulsado o clic derecho: fijar en la barra',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (_loading) const LinearProgressIndicator(),
            SizedBox(
              height: 420,
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 120,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.9,
                ),
                itemCount: filtered.length,
                itemBuilder: (context, i) {
                  final pkg = filtered[i];
                  return GestureDetector(
                    onLongPress: () => _togglePin(pkg),
                    onSecondaryTap: () => _togglePin(pkg),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: AppTile(
                            name: _name(pkg),
                            icon: widget.hub.appIcons[pkg],
                            open: _tasks.containsKey(pkg),
                            onTap: canLaunch
                                ? () => _openApp(pkg)
                                : () => setState(
                                    () => _status =
                                        'Inicia Alero Desktop para abrir ${_name(pkg)}.',
                                  ),
                          ),
                        ),
                        if (_pins.contains(pkg))
                          const Positioned(
                            top: 4,
                            right: 8,
                            child: Icon(Icons.push_pin_rounded, size: 16),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _workspace(BuildContext context, bool live, bool canLaunch) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pantallas y ventanas',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            const Text(
              'El contenido Android se controla en el visor de scrcpy. '
              'La pantalla física del Pixel permanece independiente mientras Android lo permita.',
            ),
            const SizedBox(height: 10),
            Text(
              'Ventanas libres: ${switch (_support) {
                Desktop.ready => "Android declara soporte",
                Desktop.needsSetting => "ajuste de escritorio pendiente",
                Desktop.unsupported => "sin compatibilidad confirmada",
              }}',
            ),
            const SizedBox(height: 6),
            DropdownButton<int>(
              isExpanded: true,
              hint: const Text('Seleccionar pantalla virtual de Android'),
              value: _displayId,
              items: [
                for (final d in _displays.where((d) => d.id != 0))
                  DropdownMenuItem(
                    value: d.id,
                    child: Text(
                      'Pantalla ${d.id} · ${d.description}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: !live || _busy
                  ? null
                  : (v) {
                      setState(() {
                        _displayId = v;
                        _tasks = {};
                      });
                      _refreshTasks();
                    },
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: live && !_busy ? _refreshDisplays : null,
                  icon: const Icon(Icons.sync_rounded),
                  label: const Text('Detectar pantallas'),
                ),
                OutlinedButton.icon(
                  onPressed: canLaunch ? _showDesktop : null,
                  icon: const Icon(Icons.home_rounded),
                  label: const Text('Ir a Inicio'),
                ),
              ],
            ),
            const Divider(height: 30),
            Text(
              'Ventanas detectadas por Android',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (_tasks.isEmpty)
              const Text(
                'Todavía no hay tareas comprobadas en esta pantalla. '
                'Puedes abrir apps desde el lanzador; el visor muestra los controles nativos cuando estén disponibles.',
              ),
            for (final e in _tasks.entries.where((e) => _apps.contains(e.key)))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.web_asset_rounded),
                title: Text(
                  e.key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  'Tarea ${e.value} · pantalla ${_displayId ?? "-"}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Traer al frente',
                      onPressed: canLaunch ? () => _openApp(e.key) : null,
                      icon: const Icon(Icons.flip_to_front_rounded),
                    ),
                    IconButton(
                      tooltip: 'Maximizar (si Android lo permite)',
                      onPressed: canLaunch
                          ? () => _maximize(e.key, e.value)
                          : null,
                      icon: const Icon(Icons.crop_square_rounded),
                    ),
                    IconButton(
                      tooltip: 'Cerrar ventana',
                      onPressed: canLaunch
                          ? () => _closeApp(e.key, e.value)
                          : null,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            DropdownButton<DesktopLayout>(
              isExpanded: true,
              value: _layout,
              items: const [
                DropdownMenuItem(
                  value: DesktopLayout.floating,
                  child: Text('Ventanas libres: conservar posiciones'),
                ),
                DropdownMenuItem(
                  value: DesktopLayout.halves,
                  child: Text('Dos ventanas: mitades'),
                ),
                DropdownMenuItem(
                  value: DesktopLayout.thirds,
                  child: Text('Tres ventanas: tercios'),
                ),
                DropdownMenuItem(
                  value: DesktopLayout.quarters,
                  child: Text('Cuatro ventanas: cuadrícula'),
                ),
              ],
              onChanged: !_busy
                  ? (v) => setState(() => _layout = v ?? _layout)
                  : null,
            ),
            FilledButton.tonalIcon(
              onPressed: canLaunch && _layout != DesktopLayout.floating
                  ? _arrange
                  : null,
              icon: const Icon(Icons.view_quilt_rounded),
              label: const Text('Organizar ventanas detectadas'),
            ),
            const SizedBox(height: 6),
            Text(
              'Para minimizar o cerrar una sola ventana sin forzar la '
              'detención de toda la app, usa su barra de título Android dentro '
              'del visor. Android determina si esa barra está disponible.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// One screen size for Alero Desktop, as a card.
class _SizeCard extends StatelessWidget {
  const _SizeCard({
    required this.name,
    required this.pixels,
    required this.selected,
    this.onTap,
  });
  final String name, pixels;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? s.primary : s.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: SizedBox(
            width: 150,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.monitor_rounded,
                    color: selected ? s.onPrimary : s.onSurface,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    name,
                    style: t.titleMedium?.copyWith(
                      color: selected ? s.onPrimary : s.onSurface,
                    ),
                  ),
                  Text(
                    pixels,
                    style: t.bodySmall?.copyWith(
                      color: selected ? s.onPrimary : s.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
