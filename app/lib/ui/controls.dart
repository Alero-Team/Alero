import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Icon;
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../phone_adb.dart';
import '../phone_control.dart';
import '../scrcpy.dart';
import '../src/rust/api/engine.dart' as pb;
import 'phone_page.dart' show NeedsAdb;
import 'expressive.dart' show Spring, motion;
import 'phone_windows.dart' show CameraFailure;
import 'screen.dart' show openScreen;
import 'shell.dart' show confirm;
import 'theme.dart';
import 'widgets.dart';
import 'icon.dart';

/// "Controles del teléfono", a panel on the computer's Inicio: quick toggles and shortcuts, like the phone's own
/// quick settings. Do Not Disturb, flashlight, sound, volume and "find my phone" go through Alero on the phone;
/// Wi-Fi and Bluetooth need adb, the only way Android lets them be switched from outside.
class PhoneControlsPanel extends StatelessWidget {
  const PhoneControlsPanel(this.hub, this.phone, {super.key});
  final Hub hub;
  final pb.Peer phone;

  @override
  Widget build(BuildContext context) => Panel(
    title: 'Controles del teléfono',
    icon: Symbols.tune_rounded,
    action: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Elegir y ordenar los controles',
          onPressed: () => _customize(context, hub),
          icon: const Icon(Symbols.dashboard_customize_rounded),
        ),
        IconButton(
          tooltip: 'Actualizar',
          onPressed: () => hub.phoneCmd(phone.id, 'state.request'),
          icon: const Icon(Symbols.refresh_rounded),
        ),
      ],
    ),
    // A new phone gets fresh state and its own adb lookup.
    child: _Controls(hub, phone, key: ValueKey(phone.id)),
  );
}

/// Every control, by name, in its default order. The first [_mainCount] the user keeps on top are always in
/// sight; the rest wait under "Controles avanzados".
const controlNames = {
  'wifi': 'Wi-Fi',
  'bt': 'Bluetooth',
  'hotspot': 'Zona Wi-Fi',
  'dnd': 'No molestar',
  'torch': 'Linterna',
  'lock': 'Bloquear',
  'camBack': 'Cámara trasera',
  'camFront': 'Cámara frontal',
  'screen': 'Ver pantalla',
  'shot': 'Captura',
  'rotate': 'Rotación',
  'mute': 'Silenciar',
  'find': 'Buscar teléfono',
  'clip': 'Portapapeles',
};
const _mainCount = 8;

Future<void> _customize(BuildContext context, Hub hub) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: const Text('Controles del teléfono'),
    content: SizedBox(
      width: 380,
      child: ListenableBuilder(
        listenable: hub,
        builder: (ctx, _) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Arrastra para ordenar y apaga los que no uses. Los $_mainCount primeros quedan '
                'siempre a la vista; el resto, en «Controles avanzados».',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: Gap.s),
              OrderList(
                order: ordered(
                  controlNames.keys.toList(),
                  hub.controlOrder,
                  const {},
                ),
                names: controlNames,
                hidden: hub.controlHidden,
                onChanged: hub.setControls,
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => hub.setControls([], {}),
        child: const Text('Restablecer'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Listo'),
      ),
    ],
  ),
);

class _Controls extends StatefulWidget {
  const _Controls(this.hub, this.phone, {super.key});
  final Hub hub;
  final pb.Peer phone;

  @override
  State<_Controls> createState() => _ControlsState();
}

class _ControlsState extends State<_Controls> {
  Hub get hub => widget.hub;
  AdbDevice? _adb;
  (bool, bool, bool)? _radios;
  bool _more = false;
  // The adb notice waits for the first lookup: it flashed on every open even with debugging on.
  bool _looked = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    hub.phoneCmd(widget.phone.id, 'state.request');
    _find();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _find());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _find() async {
    // No caching: after a Wi-Fi drop the old serial is dead and find() reconnects on the new port.
    final d = await PhoneAdb.find(
      widget.phone,
      hub.info[widget.phone.id]?.model ?? '',
    );
    final r = d == null
        ? null
        : await PhoneAdb.toggles(d.serial)
              .catchError((_) => (false, false, false));
    if (!mounted) return;
    setState(() {
      _adb = d;
      _radios = r;
      _looked = true;
    });
  }

  Future<void> _wifi(bool on) async {
    // Over Wi-Fi, turning it off cuts Alero (and wireless debugging) until it is back on.
    if (!on &&
        (hub.routeOf(widget.phone) != 'Cable USB' || _adb!.wifi) &&
        !await confirm(
          context,
          '¿Apagar el Wi-Fi del teléfono?',
          'Alero está conectado por Wi-Fi: se desconectará hasta que lo vuelvas a encender en el teléfono.',
          'Apagar',
        )) {
      return;
    }
    final adb =
        _adb; // the 5 s poll may have dropped it while the dialog was open
    if (adb == null) return;
    await PhoneAdb.setWifi(adb.serial, on);
    await Future.delayed(const Duration(seconds: 1));
    await _find();
  }

  Future<void> _bt(bool on) async {
    await PhoneAdb.setBluetooth(_adb!.serial, on);
    await Future.delayed(const Duration(seconds: 1));
    await _find();
  }

  Future<void> _camera(String facing) => PhoneSessions.instance.startCamera(
    _adb!.serial,
    'Cámara ${facing == 'front' ? 'frontal' : 'trasera'} · ${widget.phone.name}',
    facing,
  );

  Future<void> _rotate(bool on) async {
    await PhoneAdb.setAutoRotate(_adb!.serial, on);
    await _find();
  }

  Future<void> _shot() async {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        'Captura-telefono-${n.year}${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}${two(n.second)}.png';
    try {
      Directory(hub.downloads).createSync(recursive: true);
      await Scrcpy.screenshot(
        _adb!.serial,
        '${hub.downloads}${Platform.pathSeparator}$name',
      );
      hub.messages.add('Captura guardada en la carpeta de descargas: $name');
    } catch (_) {
      hub.messages.add(
        'No se pudo capturar la pantalla del teléfono. Desbloquéalo e inténtalo de nuevo.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hub,
    builder: (context, _) {
      final id = widget.phone.id;
      final st = hub.phoneState[id];
      final adb = _adb;
      final t = Theme.of(context).textTheme;
      final s = Theme.of(context).colorScheme;
      void cmd(String what, [Map<String, Object?> b = const {}]) =>
          hub.phoneCmd(id, what, b);
      const needAdb = 'Requiere depuración del teléfono';
      const camHint = 'Abre la cámara en una ventana (Android 12+)';
      _Tile tile(
        String key,
        IconData icon, {
        bool? on,
        String? hint,
        VoidCallback? onTap,
      }) => _Tile(
        icon: icon,
        label: controlNames[key]!,
        on: on,
        hint: hint,
        onTap: onTap,
      );
      final tiles = {
        'wifi': tile(
          'wifi',
          Symbols.wifi_rounded,
          on: _radios?.$1,
          hint: adb == null ? needAdb : null,
          onTap: adb == null || _radios == null
              ? null
              : () => _wifi(!_radios!.$1),
        ),
        'bt': tile(
          'bt',
          Symbols.bluetooth_rounded,
          on: _radios?.$2,
          hint: adb == null ? needAdb : null,
          onTap: adb == null || _radios == null
              ? null
              : () => _bt(!_radios!.$2),
        ),
        'hotspot': tile(
          'hotspot',
          Symbols.wifi_tethering_rounded,
          hint: adb == null ? needAdb : 'Abre sus ajustes en el teléfono',
          onTap: adb == null ? null : () => PhoneAdb.openHotspot(adb.serial),
        ),
        'dnd': tile(
          'dnd',
          Symbols.do_not_disturb_on_rounded,
          on: st?.dnd,
          hint: st != null && !st.dndAccess
              ? 'Pide permiso en el teléfono'
              : null,
          onTap: st == null ? null : () => cmd('dnd', {'on': !st.dnd}),
        ),
        'torch': tile(
          'torch',
          Symbols.flashlight_on_rounded,
          on: st?.torch,
          onTap: st == null ? null : () => cmd('torch', {'on': !st.torch}),
        ),
        'lock': tile(
          'lock',
          Symbols.lock_rounded,
          hint: adb == null ? needAdb : null,
          onTap: adb == null ? null : () => PhoneAdb.lock(adb.serial),
        ),
        'camBack': tile(
          'camBack',
          Symbols.photo_camera_back_rounded,
          hint: adb == null ? needAdb : camHint,
          onTap: adb == null ? null : () => _camera('back'),
        ),
        'camFront': tile(
          'camFront',
          Symbols.photo_camera_front_rounded,
          hint: adb == null ? needAdb : camHint,
          onTap: adb == null ? null : () => _camera('front'),
        ),
        'screen': tile(
          'screen',
          Symbols.cast_rounded,
          hint: 'Abre Acceso remoto',
          onTap: () => openScreen(context, hub, widget.phone),
        ),
        'shot': tile(
          'shot',
          Symbols.screenshot_rounded,
          hint: adb == null ? needAdb : 'La guarda en la carpeta de descargas',
          onTap: adb == null ? null : _shot,
        ),
        'rotate': tile(
          'rotate',
          Symbols.screen_rotation_rounded,
          on: _radios?.$3,
          hint: adb == null ? needAdb : null,
          onTap: adb == null || _radios == null
              ? null
              : () => _rotate(!_radios!.$3),
        ),
        'mute': tile(
          'mute',
          Symbols.notifications_off_rounded,
          on: st == null ? null : st.ringer == 'silent',
          onTap: st == null
              ? null
              : () => cmd('ringer', {
                  'mode': st.ringer == 'silent' ? 'normal' : 'silent',
                }),
        ),
        'find': tile(
          'find',
          Symbols.mobile_sound_rounded,
          on: st?.finding,
          hint: 'Lo hace sonar un minuto, aunque esté en silencio',
          onTap: st == null ? null : () => cmd('find', {'on': !st.finding}),
        ),
        'clip': tile(
          'clip',
          Symbols.content_paste_go_rounded,
          hint: 'Envía al teléfono lo que copiaste aquí',
          onTap: () => hub.sendClipboard(id),
        ),
      };
      final order = ordered(
        tiles.keys.toList(),
        hub.controlOrder,
        hub.controlHidden,
      );
      final rest = order.skip(_mainCount).toList();
      Widget heading(String text) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.s),
        child: Text(
          text,
          style: t.labelMedium?.copyWith(color: s.onSurfaceVariant),
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Tiles that share the whole width, like the phone's quick settings.
          _Grid(hub, [for (final k in order.take(_mainCount)) tiles[k]!]),
          if (adb != null) CameraFailure(adb.serial),
          if (st != null) ...[
            const SizedBox(height: Gap.l),
            heading('Sonido'),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: 'normal',
                  icon: Icon(Symbols.notifications_active_rounded, size: 18),
                  label: FitLabel('Sonido'),
                ),
                ButtonSegment(
                  value: 'vibrate',
                  icon: Icon(Symbols.vibration_rounded, size: 18),
                  label: FitLabel('Vibrar'),
                ),
                ButtonSegment(
                  value: 'silent',
                  icon: Icon(Symbols.notifications_off_rounded, size: 18),
                  label: FitLabel('Silencio'),
                ),
              ],
              selected: {st.ringer},
              onSelectionChanged: (v) => cmd('ringer', {'mode': v.first}),
            ),
            const SizedBox(height: Gap.s),
            _Volume(
              'Multimedia',
              Symbols.music_note_rounded,
              st.media,
              st.mediaMax,
              (v) => cmd('volume', {'stream': 'media', 'value': v}),
            ),
            _Volume(
              'Tono de llamada',
              Symbols.ring_volume_rounded,
              st.ring,
              st.ringMax,
              (v) => cmd('volume', {'stream': 'ring', 'value': v}),
            ),
          ],
          const SizedBox(height: Gap.s),
          // The second drawer: every other control, and what is playing on the phone.
          InkWell(
            borderRadius: BorderRadius.circular(Radii.chip),
            onTap: () => setState(() => _more = !_more),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.s),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Controles avanzados', style: t.titleSmall),
                  ),
                  AnimatedRotation(
                    turns: _more ? .5 : 0,
                    duration: motion(
                      context,
                      const Duration(milliseconds: 220),
                    ),
                    curve: Spring.fast,
                    child: const Icon(Symbols.expand_more_rounded),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: motion(context, Spring.spatial.settle),
            curve: Spring.spatial,
            alignment: Alignment.topCenter,
            child: !_more
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (rest.isNotEmpty) ...[
                        _Grid(hub, [for (final k in rest) tiles[k]!]),
                        const SizedBox(height: Gap.l),
                      ],
                      heading('Reproducción en el teléfono'),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final (tip, icon, action) in const [
                            ('Anterior', Symbols.skip_previous_rounded, 'prev'),
                            (
                              'Reproducir o pausar',
                              Symbols.play_pause_rounded,
                              'toggle',
                            ),
                            ('Siguiente', Symbols.skip_next_rounded, 'next'),
                          ])
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Gap.xs,
                              ),
                              child: IconButton.filledTonal(
                                tooltip: tip,
                                onPressed: () => hub.mediaCmd(id, action),
                                icon: Icon(icon),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
          ),
          if (_looked && adb == null) ...[
            const SizedBox(height: Gap.s),
            const NeedsAdb(
              'Wi-Fi, Bluetooth, bloqueo, rotación, captura y cámara',
              card: false,
            ),
          ],
        ],
      );
    },
  );
}

/// Lays tiles out in equal columns that fill the panel's width; each tile spans the columns its user chose.
/// Like Android's quick settings: long-press a tile, drag the tick on its edge to resize it, tap the tick when done.
class _Grid extends StatefulWidget {
  const _Grid(this.hub, this.children);
  final Hub hub;
  final List<_Tile> children;

  @override
  State<_Grid> createState() => _GridState();
}

class _GridState extends State<_Grid> {
  String? _editing;
  double _drag = 0;
  int _from = 1;

  Hub get hub => widget.hub;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final cols = (box.maxWidth / 172).floor().clamp(2, 6);
      final w = (box.maxWidth - Gap.s * (cols - 1)) / cols;
      final s = Theme.of(context).colorScheme;
      return Wrap(
        spacing: Gap.s,
        runSpacing: Gap.s,
        children: [
          for (final c in widget.children)
            Builder(
              builder: (context) {
                final span = (hub.controlSpans[c.label] ?? 1).clamp(1, cols);
                final editing = _editing == c.label;
                void edit() => setState(() => _editing = c.label);
                return SizedBox(
                  width: w * span + Gap.s * (span - 1),
                  height: 56,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        onLongPress: edit,
                        onSecondaryTap: edit,
                        // While resizing, a tap must not switch the control.
                        child: AbsorbPointer(absorbing: editing, child: c),
                      ),
                      if (editing) ...[
                        IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(Radii.tile),
                              border: Border.all(color: s.primary, width: 2),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 2,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: Semantics(
                              button: true,
                              label:
                                  'Arrastra para cambiar el tamaño de ${c.label}; toca para terminar',
                              child: GestureDetector(
                                onTap: () => setState(() => _editing = null),
                                onHorizontalDragStart: (_) {
                                  _drag = 0;
                                  _from = span;
                                },
                                onHorizontalDragUpdate: (d) {
                                  _drag += d.delta.dx;
                                  final next = (_from + _drag / (w + Gap.s))
                                      .round()
                                      .clamp(1, cols);
                                  if (next != span) {
                                    hub.setControlSpan(c.label, next);
                                  }
                                },
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.resizeLeftRight,
                                  child: CircleAvatar(
                                    radius: 13,
                                    backgroundColor: s.primary,
                                    child: Icon(
                                      Symbols.check_rounded,
                                      size: 16,
                                      color: s.onPrimary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
        ],
      );
    },
  );
}

/// A quick-settings tile: small icon and name; on (filled), off, or not available. The tooltip says why.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.label,
    this.on,
    this.hint,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final bool? on;
  final String? hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final active = on == true;
    final state = on == null ? null : (active ? 'activado' : 'desactivado');
    final tip = [
      label,
      ?state,
      ?hint,
      'Mantén presionado para cambiar su tamaño',
    ].join(' · ');
    return Tooltip(
      message: tip,
      child: Semantics(
        button: true,
        toggled: on,
        enabled: onTap != null,
        label: tip,
        child: Material(
          color: active ? s.primary : s.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.tile),
            side: BorderSide(color: active ? s.primary : s.outlineVariant),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.tile),
            onTap: onTap,
            child: Opacity(
              opacity: onTap == null ? 0.45 : 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active
                            ? s.onPrimary.withValues(alpha: .16)
                            : s.surfaceContainerHighest,
                      ),
                      child: Icon(
                        icon,
                        size: 18,
                        fill: active ? 1 : 0,
                        color: active ? s.onPrimary : s.onSurface,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelLarge?.copyWith(
                              color: active ? s.onPrimary : s.onSurface,
                            ),
                          ),
                          if (on != null)
                            Text(
                              active ? 'Activado' : 'Desactivado',
                              maxLines: 1,
                              style: text.labelSmall?.copyWith(
                                color: active
                                    ? s.onPrimary.withValues(alpha: .8)
                                    : s.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Volume extends StatefulWidget {
  const _Volume(this.label, this.icon, this.value, this.max, this.onChanged);
  final String label;
  final IconData icon;
  final int value, max;
  final ValueChanged<int> onChanged;

  @override
  State<_Volume> createState() => _VolumeState();
}

/// Follows the finger while dragging; the phone gets the value once, on release.
class _VolumeState extends State<_Volume> {
  double? _drag;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Tooltip(
        message: widget.label,
        child: Icon(widget.icon, size: 20, semanticLabel: widget.label),
      ),
      Expanded(
        child: Slider(
          value: (_drag ?? widget.value.clamp(0, widget.max).toDouble()),
          max: widget.max.toDouble(),
          divisions: widget.max > 0 ? widget.max : null,
          label: '${(_drag ?? widget.value).round()}',
          onChanged: (v) => setState(() => _drag = v),
          onChangeEnd: (v) {
            widget.onChanged(v.round());
            setState(() => _drag = null);
          },
        ),
      ),
      SizedBox(
        width: 44,
        child: Text(
          '${(_drag ?? widget.value).round()}/${widget.max}',
          textAlign: TextAlign.end,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(fontFeatures: tabular),
        ),
      ),
    ],
  );
}
