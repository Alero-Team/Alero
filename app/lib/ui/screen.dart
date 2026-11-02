import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../phone_control.dart';
import '../scrcpy.dart';
import '../src/rust/api/engine.dart' as pb;
import 'expressive.dart';
import 'theme.dart';
import 'widgets.dart';

/// "Controlar teléfono": view and drive a phone from this computer with scrcpy (ADR-0008), over USB or wireless
/// debugging. The user authorises it on the phone (adb), a paired phone shows a notice with "Detener", and every
/// session ends with its window, with "Detener" here or there, or when Alero quits.
Future<void> openScreen(BuildContext context, Hub hub, pb.Peer phone) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PhoneControlPage(hub, phone)),
    );

String _ipOf(pb.Peer p) {
  final i = p.addr.lastIndexOf(':');
  return i > 0 ? p.addr.substring(0, i) : '';
}

class PhoneControlPage extends StatefulWidget {
  const PhoneControlPage(this.hub, this.phone, {super.key});
  final Hub hub;
  final pb.Peer phone;

  @override
  State<PhoneControlPage> createState() => _PhoneControlPageState();
}

class _PhoneControlPageState extends State<PhoneControlPage> {
  final _port = TextEditingController(), _code = TextEditingController();
  List<AdbDevice> _devices = [];
  String? _serial;
  Desktop _desktop = Desktop.unsupported;
  String _status = '';
  bool _busy = false, _listing = false;
  Timer? _poll;

  // Session options (scrcpy flags, see scrcpyArgs).
  int _maxSize = 1600, _bitRate = 8, _fps = 60, _orientation = 0;
  bool _audio = true, _screenOff = false, _fullscreen = false, _desk = false;

  AdbDevice? get _device =>
      _devices.where((d) => d.serial == _serial).firstOrNull;

  @override
  void initState() {
    super.initState();
    if (!Scrcpy.available) return;
    PhoneSessions.instance.addListener(_changed);
    _list();
    // A cable plugged in, or "Permitir" tapped on the phone, shows up within a few seconds.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _list());
  }

  @override
  void dispose() {
    _poll?.cancel();
    PhoneSessions.instance.removeListener(_changed);
    _port.dispose();
    _code.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _list() async {
    if (_listing) return;
    _listing = true;
    try {
      final d = await Scrcpy.list();
      if (!mounted) return;
      final before = _serial;
      setState(() {
        _devices = d;
        if (_device == null) {
          // Prefer this phone's own Wi-Fi address, then whatever is ready.
          final ip = _ipOf(widget.phone);
          _serial =
              (d
                          .where(
                            (x) =>
                                x.ready &&
                                ip.isNotEmpty &&
                                x.serial.startsWith('$ip:'),
                          )
                          .firstOrNull ??
                      d.where((x) => x.ready).firstOrNull ??
                      d.firstOrNull)
                  ?.serial;
        }
      });
      if (_serial != before) await _probe();
    } catch (_) {
      // adb busy or missing for a moment: the next tick tries again
    } finally {
      _listing = false;
    }
  }

  Future<void> _probe() async {
    final d = _device;
    final r = d != null && d.ready
        ? await Scrcpy.desktop(d.serial)
        : Desktop.unsupported;
    if (mounted) {
      setState(() {
        _desktop = r;
        if (r != Desktop.ready) _desk = false;
      });
    }
  }

  Future<void> _run(String doing, Future<String> Function() f) async {
    setState(() {
      _busy = true;
      _status = doing;
    });
    String s;
    try {
      s = await f();
    } catch (e) {
      s = 'No se pudo: $e';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _status = s;
      });
    }
  }

  Future<String> _wifi() async {
    final serial = await Scrcpy.ready(_ipOf(widget.phone));
    await _list();
    if (serial == null) {
      return 'No aparece por Wi-Fi. Activa «Depuración inalámbrica» en el teléfono y vincúlalo una vez con los pasos de abajo.';
    }
    setState(() => _serial = serial);
    await _probe();
    return 'Conectado por Wi-Fi.';
  }

  Future<String> _pair() async {
    final out = await Scrcpy.pair(
      _ipOf(widget.phone),
      _port.text.trim(),
      _code.text.trim(),
    );
    if (!out.toLowerCase().contains('successfully')) {
      return 'No se vinculó. El puerto y el código cambian cada vez que abres la pantalla de vinculación.';
    }
    _code.clear();
    _port.clear();
    return _wifi();
  }

  /// The paired phone this adb device is, if any: same Wi-Fi address, or the same model.
  String? _peerFor(AdbDevice d) {
    final ip = _ipOf(widget.phone);
    final model = widget.hub.info[widget.phone.id]?.model.toLowerCase() ?? '';
    final same =
        (ip.isNotEmpty && d.serial.startsWith('$ip:')) ||
        (!d.wifi && model.isNotEmpty && d.model.toLowerCase() == model);
    return same ? widget.phone.id : null;
  }

  Future<String> _start() async {
    final d = _device;
    if (d == null || !d.ready) return 'Elige un teléfono listo.';
    await widget.hub.startControl(
      d.serial,
      '${d.name} · Alero',
      SessionOptions(
        maxSize: _maxSize,
        bitRate: _bitRate,
        maxFps: _fps,
        audio: _audio,
        screenOff: _screenOff,
        fullscreen: _fullscreen,
        orientation: _orientation,
        desktop: _desk,
      ),
      peerId: _peerFor(d),
    );
    return _desk
        ? 'Escritorio abierto en otra ventana. Las apps se abren en ventanas que puedes mover y redimensionar.'
        : 'Pantalla abierta en otra ventana. Usa el ratón y el teclado como si tocaras el teléfono.';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final d = _device;
    final live = d != null && PhoneSessions.instance.running(d.serial);
    return Scaffold(
      appBar: AppBar(title: Text('Controlar ${widget.phone.name}')),
      body: Platform.isAndroid || !Scrcpy.available
          ? const EmptyState(
              icon: Symbols.cast_rounded,
              title: 'Falta el componente de pantalla',
              body: 'Esta instalación no incluye scrcpy. Reinstala Alero o copia la carpeta «scrcpy» junto al programa.',
            )
          : ListView(
              padding: const EdgeInsets.all(Gap.l),
              children: [
                if (live) _LiveBar(serial: d.serial, name: d.name),
                Reveal(
                  index: 0,
                  child: Panel(
                    title: 'Dispositivo',
                    icon: Symbols.devices_rounded,
                    action: IconButton(
                      tooltip: 'Buscar de nuevo',
                      onPressed: _list,
                      icon: const Icon(Symbols.refresh_rounded),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_devices.isEmpty)
                          Text(
                            'No hay teléfonos a la vista. Conecta uno por USB con «Depuración USB» activada, o búscalo por Wi-Fi.',
                            style: t.bodyMedium?.copyWith(
                              color: s.onSurfaceVariant,
                            ),
                          ),
                        RadioGroup<String>(
                          groupValue: _serial,
                          onChanged: (v) {
                            setState(() => _serial = v);
                            _probe();
                          },
                          child: Column(
                            children: [
                              for (final x in _devices)
                                RadioListTile<String>(
                                  contentPadding: EdgeInsets.zero,
                                  value: x.serial,
                                  secondary: Icon(
                                    x.wifi
                                        ? Symbols.wifi_rounded
                                        : Symbols.usb_rounded,
                                  ),
                                  title: Text(x.name),
                                  subtitle: Text(_stateText(x)),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: Gap.s),
                        Wrap(
                          spacing: Gap.s,
                          runSpacing: Gap.s,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: _busy
                                  ? null
                                  : () => _run('Buscando por Wi-Fi…', _wifi),
                              icon: const Icon(
                                Symbols.wifi_find_rounded,
                                size: 18,
                              ),
                              label: const Text('Buscar por Wi-Fi'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Gap.m),
                Reveal(
                  index: 1,
                  child: Panel(
                    title: 'Modo',
                    icon: Symbols.desktop_windows_rounded,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SegmentedButton<bool>(
                          segments: [
                            const ButtonSegment(
                              value: false,
                              icon: Icon(Symbols.smartphone_rounded),
                              label: Text('Pantalla del teléfono'),
                            ),
                            ButtonSegment(
                              value: true,
                              enabled: _desktop == Desktop.ready,
                              icon: const Icon(Symbols.desktop_windows_rounded),
                              label: const Text('Escritorio'),
                            ),
                          ],
                          selected: {_desk},
                          onSelectionChanged: (v) =>
                              setState(() => _desk = v.first),
                        ),
                        const SizedBox(height: Gap.s),
                        Text(
                          switch (_desktop) {
                            Desktop.ready => 'Este teléfono tiene escritorio de Android: abre una pantalla aparte con ventanas libres, sin tocar su pantalla.',
                            Desktop.needsSetting => 'Este teléfono admite escritorio. Actívalo en Ajustes › Sistema › Opciones de desarrollador › «Forzar modo de escritorio» y reinicia el teléfono. Mientras tanto se usa su pantalla normal.',
                            Desktop.unsupported => 'Este teléfono no tiene escritorio de Android: se controla su pantalla normal.',
                          },
                          style: t.bodyMedium?.copyWith(
                            color: s.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Gap.m),
                Reveal(
                  index: 2,
                  child: Panel(
                    title: 'Imagen y sonido',
                    icon: Symbols.tune_rounded,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Choice(
                          label: 'Resolución',
                          value: _maxSize,
                          options: const {
                            1024: '1024',
                            1600: '1600',
                            0: 'Original',
                          },
                          onChanged: (v) => setState(() => _maxSize = v),
                        ),
                        _Choice(
                          label: 'Calidad',
                          value: _bitRate,
                          options: const {4: 'Ahorro', 8: 'Normal', 16: 'Alta'},
                          onChanged: (v) => setState(() => _bitRate = v),
                        ),
                        _Choice(
                          label: 'Fotogramas',
                          value: _fps,
                          options: const {30: '30', 60: '60'},
                          onChanged: (v) => setState(() => _fps = v),
                        ),
                        _Choice(
                          label: 'Orientación',
                          value: _orientation,
                          options: const {
                            0: 'Auto',
                            90: '90°',
                            180: '180°',
                            270: '270°',
                          },
                          onChanged: (v) => setState(() => _orientation = v),
                        ),
                        _Toggle(
                          'Sonido del teléfono en el ordenador',
                          _audio,
                          (v) => setState(() => _audio = v),
                        ),
                        _Toggle(
                          'Abrir a pantalla completa',
                          _fullscreen,
                          (v) => setState(() => _fullscreen = v),
                        ),
                        if (!_desk)
                          _Toggle(
                            'Apagar la pantalla del teléfono mientras tanto',
                            _screenOff,
                            (v) => setState(() => _screenOff = v),
                          ),
                        Text(
                          'En la ventana: Alt+F pantalla completa, Alt+R girar, Ctrl+C y Ctrl+V copian y pegan entre los dos.',
                          style: t.bodySmall?.copyWith(
                            color: s.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Gap.m),
                if (_status.isNotEmpty)
                  Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: Gap.m),
                      child: Row(
                        children: [
                          if (_busy)
                            const Padding(
                              padding: EdgeInsets.only(right: Gap.s),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          Expanded(child: Text(_status, style: t.bodyMedium)),
                        ],
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: live
                      ? FilledButton.tonalIcon(
                          onPressed: () =>
                              PhoneSessions.instance.stop(d.serial),
                          icon: const Icon(
                            Symbols.stop_circle_rounded,
                            size: 18,
                          ),
                          label: const Text('Detener'),
                        )
                      : FilledButton.icon(
                          onPressed: _busy || d == null || !d.ready
                              ? null
                              : () => _run('Abriendo…', _start),
                          icon: const Icon(Symbols.cast_rounded, size: 18),
                          label: Text(
                            _desk ? 'Abrir escritorio' : 'Iniciar control',
                          ),
                        ),
                ),
                const SizedBox(height: Gap.l),
                _Setup(
                  port: _port,
                  code: _code,
                  busy: _busy,
                  onPair: () => _run('Vinculando…', _pair),
                ),
              ],
            ),
    );
  }

  static String _stateText(AdbDevice d) => switch (d.state) {
    'device' => d.wifi ? 'Listo · Wi-Fi' : 'Listo · USB',
    'unauthorized' => 'Falta permiso: en el teléfono toca «Permitir» en «¿Permitir la depuración USB?»',
    'offline' => 'Sin respuesta: desconecta y vuelve a conectar el cable',
    _ => d.state,
  };
}

/// Shown while a session runs: who is being controlled, the phone's keys, and the way to stop it.
class _LiveBar extends StatelessWidget {
  const _LiveBar({required this.serial, required this.name});
  final String serial, name;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    Widget key(IconData icon, String label, int code) => MorphButton(
      icon: icon,
      label: label,
      size: 48,
      onPressed: () {
        HapticFeedback.selectionClick();
        Scrcpy.key(serial, code);
      },
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.m),
      child: Card(
        color: s.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Symbols.screen_share_rounded,
                    color: s.onPrimaryContainer,
                  ),
                  const SizedBox(width: Gap.s),
                  Expanded(
                    child: Text(
                      'Controlando $name',
                      style: t.titleMedium?.copyWith(
                        color: s.onPrimaryContainer,
                      ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: () => PhoneSessions.instance.stop(serial),
                    icon: const Icon(Symbols.stop_circle_rounded, size: 18),
                    label: const Text('Detener'),
                  ),
                ],
              ),
              const SizedBox(height: Gap.m),
              Wrap(
                spacing: Gap.s,
                runSpacing: Gap.s,
                children: [
                  key(Symbols.arrow_back_rounded, 'Atrás', Keys.back),
                  key(Symbols.circle_rounded, 'Inicio', Keys.home),
                  key(Symbols.crop_square_rounded, 'Recientes', Keys.recents),
                  key(
                    Symbols.volume_down_rounded,
                    'Bajar volumen',
                    Keys.volumeDown,
                  ),
                  key(
                    Symbols.volume_up_rounded,
                    'Subir volumen',
                    Keys.volumeUp,
                  ),
                  key(Symbols.skip_previous_rounded, 'Anterior', Keys.previous),
                  key(
                    Symbols.play_pause_rounded,
                    'Reproducir o pausar',
                    Keys.playPause,
                  ),
                  key(Symbols.skip_next_rounded, 'Siguiente', Keys.next),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });
  final String label;
  final int value;
  final Map<int, String> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.s),
    child: Row(
      children: [
        SizedBox(width: 110, child: Text(label)),
        Expanded(
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              for (final e in options.entries)
                ButtonSegment(value: e.key, label: Text(e.value)),
            ],
            selected: {value},
            onSelectionChanged: (v) => onChanged(v.first),
          ),
        ),
      ],
    ),
  );
}

class _Toggle extends StatelessWidget {
  const _Toggle(this.label, this.value, this.onChanged);
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(label)),
      AleroSwitch(value: value, onChanged: onChanged, label: label),
    ],
  );
}

/// One-time setup: USB debugging, or wireless debugging paired with a code. Android's own, documented steps.
class _Setup extends StatelessWidget {
  const _Setup({
    required this.port,
    required this.code,
    required this.busy,
    required this.onPair,
  });
  final TextEditingController port, code;
  final bool busy;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    return Panel(
      title: 'Preparar el teléfono (una sola vez)',
      icon: Symbols.developer_mode_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, step) in const [
            'Ajustes › Información del teléfono › toca 7 veces «Número de compilación».',
            'Por cable: Ajustes › Sistema › Opciones de desarrollador › activa «Depuración USB», conecta el cable y toca «Permitir» en el teléfono.',
            'Por Wi-Fi: en Opciones de desarrollador activa «Depuración inalámbrica», toca «Vincular dispositivo con código de vinculación» y escribe aquí el puerto y el código.',
          ].indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.s),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 11,
                    backgroundColor: s.secondaryContainer,
                    child: Text(
                      '${i + 1}',
                      style: t.labelSmall?.copyWith(
                        color: s.onSecondaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: Gap.m),
                  Expanded(child: Text(step, style: t.bodyMedium)),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Puerto'),
                ),
              ),
              const SizedBox(width: Gap.s),
              Expanded(
                child: TextField(
                  controller: code,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Código'),
                ),
              ),
              const SizedBox(width: Gap.s),
              FilledButton.tonal(
                onPressed: busy ? null : onPair,
                child: const Text('Vincular'),
              ),
            ],
          ),
          const SizedBox(height: Gap.s),
          Text(
            'La depuración da control total del teléfono a los equipos autorizados. Desactívala cuando no la uses.',
            style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
