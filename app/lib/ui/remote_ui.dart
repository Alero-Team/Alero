import 'dart:async';

import 'package:flutter/material.dart' hide Icon;
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../pc_remote.dart';
import '../remote.dart';
import 'expressive.dart';
import 'shell.dart' show confirm;
import 'theme.dart';
import 'widgets.dart' show FitLabel;
import 'icon.dart';

/// The phone as a touchpad for a paired computer. One finger moves the pointer, a tap clicks, a two-finger tap
/// right-clicks, two fingers scroll (naturally, both axes),
/// and a second tap held down drags until the finger lifts. Movement is sent in small batches (60 per second at most) as relative deltas, like a mouse.
class Touchpad extends StatefulWidget {
  const Touchpad(
    this.hub,
    this.peer, {
    super.key,
    this.height = 168,
    this.child,
    this.gain = 2.2,
  });
  final Hub hub;
  final String peer;
  final double height;
  final double gain;

  /// Drawn under the gestures (the computer's screen, when watching it).
  final Widget? child;

  @override
  State<Touchpad> createState() => _TouchpadState();
}

class _TouchpadState extends State<Touchpad> with WidgetsBindingObserver {
  final _pointers = <int, Offset>{};
  bool _tapExpired = false;
  Offset _start = Offset.zero;
  bool _moved = false,
      _drag = false,
      _two = false,
      _active = false,
      _cancelled = false;
  Offset? _finger;
  double _ax = 0, _ay = 0, _sy = 0, _sx = 0, _travel = 0;
  Timer? _flush, _tap;
  DateTime? _lastTap;
  Offset? _lastTapPosition;

  PcRemote get _r => widget.hub.remote;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _release(PcRemote remote, String peer) {
    _tap?.cancel();
    _flush?.cancel();
    _flush = null;
    if (_drag) remote.button(peer, 'left', false);
    _lastTap = null;
    _pointers.clear();
    _ax = _ay = _sx = _sy = 0;
    _drag = _active = false;
    _finger = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _release(_r, widget.peer);
      if (mounted) setState(() {});
    }
  }

  @override
  void didUpdateWidget(Touchpad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peer != widget.peer || oldWidget.hub != widget.hub) {
      _release(oldWidget.hub.remote, oldWidget.peer);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _release(_r, widget.peer);
    super.dispose();
  }

  void _tick({bool finish = false}) {
    final dx = _ax.truncate(), dy = _ay.truncate();
    if (dx != 0 || dy != 0) {
      _ax -= dx;
      _ay -= dy;
      _r.move(widget.peer, dx, dy);
    }
    // 30 px of two-finger travel = one wheel notch
    if (_sy.abs() >= 0.2 ||
        _sx.abs() >= 0.2 ||
        (finish && (_sy != 0 || _sx != 0))) {
      _r.scroll(widget.peer, dy: _sy, dx: _sx);
      _sy = _sx = 0;
    }
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 1) {
      _tapExpired = false;
      _tap?.cancel();
      _tap = Timer(const Duration(milliseconds: 300), () => _tapExpired = true);
      _start = e.position;
      _moved = _drag = _two = _cancelled = false;
      _ax = _ay = _sy = _sx = _travel = 0;
      _flush ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _tick(),
      );
      final last = _lastTap;
      if (last != null &&
          DateTime.now().difference(last).inMilliseconds <= 350 &&
          (e.position - (_lastTapPosition ?? e.position)).distance <= 40 &&
          !_r.buttonHeld(widget.peer, 'left')) {
        _drag = true;
        _lastTap = null;
        _r.button(widget.peer, 'left', true);
        HapticFeedback.selectionClick();
      }
    } else {
      _two = true;
      _lastTap = null;
      if (_drag) {
        _r.button(widget.peer, 'left', false);
        _drag = false;
      }
    }
    setState(() {
      _active = true;
      _finger = e.localPosition;
    });
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    if (_cancelled) return;
    _pointers[e.pointer] = e.position;
    setState(() => _finger = e.localPosition);
    if (_pointers.length == 1) {
      // Lifting one finger after scrolling must not move the cursor with the remaining finger.
      if (_two || _cancelled) return;
      if (!_moved && (e.position - _start).distance > 6) {
        _moved = true;
      }
      if (_moved || _drag) {
        _ax += e.delta.dx * widget.gain;
        _ay += e.delta.dy * widget.gain;
      }
    } else {
      _moved = true;
      _travel += e.delta.distance;
      _sy += e.delta.dy / _pointers.length / 30;
      // Natural like the vertical one: the content follows the fingers (swipe left, the page goes left).
      _sx -= e.delta.dx / _pointers.length / 30;
    }
  }

  void _up(PointerEvent e, {bool cancel = false}) {
    if (_pointers.remove(e.pointer) == null) return;
    _cancelled = _cancelled || cancel;
    if (cancel) {
      if (_drag) _r.button(widget.peer, 'left', false);
      _drag = false;
      _ax = _ay = _sx = _sy = 0;
    }
    if (_pointers.isNotEmpty) return;
    _tap?.cancel();
    if (!_cancelled) _tick(finish: true);
    _flush?.cancel();
    _flush = null;
    if (_drag) {
      _r.button(widget.peer, 'left', false);
    } else if (!_cancelled && _two && !_tapExpired && _travel < 24) {
      // Two-finger tap: right click, like a laptop touchpad.
      _r.click(widget.peer, button: 'right');
      HapticFeedback.selectionClick();
    } else if (!_cancelled && !_two && !_moved && !_tapExpired) {
      if (!_r.buttonHeld(widget.peer, 'left') &&
          !_r.buttonHeld(widget.peer, 'right')) {
        _lastTap = DateTime.now();
        _lastTapPosition = e.position;
        _r.click(widget.peer);
      }
      HapticFeedback.selectionClick();
    }
    _drag = false;
    setState(() {
      _active = false;
      _finger = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Semantics(
      label: 'Panel táctil del ordenador',
      hint: 'Un dedo mueve el cursor. Toca para clic. Toca con dos dedos para clic derecho. Dos dedos desplazan. Toca dos veces y mueve sin levantar el segundo toque para seleccionar.',
      onTap: () => _r.click(widget.peer),
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
            color: s.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Radii.tile + 4),
            border: Border.all(
              color: _active ? s.outline : s.outlineVariant,
              width: _active ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ?widget.child,
              if (widget.child == null)
                ExcludeSemantics(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.l),
                      child: LayoutBuilder(
                        builder: (context, box) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (box.maxHeight >= 120) ...[
                              Icon(
                                Symbols.mouse_rounded,
                                size: 32,
                                color: s.onSurfaceVariant,
                              ),
                              const SizedBox(height: Gap.m),
                            ],
                            Text(
                              _drag
                                  ? 'Arrastrando'
                                  : _two && _active
                                  ? 'Desplazando'
                                  : 'Desliza para mover el cursor',
                              textAlign: TextAlign.center,
                              style: weight(t.bodyMedium, 500),
                            ),
                            if (box.maxHeight >= 160) ...[
                              const SizedBox(height: Gap.s),
                              Text(
                                'Un toque: clic · Dos dedos: clic derecho\nDesliza con dos dedos: desplazar\nDoble toque y mueve: seleccionar',
                                textAlign: TextAlign.center,
                                style: t.bodySmall?.copyWith(
                                  color: s.onSurfaceVariant,
                                  height: 1.6,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_finger != null)
                Positioned(
                  left: _finger!.dx - 18,
                  top: _finger!.dy - 18,
                  child: IgnorePointer(
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: s.onSurface.withValues(alpha: .06),
                        border: Border.all(
                          color: s.onSurface.withValues(alpha: .35),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_drag && widget.child != null)
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

/// Mouse buttons stay selected until tapped again, including while the pad is moved.
class MouseActionBar extends StatefulWidget {
  const MouseActionBar(this.hub, this.peer, {super.key});
  final Hub hub;
  final String peer;
  @override
  State<MouseActionBar> createState() => _MouseActionBarState();
}

class _MouseActionBarState extends State<MouseActionBar>
    with WidgetsBindingObserver {
  final _held = <String>{};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _release(Hub hub, String peer) {
    for (final b in _held) {
      hub.remote.button(peer, b, false);
    }
    _held.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s != AppLifecycleState.resumed) {
      _release(widget.hub, widget.peer);
      if (mounted) setState(() {});
    }
  }

  @override
  void didUpdateWidget(MouseActionBar old) {
    super.didUpdateWidget(old);
    if (old.peer != widget.peer || old.hub != widget.hub) {
      _release(old.hub, old.peer);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _release(widget.hub, widget.peer);
    super.dispose();
  }

  Widget _button(String button, String label) => Expanded(
    child: Semantics(
      label: 'Clic $label',
      button: true,
      toggled: _held.contains(button),
      onTap: () => _toggle(button),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _toggle(button),
        onPointerCancel: (_) => _up(button),
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: _held.contains(button)
                ? Theme.of(context).colorScheme.secondaryContainer
                : Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Radii.tile),
          ),
          child: ExcludeSemantics(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                MouseButtonIcon(left: button == 'left'),
                const SizedBox(height: Gap.xs),
                Text(
                  _held.contains(button)
                      ? 'Soltar ${button == 'left' ? 'izq.' : 'der.'}'
                      : label,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  void _toggle(String button) {
    if (_held.contains(button)) {
      _up(button);
    } else {
      _held.add(button);
      widget.hub.remote.button(widget.peer, button, true);
      setState(() {});
    }
    HapticFeedback.selectionClick();
  }

  void _up(String button) {
    if (_held.remove(button)) {
      widget.hub.remote.button(widget.peer, button, false);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _button('left', 'Izquierdo'),
      const SizedBox(width: Gap.s),
      _button('right', 'Derecho'),
      const SizedBox(width: Gap.s),
      Expanded(
        child: FilledButton.tonal(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 64)),
          onPressed: () => openKeyboard(context, widget.hub, widget.peer),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.keyboard_rounded, size: 22),
              SizedBox(height: Gap.xs),
              Text('Teclado'),
            ],
          ),
        ),
      ),
    ],
  );
}

/// A mouse outline with the left or right button filled in, in the current icon colour.
class MouseButtonIcon extends StatelessWidget {
  const MouseButtonIcon({super.key, required this.left, this.size = 24});
  final bool left;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _MousePainter(
      left,
      IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface,
    ),
  );
}

class _MousePainter extends CustomPainter {
  _MousePainter(this.left, this.color);
  final bool left;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final stroke = s.width * 0.08;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        s.width * 0.22,
        s.height * 0.06,
        s.width * 0.56,
        s.height * 0.88,
      ),
      Radius.circular(s.width * 0.28),
    );
    final split = body.top + body.height * 0.42;
    final half = left
        ? Rect.fromLTRB(body.left, body.top, body.center.dx, split)
        : Rect.fromLTRB(body.center.dx, body.top, body.right, split);
    canvas.save();
    canvas.clipRRect(body);
    canvas.drawRect(half, Paint()..color = color);
    canvas.restore();
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawRRect(body, line);
    canvas.drawLine(Offset(body.left, split), Offset(body.right, split), line);
    canvas.drawLine(
      Offset(body.center.dx, body.top),
      Offset(body.center.dx, split),
      line,
    );
  }

  @override
  bool shouldRepaint(_MousePainter old) =>
      old.left != left || old.color != color;
}

class PointerSensitivity extends StatelessWidget {
  const PointerSensitivity({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<double>(
    tooltip: 'Sensibilidad del cursor',
    icon: const Icon(Symbols.tune_rounded),
    initialValue: value,
    onSelected: onChanged,
    itemBuilder: (_) => [
      for (final option in const [
        (1.2, 'Precisa'),
        (2.2, 'Normal'),
        (3.2, 'Rápida'),
      ])
        CheckedPopupMenuItem(
          value: option.$1,
          checked: value == option.$1,
          child: Text(option.$2),
        ),
    ],
  );
}

/// A button that repeats while it is held (volume), with a normal tap for one step.
class HoldButton extends StatefulWidget {
  const HoldButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onStep,
    this.repeat = true,
  });
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
                _t = Timer.periodic(
                  const Duration(milliseconds: 120),
                  (_) => widget.onStep(),
                );
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
              decoration: BoxDecoration(
                color: s.secondaryContainer,
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: ExcludeSemantics(
                child: Icon(
                  widget.icon,
                  size: 22,
                  color: s.onSecondaryContainer,
                ),
              ),
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
  if (!i.canInput && !i.canScreen) {
    return 'Este ordenador todavía no admite el control remoto (solo Windows por ahora).';
  }
  if (!i.remoteAllowed) {
    return 'El control remoto está apagado en el ordenador. Actívalo allí en Alero › Ajustes › Control remoto.';
  }
  return null;
}

/// Volume and playback, as one row of round buttons plus what is playing.
class PcMediaControls extends StatefulWidget {
  const PcMediaControls(
    this.hub,
    this.peer, {
    super.key,
    this.showNowPlaying = true,
  });
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
  void didUpdateWidget(PcMediaControls old) {
    super.didUpdateWidget(old);
    if (old.peer != widget.peer || old.hub != widget.hub) {
      old.hub.remote.unwatchMedia(old.peer);
      widget.hub.remote.watchMedia(widget.peer);
    }
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
                Icon(
                  playing && m.playing
                      ? Symbols.graphic_eq_rounded
                      : Symbols.music_note_rounded,
                  size: 18,
                  color: s.onSurfaceVariant,
                ),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: Text(
                    playing
                        ? [
                            m.title,
                            m.artist,
                          ].where((x) => x.isNotEmpty).join(' · ')
                        : 'Nada se está reproduciendo',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyMedium?.copyWith(
                      color: playing ? s.onSurface : s.onSurfaceVariant,
                    ),
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
                HoldButton(
                  icon: Symbols.volume_down_rounded,
                  label: 'Bajar volumen',
                  onStep: () => r.media(p, 'volume_down'),
                ),
                const SizedBox(width: Gap.s),
                HoldButton(
                  icon: Symbols.volume_off_rounded,
                  label: 'Silenciar',
                  repeat: false,
                  onStep: () => r.media(p, 'mute'),
                ),
                const SizedBox(width: Gap.s),
                HoldButton(
                  icon: Symbols.volume_up_rounded,
                  label: 'Subir volumen',
                  onStep: () => r.media(p, 'volume_up'),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                HoldButton(
                  icon: Symbols.skip_previous_rounded,
                  label: 'Anterior',
                  repeat: false,
                  onStep: () => r.media(p, 'prev'),
                ),
                const SizedBox(width: Gap.s),
                HoldButton(
                  icon: playing && m.playing
                      ? Symbols.pause_rounded
                      : Symbols.play_arrow_rounded,
                  label: 'Reproducir o pausar',
                  repeat: false,
                  onStep: () => r.media(p, 'toggle'),
                ),
                const SizedBox(width: Gap.s),
                HoldButton(
                  icon: Symbols.skip_next_rounded,
                  label: 'Siguiente',
                  repeat: false,
                  onStep: () => r.media(p, 'next'),
                ),
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
Future<void> openKeyboard(BuildContext context, Hub hub, String peer) =>
    showModalBottomSheet<void>(
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

  Widget _key(
    String label,
    String key, {
    List<String> mods = const [],
    IconData? icon,
  }) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 44),
      padding: const EdgeInsets.symmetric(horizontal: Gap.m),
    ),
    onPressed: () {
      HapticFeedback.selectionClick();
      _r.key(widget.peer, key, mods: mods);
    },
    child: icon != null
        ? Icon(icon, size: 20, semanticLabel: label)
        : Text(label),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Gap.xl,
        0,
        Gap.xl,
        MediaQuery.viewInsetsOf(context).bottom + Gap.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Teclado del ordenador', style: t.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(
            'Lo que escribas aquí se escribe en el ordenador, en la ventana activa.',
            style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
          ),
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
              _key(
                'Copiar',
                'c',
                mods: const ['ctrl'],
                icon: Symbols.content_copy_rounded,
              ),
              _key(
                'Pegar',
                'v',
                mods: const ['ctrl'],
                icon: Symbols.content_paste_rounded,
              ),
              _key(
                'Deshacer',
                'z',
                mods: const ['ctrl'],
                icon: Symbols.undo_rounded,
              ),
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
          if (await confirm(
            context,
            '¿Bloquear $name?',
            'Se bloquea la sesión de Windows. Para volver hay que iniciar sesión en el ordenador.',
            'Bloquear',
          )) {
            hub.remote.power(peer, 'lock');
          }
        },
        icon: const Icon(Symbols.lock_rounded, size: 18),
        label: const FitLabel('Bloquear'),
      ),
      OutlinedButton.icon(
        onPressed: () async {
          if (await confirm(
            context,
            '¿Suspender $name?',
            'El ordenador se duerme y la conexión se pierde hasta que lo despiertes.',
            'Suspender',
          )) {
            hub.remote.power(peer, 'sleep');
          }
        },
        icon: const Icon(Symbols.bedtime_rounded, size: 18),
        label: const FitLabel('Suspender'),
      ),
    ],
  );
}
