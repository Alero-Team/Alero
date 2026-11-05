import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'remote_ui.dart';
import 'theme.dart';

/// Alero Present uses the existing, authenticated PC input channel.
/// No ADB, browser automation, or privileged device access is required.
enum PresentationMode { powerpoint, browser }
enum PresentationAction { next, previous, start, finish }

typedef PresentationShortcut = ({String key, List<String> mods});

/// The desktop application must already be focused on Windows.
/// F5 starts a PowerPoint slideshow, but in a browser F5 would refresh the page,
/// so only the universal navigation/escape keys are supported there.
PresentationShortcut? presentationShortcut(
  PresentationMode mode,
  PresentationAction action,
) {
  switch (action) {
    case PresentationAction.next:
      return (key: 'right', mods: const []);
    case PresentationAction.previous:
      return (key: 'left', mods: const []);
    case PresentationAction.finish:
      return (key: 'esc', mods: const []);
    case PresentationAction.start:
      return mode == PresentationMode.powerpoint
          ? (key: 'f5', mods: const [])
          : null;
  }
}

Future<void> openAleroPresent(
  BuildContext context,
  Hub hub,
  String peer,
  String name,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => AleroPresentPage(hub, peer, name),
  ),
);

class AleroPresentPage extends StatefulWidget {
  const AleroPresentPage(this.hub, this.peer, this.name, {super.key});
  final Hub hub;
  final String peer, name;

  @override
  State<AleroPresentPage> createState() => _AleroPresentPageState();
}

class _AleroPresentPageState extends State<AleroPresentPage>
    with WidgetsBindingObserver {
  PresentationMode _mode = PresentationMode.powerpoint;
  Timer? _ticker;
  DateTime? _resumedAt;
  Duration _accumulated = Duration.zero;
  Duration _elapsed = Duration.zero;

  bool get _running => _resumedAt != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The timer measures elapsed wall time and does not hold the screen awake
    // or keep a background timer alive when Android leaves the foreground.
    if (state != AppLifecycleState.resumed) {
      _ticker?.cancel();
      _ticker = null;
    } else if (_running) {
      _tick();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
  }

  void _tick() {
    if (!mounted) return;
    setState(() {
      _elapsed = _accumulated + (_resumedAt == null
          ? Duration.zero
          : DateTime.now().difference(_resumedAt!));
    });
  }

  void _toggleTimer() {
    if (_running) {
      _accumulated = _elapsed;
      _resumedAt = null;
      _ticker?.cancel();
      _ticker = null;
    } else {
      _resumedAt = DateTime.now();
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
    _tick();
  }

  void _resetTimer() {
    _ticker?.cancel();
    _ticker = null;
    _resumedAt = null;
    _accumulated = Duration.zero;
    _tick();
  }

  void _send(PresentationAction action) {
    final shortcut = presentationShortcut(_mode, action);
    if (shortcut != null) {
      widget.hub.remote.key(
        widget.peer,
        shortcut.key,
        mods: shortcut.mods,
      );
    }
  }

  String get _time {
    final hours = _elapsed.inHours;
    final minutes = _elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = _elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours == 0 ? '$minutes:$seconds' : '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.hub,
    builder: (context, _) {
      final online = widget.hub.peers.any(
        (p) => p.id == widget.peer && p.state == pb.PeerState.connected,
      );
      final info = widget.hub.info[widget.peer];
      final blocked = remoteBlocker(info, online) ??
          (info?.canInput == false
              ? 'Este ordenador no permite controlar el teclado.'
              : null);
      final enabled = blocked == null;
      final t = Theme.of(context).textTheme;
      final s = Theme.of(context).colorScheme;
      return Scaffold(
        appBar: AppBar(title: const Text('Alero Present')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(Gap.xl),
            children: [
              Text('Presentación en ${widget.name}', style: t.titleLarge),
              const SizedBox(height: Gap.s),
              Text(
                'Utiliza el teclado remoto de Alero a través de la red local. '
                'La presentación debe estar abierta y enfocada en Windows.',
                style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
              ),
              const SizedBox(height: Gap.xl),
              SegmentedButton<PresentationMode>(
                segments: const [
                  ButtonSegment(
                    value: PresentationMode.powerpoint,
                    label: Text('PowerPoint'),
                    icon: Icon(Symbols.slideshow_rounded),
                  ),
                  ButtonSegment(
                    value: PresentationMode.browser,
                    label: Text('Navegador'),
                    icon: Icon(Symbols.language_rounded),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (values) => setState(() => _mode = values.first),
              ),
              const SizedBox(height: Gap.m),
              if (blocked != null)
                Text(blocked, style: TextStyle(color: s.error))
              else
                Text(
                  _mode == PresentationMode.powerpoint
                      ? 'F5 inicia una presentación de PowerPoint. '
                        'Las flechas avanzan o retroceden y Esc la termina.'
                      : 'Inicia el modo Presentar desde Google Slides u otro '
                        'servicio en la computadora. Las flechas cambian '
                        'diapositivas y Esc sale del modo presentación.',
                  style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                ),
              const SizedBox(height: Gap.xxl),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: enabled
                          ? () => _send(PresentationAction.previous)
                          : null,
                      icon: const Icon(Symbols.arrow_back_rounded),
                      label: const Text('Anterior'),
                    ),
                  ),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: enabled
                          ? () => _send(PresentationAction.next)
                          : null,
                      icon: const Icon(Symbols.arrow_forward_rounded),
                      label: const Text('Siguiente'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.m),
              Row(
                children: [
                  if (_mode == PresentationMode.powerpoint) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: enabled
                            ? () => _send(PresentationAction.start)
                            : null,
                        icon: const Icon(Symbols.play_arrow_rounded),
                        label: const Text('Iniciar'),
                      ),
                    ),
                    const SizedBox(width: Gap.m),
                  ],
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: enabled
                          ? () => _send(PresentationAction.finish)
                          : null,
                      icon: const Icon(Symbols.stop_rounded),
                      label: const Text('Salir (Esc)'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.xxl),
              Card.filled(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.l),
                  child: Column(
                    children: [
                      Text('Cronómetro de exposición', style: t.titleMedium),
                      const SizedBox(height: Gap.s),
                      Text(_time, style: t.displayMedium),
                      const SizedBox(height: Gap.s),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          FilledButton.tonal(
                            onPressed: _toggleTimer,
                            child: Text(_running ? 'Pausar' : 'Iniciar tiempo'),
                          ),
                          const SizedBox(width: Gap.s),
                          TextButton(
                            onPressed: _resetTimer,
                            child: const Text('Restablecer'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Gap.m),
              Text(
                'Los controles envían teclas al programa activo: Alero no '
                'puede confirmar qué diapositiva está mostrando Windows. '
                'No necesita depuración USB ni inalámbrica.',
                style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    },
  );
}
