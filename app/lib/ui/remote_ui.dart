import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../pc_remote.dart';
import '../remote.dart';
import 'expressive.dart';
import 'shell.dart' show confirm;
import 'theme.dart';

/// The phone as a touchpad for a paired computer. One finger moves the pointer, a tap clicks, two fingers scroll,
/// a two-finger tap right-clicks, and holding a finger still for a moment presses the button so the next movement
/// drags. Movement is sent in small batches (60 per second at most) as relative deltas, like a mouse.
class Touchpad extends StatefulWidget {
  const Touchpad(this.hub, this.peer, {super.key, this.height = 168, this.child, this.gain = 2.2});
  final Hub hub;
  final String peer;
  final double height;
  final double gain;

  /// Drawn under the gestures (the computer's screen, when watching it).
  final Widget? child;

  @override
  State<Touchpad> createState() => _TouchpadState();
}

class _TouchpadState extends State<Touchpad> {
  final _pointers = <int, Offset>{};
  final _clock = Stopwatch();
  Offset _start = Offset.zero;
  bool _moved = false, _drag = false, _two = false, _active = false;
  double _ax = 0, _ay = 0, _sy = 0, _sx = 0;
  Timer? _long, _flush;

  PcRemote get _r => widget.hub.remote;

  @override
  void dispose() {
    _long?.cancel();
    _flush?.cancel();
    if (_drag) _r.button(widget.peer, 'left', false);
    super.dispose();
  }

  void _tick() {
    final dx = _ax.truncate(), dy = _ay.truncate();
    if (dx != 0 || dy != 0) {
      _ax -= dx;
      _ay -= dy;
      _r.move(widget.peer, dx, dy);
    }
    // 30 px of two-finger travel = one wheel notch
    if (_sy.abs() >= 0.2 || _sx.abs() >= 0.2) {
      _r.scroll(widget.peer, dy: _sy, dx: _sx);
      _sy = _sx = 0;
    }
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 1) {
      _clock
        ..reset()
        ..start();
      _start = e.position;
      _moved = _drag = _two = false;
      _ax = _ay = _sy = _sx = 0;
      _flush ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
      _long = Timer(const Duration(milliseconds: 450), () {
        if (!_moved && _pointers.length == 1) {
          _drag = true;
          HapticFeedback.mediumImpact();
          _r.button(widget.peer, 'left', true);
          setState(() {});
        }
      });
    } else {
      _two = true;
      _long?.cancel();
    }
    setState(() => _active = true);
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 1) {
      if (!_moved && (e.position - _start).distance > 6) {
        _moved = true;
        _long?.cancel();
      }
      if (_moved || _drag) {
        _ax += e.delta.dx * widget.gain;
        _ay += e.delta.dy * widget.gain;
      }
    } else {
      _moved = true;
      _sy += e.delta.dy / _pointers.length / 30;
      _sx += e.delta.dx / _pointers.length / 30;
    }
  }

  void _up(PointerEvent e, {bool cancel = false}) {
    if (_pointers.remove(e.pointer) == null) return;
    if (_pointers.isNotEmpty) return;
    _long?.cancel();
    _tick();
    _flush?.cancel();
    _flush = null;
    if (_drag) {
      _r.button(widget.peer, 'left', false);
    } else if (!cancel && !_moved && _clock.elapsedMilliseconds < 300) {
      _r.click(widget.peer, button: _two ? 'right' : 'left');
      HapticFeedback.selectionClick();
    }
    _drag = false;
    setState(() => _active = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Semantics(
      label: 'Panel táctil del ordenador. Un dedo mueve el cursor, tocar hace clic, dos dedos desplazan.',
      child: Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: (e) => _up(e, cancel: true),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: motion(context, const Duration(milliseconds: 150)),
          height: widget.height,
          decoration: BoxDecoration(
            color: _active ? s.secondaryContainer : s.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.tile + 4),
            border: Border.all(color: s.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ?widget.child,
              if (widget.child == null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.l),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Symbols.touch_app_rounded, size: 28, color: s.onSurfaceVariant),
                        const SizedBox(height: Gap.xs),
                        Text(
                          'Desliza para mover · toca para clic\nDos dedos: desplazar o clic derecho',
                          textAlign: TextAlign.center,
                          style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_drag)
                Positioned(
                  top: Gap.s,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Chip(
                      label: const Text('Arrastrando'),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: s.primaryContainer,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A button that repeats while it is held (volume), with a normal tap for one step.
class HoldButton extends StatefulWidget {
  const HoldButton({super.key, required this.icon, required this.label, required this.onStep, this.repeat = true});
  final IconData icon;
  final String label;
  final VoidCallback onStep;
  final bool repeat;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> {
  Timer? _t;
  bool _down = false;

  void _stop() {
    _t?.cancel();
    if (_down) setState(() => _down = false);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        child: GestureDetector(
          onTapDown: (_) {
            setState(() => _down = true);
            widget.onStep();
            HapticFeedback.selectionClick();
            if (widget.repeat) {
              _t = Timer(const Duration(milliseconds: 400), () {
                _t = Timer.periodic(const Duration(milliseconds: 120), (_) => widget.onStep());
              });
            }
          },
          onTapUp: (_) => _stop(),
          onTapCancel: _stop,
          child: AnimatedScale(
            scale: _down ? 0.92 : 1,
            duration: motion(context, const Duration(milliseconds: 100)),
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: s.secondaryContainer, borderRadius: BorderRadius.circular(Radii.pill)),
              child: ExcludeSemantics(child: Icon(widget.icon, size: 22, color: s.onSecondaryContainer)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Why the controls are not usable, or null when they are. One wording for every place that shows them.
String? remoteBlocker(PeerInfo? i, bool online) {
  if (!online) return 'Sin conexión con el ordenador.';
  if (i == null) return 'Esperando los datos del ordenador…';
  if (!i.canInput && !i.canScreen) return 'Este ordenador todavía no admite el control remoto (solo Windows por ahora).';
  if (!i.remoteAllowed) return 'El control remoto está apagado en el ordenador. Actívalo allí en Alero › Ajustes › Control remoto.';
  return null;
}

/// Volume and playback, as one row of round buttons plus what is playing.
class PcMediaControls extends StatefulWidget {
  const PcMediaControls(this.hub, this.peer, {super.key, this.showNowPlaying = true});
  final Hub hub;
  final String peer;
  final bool showNowPlaying;

  @override
  State<PcMediaControls> createState() => _PcMediaControlsState();
}

class _PcMediaControlsState extends State<PcMediaControls> {
  @override
  void initState() {
    super.initState();
    widget.hub.remote.watchMedia(widget.peer);
  }

  @override
  void dispose() {
    widget.hub.remote.unwatchMedia(widget.peer);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.hub.remote, p = widget.peer;
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final m = widget.hub.media[p];
    final playing = m != null && m.active && m.title.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showNowPlaying)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.s),
            child: Row(
              children: [
                Icon(playing && m.playing ? Symbols.graphic_eq_rounded : Symbols.music_note_rounded, size: 18, color: s.onSurfaceVariant),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: Text(
                    playing ? [m.title, m.artist].where((x) => x.isNotEmpty).join(' · ') : 'Nada se está reproduciendo',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyMedium?.copyWith(color: playing ? s.onSurface : s.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          runSpacing: Gap.s,
          spacing: Gap.s,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                HoldButton(icon: Symbols.volume_down_rounded, label: 'Bajar volumen', onStep: () => r.media(p, 'volume_down')),
                const SizedBox(width: Gap.s),
                HoldButton(icon: Symbols.volume_off_rounded, label: 'Silenciar', repeat: false, onStep: () => r.media(p, 'mute')),
                const SizedBox(width: Gap.s),
                HoldButton(icon: Symbols.volume_up_rounded, label: 'Subir volumen', onStep: () => r.media(p, 'volume_up')),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                HoldButton(icon: Symbols.skip_previous_rounded, label: 'Anterior', repeat: false, onStep: () => r.media(p, 'prev')),
                const SizedBox(width: Gap.s),
                HoldButton(
                  icon: playing && m.playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                  label: 'Reproducir o pausar',
                  repeat: false,
                  onStep: () => r.media(p, 'toggle'),
                ),
                const SizedBox(width: Gap.s),
                HoldButton(icon: Symbols.skip_next_rounded, label: 'Siguiente', repeat: false, onStep: () => r.media(p, 'next')),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// Text and special keys for the computer. "Escribir en vivo" sends each character as it is typed; the
/// shortcut row sends the usual combinations. (IME suggestions can rewrite what was typed: turned off here.)
Future<void> openKeyboard(BuildContext context, Hub hub, String peer) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _KeyboardSheet(hub, peer),
);

class _KeyboardSheet extends StatefulWidget {
  const _KeyboardSheet(this.hub, this.peer);
  final Hub hub;
  final String peer;

  @override
  State<_KeyboardSheet> createState() => _KeyboardSheetState();
}

class _KeyboardSheetState extends State<_KeyboardSheet> {
  final _c = TextEditingController();
  String _prev = '';

  PcRemote get _r => widget.hub.remote;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _changed(String now) {
    // Send only what changed since the last event: appended text, or backspaces for removed characters.
    if (now.startsWith(_prev)) {
      final add = now.substring(_prev.length);
      if (add.isNotEmpty) _r.text(widget.peer, add);
    } else if (_prev.startsWith(now)) {
      for (var i = 0; i < _prev.length - now.length; i++) {
        _r.key(widget.peer, 'backspace');
      }
    } else {
      // Rewritten by the keyboard (autocorrect): replace the whole word.
      for (var i = 0; i < _prev.length; i++) {
        _r.key(widget.peer, 'backspace');
      }
      _r.text(widget.peer, now);
    }
    _prev = now;
  }

  Widget _key(String label, String key, {List<String> mods = const [], IconData? icon}) => OutlinedButton(
    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 44), padding: const EdgeInsets.symmetric(horizontal: Gap.m)),
    onPressed: () {
      HapticFeedback.selectionClick();
      _r.key(widget.peer, key, mods: mods);
    },
    child: icon != null ? Icon(icon, size: 20, semanticLabel: label) : Text(label),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, MediaQuery.viewInsetsOf(context).bottom + Gap.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Teclado del ordenador', style: t.titleLarge),
          const SizedBox(height: Gap.xs),
          Text('Lo que escribas aquí se escribe en el ordenador, en la ventana activa.', style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
          const SizedBox(height: Gap.l),
          TextField(
            controller: _c,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            minLines: 1,
            maxLines: 3,
            onChanged: _changed,
            decoration: const InputDecoration(hintText: 'Escribe aquí'),
          ),
          const SizedBox(height: Gap.m),
          Wrap(
            spacing: Gap.s,
            runSpacing: Gap.s,
            children: [
              _key('Esc', 'esc'),
              _key('Tab', 'tab'),
              _key('Intro', 'enter', icon: Symbols.keyboard_return_rounded),
              _key('Borrar', 'backspace', icon: Symbols.backspace_rounded),
              _key('Suprimir', 'delete'),
              _key('Izquierda', 'left', icon: Symbols.arrow_back_rounded),
              _key('Arriba', 'up', icon: Symbols.arrow_upward_rounded),
              _key('Abajo', 'down', icon: Symbols.arrow_downward_rounded),
              _key('Derecha', 'right', icon: Symbols.arrow_forward_rounded),
              _key('Copiar', 'c', mods: const ['ctrl'], icon: Symbols.content_copy_rounded),
              _key('Pegar', 'v', mods: const ['ctrl'], icon: Symbols.content_paste_rounded),
              _key('Deshacer', 'z', mods: const ['ctrl'], icon: Symbols.undo_rounded),
              _key('Alt+Tab', 'tab', mods: const ['alt']),
              _key('Windows', 'win'),
            ],
          ),
        ],
      ),
    );
  }
}

/// Lock and sleep, each behind a confirmation (there is deliberately no shutdown).
class PowerActions extends StatelessWidget {
  const PowerActions(this.hub, this.peer, this.name, {super.key});
  final Hub hub;
  final String peer, name;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: Gap.s,
    runSpacing: Gap.s,
    children: [
      OutlinedButton.icon(
        onPressed: () async {
          if (await confirm(context, '¿Bloquear $name?', 'Se bloquea la sesión de Windows. Para volver hay que iniciar sesión en el ordenador.', 'Bloquear')) {
            hub.remote.power(peer, 'lock');
          }
        },
        icon: const Icon(Symbols.lock_rounded, size: 18),
        label: const Text('Bloquear'),
      ),
      OutlinedButton.icon(
        onPressed: () async {
          if (await confirm(context, '¿Suspender $name?', 'El ordenador se duerme y la conexión se pierde hasta que lo despiertes.', 'Suspender')) {
            hub.remote.power(peer, 'sleep');
          }
        },
        icon: const Icon(Symbols.bedtime_rounded, size: 18),
        label: const Text('Suspender'),
      ),
    ],
  );
}
