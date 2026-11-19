import 'dart:io';

import 'package:flutter/material.dart' hide Icon, Text;
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../island_prefs.dart';
import '../l10n.dart';
import 'expressive.dart' show Spring, motion;
import 'icon.dart';
import 'alero_motion.dart';
import 'settings.dart' show AleroSegments;
import 'theme.dart';
import 'widgets.dart';

/// Backgrounds offered for the island (the first one, pure black, is the default and the best on OLED screens).
const _backgrounds = <(String, String)>[
  ('#000000', 'OLED'),
  ('#1B1B1B', 'Grafito'),
  ('#0B1220', 'Azul noche'),
  ('#1E0B14', 'Vino'),
  ('#0B1A14', 'Bosque'),
  ('#F2F2F2', 'Claro'),
];

const _accents = <(String, String)>[
  ('#FFFFFF', 'Alero'),
  ('#8AB4F8', 'Azul'),
  ('#81C995', 'Verde'),
  ('#F28B82', 'Coral'),
  ('#FDD663', 'Ámbar'),
  ('#C58AF9', 'Violeta'),
];

/// The island's phone controls, in the order they are drawn. The last four need wireless debugging (adb).
const _controlNames = <String, (String, IconData)>{
  'dnd': ('No molestar', Symbols.do_not_disturb_on_rounded),
  'torch': ('Linterna', Symbols.flashlight_on_rounded),
  'find': ('Buscar', Symbols.my_location_rounded),
  'ringer': ('Sonido', Symbols.volume_up_rounded),
  'wifi': ('Wi-Fi', Symbols.wifi_rounded),
  'bt': ('Bluetooth', Symbols.bluetooth_rounded),
  'rotate': ('Rotación', Symbols.screen_rotation_rounded),
  'lock': ('Bloquear', Symbols.lock_rounded),
};

const _moduleNames = <String, (String, IconData)>{
  'player': ('Reproductor', Symbols.music_note_rounded),
  'send': ('Enviar archivos arrastrando', Symbols.upload_rounded),
  'incoming': ('Archivos entrantes', Symbols.download_rounded),
  'notifications': (
    'Notificaciones del teléfono',
    Symbols.notifications_rounded,
  ),
  'call': ('Llamadas entrantes', Symbols.call_rounded),
  'clipboard': ('Portapapeles', Symbols.content_paste_rounded),
  'controls': ('Controles rápidos', Symbols.tune_rounded),
  'status': ('Estado y batería del teléfono', Symbols.smartphone_rounded),
};

Color _hex(String s) {
  final v = int.tryParse(s.replaceFirst('#', ''), radix: 16) ?? 0;
  return Color(0xFF000000 | v);
}

/// Ajustes › Alero Island: everything the overlay can be told, written to `island.json` as it changes.
class IslandPanel extends StatefulWidget {
  const IslandPanel(this.hub, {super.key});
  final Hub hub;

  @override
  State<IslandPanel> createState() => _IslandPanelState();
}

class _IslandPanelState extends State<IslandPanel> {
  late final IslandPrefs p = IslandPrefs(widget.hub.islandFile);

  @override
  void dispose() {
    p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: p,
    builder: (context, _) {
      final on = p.flag('enabled');
      return Panel(
        title: 'Alero Island',
        icon: Symbols.expand_content_rounded,
        action: on
            ? TextButton(onPressed: p.reset, child: const Text('Restablecer'))
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingTile(
              title: 'Activar Alero Island',
              subtitle: 'Una isla que baja desde el borde superior de la pantalla cuando pasas el ratón por el centro, con reproductor, archivos, notificaciones y llamadas del teléfono.',
              trailing: AleroSwitch(
                value: on,
                onChanged: (v) => p.set('enabled', v),
                label: tx('Activar Alero Island'),
              ),
              onTap: () => p.set('enabled', !on),
            ),
            ArcExpand(
              expanded: on,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Title('Aspecto'),
                  _Swatches(
                    title: 'Color de fondo',
                    options: _backgrounds,
                    value: p.text('color'),
                    onChanged: (v) => p.set('color', v),
                  ),
                  _Swatches(
                    title: 'Color de acento',
                    options: _accents,
                    value: p.text('accent'),
                    onChanged: (v) => p.set('accent', v),
                  ),
                  _Pick(
                    title: 'Tamaño',
                    child: AleroSegments<int>(
                      segments: const [
                        ButtonSegment(value: 85, label: FitLabel('Pequeña')),
                        ButtonSegment(value: 100, label: FitLabel('Mediana')),
                        ButtonSegment(value: 125, label: FitLabel('Grande')),
                      ],
                      selected: const [85, 100, 125].contains(p.number('scale'))
                          ? p.number('scale')
                          : null,
                      onChanged: (v) => p.set('scale', v),
                    ),
                  ),
                  _Slide(
                    title: 'Tamaño exacto',
                    value: p.number('scale'),
                    min: 75,
                    max: 150,
                    suffix: '%',
                    onChanged: (v) => p.set('scale', v),
                  ),
                  _Pick(
                    title: 'Animaciones',
                    child: AleroSegments<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'normal',
                          label: FitLabel('Normales'),
                        ),
                        ButtonSegment(value: 'soft', label: FitLabel('Suaves')),
                        ButtonSegment(value: 'off', label: FitLabel('Ninguna')),
                      ],
                      selected: p.text('animation'),
                      onChanged: (v) => p.set('animation', v),
                    ),
                  ),
                  _Toggle(
                    title: 'Respetar «reducir animaciones» del sistema',
                    value: p.flag('respect_reduce_motion'),
                    onChanged: (v) => p.set('respect_reduce_motion', v),
                  ),
                  const _Title('Cuándo aparece'),
                  _Pick(
                    title: 'Pantalla',
                    // A popup menu rather than DropdownButton: its route timing is fixed, this one takes the Fluent style.
                    child: _Monitor(
                      value: const [-1, 0, 1, 2].contains(p.number('monitor'))
                          ? p.number('monitor')
                          : -1,
                      onChanged: (v) => p.set('monitor', v),
                    ),
                  ),
                  _Slide(
                    title: 'Ancho de la zona de activación',
                    value: p.number('zone_width'),
                    min: 100,
                    max: 400,
                    suffix: ' px',
                    onChanged: (v) => p.set('zone_width', v),
                  ),
                  _Slide(
                    title: 'Espera antes de abrirse',
                    value: p.number('open_delay_ms'),
                    min: 0,
                    max: 500,
                    step: 10,
                    suffix: ' ms',
                    onChanged: (v) => p.set('open_delay_ms', v),
                  ),
                  _Slide(
                    title: 'Espera antes de cerrarse',
                    value: p.number('close_delay_ms'),
                    min: 0,
                    max: 1000,
                    step: 50,
                    suffix: ' ms',
                    onChanged: (v) => p.set('close_delay_ms', v),
                  ),
                  _Slide(
                    title: 'Desplazamiento horizontal',
                    value: p.number('offset_x'),
                    min: -300,
                    max: 300,
                    step: 5,
                    suffix: ' px',
                    onChanged: (v) => p.set('offset_x', v),
                  ),
                  _Toggle(
                    title: 'Ocultar con juegos y apps a pantalla completa',
                    value: p.flag('hide_fullscreen'),
                    onChanged: (v) => p.set('hide_fullscreen', v),
                  ),
                  if (Platform.isWindows) _Hotkey(p),
                  const _Title('Qué muestra'),
                  for (final e in _moduleNames.entries)
                    _Toggle(
                      title: e.value.$1,
                      icon: e.value.$2,
                      value: p.module(e.key),
                      onChanged: (v) => p.setModule(e.key, v),
                    ),
                  ArcExpand(
                    expanded: p.module('controls'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _Title('Controles del teléfono'),
                        _Controls(p),
                      ],
                    ),
                  ),
                  const _Title('Avisos'),
                  _Toggle(
                    title:
                        'Abrirse sola con llamadas, archivos y notificaciones',
                    value: p.flag('auto_expand'),
                    onChanged: (v) => p.set('auto_expand', v),
                  ),
                  ArcExpand(
                    expanded: p.flag('auto_expand'),
                    child: _Slide(
                      title: 'Segundos visible',
                      value: p.number('event_secs'),
                      min: 3,
                      max: 15,
                      suffix: ' s',
                      onChanged: (v) => p.set('event_secs', v),
                    ),
                  ),
                  _Toggle(
                    title: 'Sonido en llamadas y archivos entrantes',
                    value: p.flag('sound'),
                    onChanged: (v) => p.set('sound', v),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _Title extends StatelessWidget {
  const _Title(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.l, 0, Gap.xs),
    child: Text(
      tx(text),
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: context.pal.muted),
    ),
  );
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.title,
    required this.value,
    required this.onChanged,
    this.icon,
  });
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => SettingTile(
    leading: icon == null
        ? null
        : Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
    title: title,
    trailing: AleroSwitch(value: value, onChanged: onChanged, label: tx(title)),
    onTap: () => onChanged(!value),
  );
}

class _Pick extends StatelessWidget {
  const _Pick({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      tx(title),
      style: weight(Theme.of(context).textTheme.bodyLarge, 500),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.s),
      // Narrow panel: the control goes under its title at full width instead of being squeezed beside it.
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth < 520
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  label,
                  const SizedBox(height: Gap.s),
                  Align(alignment: Alignment.centerLeft, child: child),
                ],
              )
            : Row(
                children: [
                  Expanded(child: label),
                  const SizedBox(width: Gap.m),
                  Flexible(child: child),
                ],
              ),
      ),
    );
  }
}

class _Slide extends StatelessWidget {
  const _Slide({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.suffix = '',
    this.step = 1,
  });
  final String title;
  final int value, min, max, step;
  final String suffix;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final v = value.clamp(min, max);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(tx(title), style: weight(t.bodyLarge, 500))),
              Text(
                '$v$suffix',
                style: t.bodyMedium?.copyWith(color: context.pal.muted),
              ),
            ],
          ),
          Slider(
            value: v.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: ((max - min) / step).round(),
            onChanged: (d) => onChanged((d / step).round() * step),
          ),
        ],
      ),
    );
  }
}

class _Swatches extends StatefulWidget {
  const _Swatches({
    required this.title,
    required this.options,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final List<(String, String)> options;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_Swatches> createState() => _SwatchesState();
}

class _SwatchesState extends State<_Swatches> {
  late final c = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_Swatches old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && normalizeHex(c.text) != widget.value) {
      c.text = widget.value;
    }
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final cur = widget.value.toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tx(widget.title), style: weight(t.bodyLarge, 500)),
          const SizedBox(height: Gap.s),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: Gap.s,
                  runSpacing: Gap.s,
                  children: [
                    for (final (hex, name) in widget.options)
                      Semantics(
                        label: tx(name),
                        selected: cur == hex,
                        button: true,
                        child: Tooltip(
                          message: tx(name),
                          child: AleroPress(
                            radius: 17,
                            onTap: () => widget.onChanged(hex),
                            child: AnimatedContainer(
                              duration: AleroMotion.micro(
                                context,
                                Fluent.d167,
                              ),
                              curve: Fluent.enter,
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: _hex(hex),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: cur == hex
                                      ? s.primary
                                      : s.outlineVariant,
                                  width: cur == hex ? 2.5 : 1,
                                ),
                              ),
                              // Always mounted so the tick scales in and out instead of popping.
                              child: AnimatedScale(
                                scale: cur == hex ? 1 : 0,
                                duration: AleroMotion.micro(
                                  context,
                                  Fluent.d167,
                                ),
                                curve: Fluent.enter,
                                child: Icon(
                                  Symbols.check_rounded,
                                  size: 18,
                                  color: _hex(hex).computeLuminance() > 0.5
                                      ? Colors.black
                                      : Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Gap.m),
              SizedBox(
                width: 112,
                child: TextField(
                  controller: c,
                  maxLength: 7,
                  decoration: InputDecoration(
                    isDense: true,
                    counterText: '',
                    labelText: tx('Hex'),
                  ),
                  onChanged: (v) {
                    final n = normalizeHex(v);
                    if (n != null) widget.onChanged(n);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Hotkey extends StatefulWidget {
  const _Hotkey(this.p);
  final IslandPrefs p;

  @override
  State<_Hotkey> createState() => _HotkeyState();
}

/// Which phone controls the island shows: tap to add or remove; they keep the order of [_controlNames].
class _Controls extends StatelessWidget {
  const _Controls(this.p);
  final IslandPrefs p;

  @override
  Widget build(BuildContext context) {
    final on = p.text('controls').split(',').toSet();
    void toggle(String k) {
      final next = {...on};
      if (!next.remove(k)) next.add(k);
      p.set('controls', _controlNames.keys.where(next.contains).join(','));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Gap.s,
            runSpacing: Gap.s,
            children: [
              for (final e in _controlNames.entries)
                FilterChip(
                  avatar: Icon(e.value.$2, size: 18),
                  label: Text(e.value.$1),
                  selected: on.contains(e.key),
                  chipAnimationStyle: ChipAnimationStyle(
                    selectAnimation: AnimationStyle(
                      duration: AleroMotion.micro(context, Fluent.d167),
                      curve: Fluent.enter,
                    ),
                    avatarDrawerAnimation: AnimationStyle(
                      duration: AleroMotion.micro(context, Fluent.d167),
                      curve: Fluent.enter,
                    ),
                  ),
                  onSelected: (_) => toggle(e.key),
                ),
            ],
          ),
          const SizedBox(height: Gap.s),
          Text(
            'Wi-Fi, Bluetooth, Rotación y Bloquear aparecen cuando el teléfono tiene la depuración inalámbrica activa.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: context.pal.muted),
          ),
        ],
      ),
    );
  }
}

/// The combination as the daemon reads it ("Ctrl+Alt+I"), or null for a key it can't register.
String? hotkeyCombo(LogicalKeyboardKey k, Set<LogicalKeyboardKey> held) {
  final l = k.keyLabel;
  final String key;
  if (k == LogicalKeyboardKey.space) {
    key = 'Space';
  } else if (RegExp(r'^(F([1-9]|1[0-2])|[A-Z0-9])$')
          .hasMatch(l.toUpperCase()) &&
      l.length <= 3) {
    key = l.toUpperCase();
  } else {
    return null;
  }
  bool any(List<LogicalKeyboardKey> ks) => ks.any(held.contains);
  final mods = [
    if (any([LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight]))
      'Ctrl',
    if (any([LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight])) 'Alt',
    if (any([LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight]))
      'Shift',
    if (any([LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight])) 'Win',
  ];
  // A bare key would be stolen from every program: the daemon refuses it too.
  return mods.isEmpty ? null : [...mods, key].join('+');
}

class _HotkeyState extends State<_Hotkey> {
  final _focus = FocusNode();
  var _recording = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _record() {
    setState(() => _recording = true);
    _focus.requestFocus();
  }

  void _stop() {
    setState(() => _recording = false);
    _focus.unfocus();
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (!_recording)
      return KeyEventResult
          .ignored; // Tab and Enter keep working when not recording
    if (e is! KeyDownEvent) return KeyEventResult.handled;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _stop();
    } else if (e.logicalKey == LogicalKeyboardKey.backspace ||
        e.logicalKey == LogicalKeyboardKey.delete) {
      widget.p.set('hotkey', '');
      _stop();
    } else {
      final c = hotkeyCombo(
        e.logicalKey,
        HardwareKeyboard.instance.logicalKeysPressed,
      );
      if (c != null) {
        widget.p.set('hotkey', c);
        _stop();
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.p.text('hotkey');
    return _Pick(
      title: 'Atajo para abrirla con el teclado',
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _key,
        onFocusChange: (f) {
          if (!f && _recording) setState(() => _recording = false);
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(
              onPressed: _recording ? _stop : _record,
              child: MotionFade(
                child: Text(
                  _recording
                      ? tx('Pulsa la combinación…')
                      : v.isEmpty
                      ? tx('Grabar atajo')
                      : v.replaceAll('Shift', tx('Mayús')),
                  key: ValueKey(_recording ? 1 : v),
                ),
              ),
            ),
            AnimatedSize(
              duration: motion(context, Spring.fast.settle),
              curve: Spring.fast,
              child: MotionFade(
                child: v.isNotEmpty && !_recording
                    ? IconButton(
                        key: const ValueKey('clear'),
                        tooltip: tx('Quitar atajo'),
                        onPressed: () => widget.p.set('hotkey', ''),
                        icon: const Icon(Symbols.close),
                      )
                    : const SizedBox.shrink(key: ValueKey('none')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which monitor the island opens on; a popup menu that grows from its button.
class _Monitor extends StatelessWidget {
  const _Monitor({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final names = {
      -1: tx('Donde esté el cursor'),
      0: tx('Principal'),
      1: tx('Segunda'),
      2: tx('Tercera'),
    };
    return PopupMenuButton<int>(
      initialValue: value,
      tooltip: tx('Pantalla'),
      popUpAnimationStyle: popUpMotion(context),
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final e in names.entries)
          PopupMenuItem(value: e.key, child: Text(e.value)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: Gap.s),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: MotionFade(
                child: Text(names[value]!, key: ValueKey(value)),
              ),
            ),
            const Icon(Symbols.arrow_drop_down_rounded),
          ],
        ),
      ),
    );
  }
}
