import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Icon, Text;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../hub.dart';
import '../native.dart';
import '../phone_adb.dart';
import '../phone_control.dart';
import '../scrcpy.dart';
import '../src/rust/api/engine.dart' as pb;
import 'phone_page.dart' show NeedsAdb;
import 'expressive.dart' show Spring, motion, showAleroDialog;
import 'alero_motion.dart';
import 'phone_windows.dart' show CameraFailure;
import 'screen.dart' show openScreen;
import 'shell.dart' show confirm;
import 'theme.dart';
import 'widgets.dart';
import 'icon.dart';
import '../l10n.dart';

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
    icon: FluentIcons.options_24_regular,
    action: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: tx('Elegir y ordenar los controles'),
          onPressed: () => _customize(context, hub),
          icon: const Icon(FluentIcons.apps_add_in_24_regular),
        ),
        IconButton(
          tooltip: tx('Actualizar'),
          onPressed: () => hub.phoneCmd(phone.id, 'state.request'),
          icon: const Icon(FluentIcons.arrow_clockwise_24_regular),
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
  'hotspot': 'Compartir internet desde el teléfono',
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

/// One-shot actions (and the torch and rotation, which show their state in the button): square buttons.
/// Everything else stays a wide tile in the grid.
const _squareKeys = {
  'camBack',
  'camFront',
  'screen',
  'shot',
  'rotate',
  'torch',
  'lock',
  'clip',
};

Future<void> _customize(BuildContext context, Hub hub) => showAleroDialog<void>(
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
                tr(
                  'Arrastra para ordenar y apaga los que no uses. Los {} primeros quedan siempre a la vista; el resto, en «Controles avanzados».',
                  [_mainCount],
                ),
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

Future<void> phoneCamera(String serial, pb.Peer phone, String facing) =>
    PhoneSessions.instance.startCamera(
      serial,
      tr('Cámara {} · {}', [
        facing == 'front' ? 'frontal' : 'trasera',
        phone.name,
      ]),
      facing,
    );

Future<void> phoneShot(Hub hub, String serial) async {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final name =
      'Captura-telefono-${n.year}${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}${two(n.second)}.png';
  try {
    Directory(hub.downloads).createSync(recursive: true);
    await Scrcpy.screenshot(
      serial,
      '${hub.downloads}${Platform.pathSeparator}$name',
    );
    hub.messages.add(
      tr('Captura guardada en la carpeta de descargas: {}', [name]),
    );
  } catch (_) {
    hub.messages.add(
      'No se pudo capturar la pantalla del teléfono. Desbloquéalo e inténtalo de nuevo.',
    );
  }
}

/// A control tapped on Alero Island that only the app runs: the same as its button in the phone controls.
Future<void> runIslandControl(
  BuildContext context,
  Hub hub,
  String peerId,
  String what,
) async {
  final phone = hub.peers.where((p) => p.id == peerId).firstOrNull;
  if (phone == null) return;
  if (what == 'screen') {
    Native.showWindow();
    await openScreen(context, hub, phone);
    return;
  }
  final adb = await PhoneAdb.find(phone, hub.info[peerId]?.model ?? '');
  if (adb == null) {
    hub.messages.add('Requiere depuración del teléfono');
    return;
  }
  switch (what) {
    case 'camBack':
      await phoneCamera(adb.serial, phone, 'back');
    case 'camFront':
      await phoneCamera(adb.serial, phone, 'front');
    case 'shot':
      await phoneShot(hub, adb.serial);
  }
}

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

  Future<void> _camera(String facing) =>
      phoneCamera(_adb!.serial, widget.phone, facing);

  Future<void> _rotate(bool on) async {
    await PhoneAdb.setAutoRotate(_adb!.serial, on);
    await _find();
  }

  Future<void> _shot() => phoneShot(hub, _adb!.serial);

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
          FluentIcons.wifi_1_24_regular,
          on: _radios?.$1,
          hint: adb == null ? needAdb : null,
          onTap: adb == null || _radios == null
              ? null
              : () => _wifi(!_radios!.$1),
        ),
        'bt': tile(
          'bt',
          FluentIcons.bluetooth_24_regular,
          on: _radios?.$2,
          hint: adb == null ? needAdb : null,
          onTap: adb == null || _radios == null
              ? null
              : () => _bt(!_radios!.$2),
        ),
        'hotspot': tile(
          'hotspot',
          FluentIcons.router_24_regular,
          hint: adb == null
              ? needAdb
              : 'Por cable USB o Wi-Fi: abre sus ajustes en el teléfono',
          onTap: adb == null ? null : () => PhoneAdb.openHotspot(adb.serial),
        ),
        'dnd': tile(
          'dnd',
          FluentIcons.weather_moon_24_regular,
          on: st?.dnd,
          hint: st != null && !st.dndAccess
              ? 'Pide permiso en el teléfono'
              : null,
          onTap: st == null ? null : () => cmd('dnd', {'on': !st.dnd}),
        ),
        'torch': tile(
          'torch',
          FluentIcons.flashlight_24_regular,
          on: st?.torch,
          onTap: st == null ? null : () => cmd('torch', {'on': !st.torch}),
        ),
        'lock': tile(
          'lock',
          FluentIcons.lock_closed_24_regular,
          hint: adb == null ? needAdb : null,
          onTap: adb == null ? null : () => PhoneAdb.lock(adb.serial),
        ),
        'camBack': tile(
          'camBack',
          FluentIcons.camera_24_regular,
          hint: adb == null ? needAdb : camHint,
          onTap: adb == null ? null : () => _camera('back'),
        ),
        'camFront': tile(
          'camFront',
          FluentIcons.camera_switch_24_regular,
          hint: adb == null ? needAdb : camHint,
          onTap: adb == null ? null : () => _camera('front'),
        ),
        'screen': tile(
          'screen',
          FluentIcons.cast_24_regular,
          hint: tx('Abre Acceso remoto'),
          onTap: () => openScreen(context, hub, widget.phone),
        ),
        'shot': tile(
          'shot',
          FluentIcons.screenshot_24_regular,
          hint: adb == null ? needAdb : 'La guarda en la carpeta de descargas',
          onTap: adb == null ? null : _shot,
        ),
        'rotate': tile(
          'rotate',
          FluentIcons.arrow_rotate_clockwise_24_regular,
          on: _radios?.$3,
          hint: adb == null ? needAdb : null,
          onTap: adb == null || _radios == null
              ? null
              : () => _rotate(!_radios!.$3),
        ),
        'mute': tile(
          'mute',
          FluentIcons.alert_off_24_regular,
          on: st == null ? null : st.ringer == 'silent',
          onTap: st == null
              ? null
              : () => cmd('ringer', {
                  'mode': st.ringer == 'silent' ? 'normal' : 'silent',
                }),
        ),
        'find': tile(
          'find',
          FluentIcons.phone_speaker_24_regular,
          on: st?.finding,
          hint: tx('Lo hace sonar un minuto, aunque esté en silencio'),
          onTap: st == null ? null : () => cmd('find', {'on': !st.finding}),
        ),
        'clip': tile(
          'clip',
          FluentIcons.clipboard_arrow_right_24_regular,
          hint: tx('Envía al teléfono lo que copiaste aquí'),
          onTap: () => hub.sendClipboard(id),
        ),
      };
      final order = ordered(
        tiles.keys.toList(),
        hub.controlOrder,
        hub.controlHidden,
      );
      final rest = order.skip(_mainCount).toList();
      // Switches keep the wide tiles; the actions go below them as square buttons of one size.
      Widget tilesOf(List<String> keys) {
        final wide = [
          for (final k in keys)
            if (!_squareKeys.contains(k)) tiles[k]!,
        ];
        final square = [
          for (final k in keys)
            if (_squareKeys.contains(k)) tiles[k]!,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide.isNotEmpty) _Grid(hub, wide),
            if (wide.isNotEmpty && square.isNotEmpty)
              const SizedBox(height: Gap.s),
            if (square.isNotEmpty) _Squares(square),
          ],
        );
      }

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
          tilesOf(order.take(_mainCount).toList()),
          Presence(child: adb == null ? null : CameraFailure(adb.serial)),
          Presence(
            child: st == null
                ? null
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: Gap.l),
                      heading('Sonido'),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: 'normal',
                            icon: Icon(
                              FluentIcons.alert_on_24_regular,
                              size: 18,
                            ),
                            label: FitLabel('Sonido'),
                          ),
                          ButtonSegment(
                            value: 'vibrate',
                            icon: Icon(FluentIcons.phone_vibrate_24_regular, size: 18),
                            label: FitLabel('Vibrar'),
                          ),
                          ButtonSegment(
                            value: 'silent',
                            icon: Icon(
                              FluentIcons.alert_off_24_regular,
                              size: 18,
                            ),
                            label: FitLabel('Silencio'),
                          ),
                        ],
                        selected: {st.ringer},
                        onSelectionChanged: (v) =>
                            cmd('ringer', {'mode': v.first}),
                      ),
                      const SizedBox(height: Gap.s),
                      _Volume(
                        'Multimedia',
                        FluentIcons.music_note_2_24_regular,
                        st.media,
                        st.mediaMax,
                        (v) => cmd('volume', {'stream': 'media', 'value': v}),
                      ),
                      _Volume(
                        'Tono de llamada',
                        FluentIcons.call_inbound_24_regular,
                        st.ring,
                        st.ringMax,
                        (v) => cmd('volume', {'stream': 'ring', 'value': v}),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: Gap.s),
          // The second drawer: every other control, and what is playing on the phone.
          AleroPress(
            radius: Radii.chip,
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
                    child: const Icon(FluentIcons.chevron_down_24_regular),
                  ),
                ],
              ),
            ),
          ),
          ArcExpand(
            expanded: _more,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (rest.isNotEmpty) ...[
                  tilesOf(rest),
                  const SizedBox(height: Gap.l),
                ],
              ],
            ),
          ),
          Presence(
            child: _looked && adb == null
                ? const Padding(
                    padding: EdgeInsets.only(top: Gap.s),
                    child: NeedsAdb(
                      'Wi-Fi, Bluetooth, bloqueo, rotación, captura y cámara',
                      card: false,
                    ),
                  )
                : null,
          ),
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
                              label: tr(
                                'Arrastra para cambiar el tamaño de {}; toca para terminar',
                                [c.label],
                              ),
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
                                      FluentIcons.checkmark_24_regular,
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

/// The color a control takes when it is on, by what it does: Wi-Fi blue, Bluetooth indigo, Do Not Disturb violet,
/// torch amber… (they were all the accent, black or white). Returns (fill, text, icon bubble) for the brightness.
(Color, Color, Color) controlTone(BuildContext context, String label) {
  final h = switch (label) {
    'Wi-Fi' => 215.0,
    'Bluetooth' => 238.0,
    'No molestar' => 275.0,
    'Linterna' => 42.0,
    'Compartir internet' || 'Punto de acceso' || 'Zona Wi-Fi' => 180.0,
    'Datos móviles' => 200.0,
    'Modo avión' => 25.0,
    'Ubicación' => 8.0,
    'Ahorro de batería' => 95.0,
    'Girar pantalla' || 'Rotación' || 'Girar' => 140.0,
    'Sonido' || 'Vibrar' || 'Silencio' => 320.0,
    _ => 210.0,
  };
  final dark = Theme.of(context).brightness == Brightness.dark;
  HSLColor c(double sat, double l) => HSLColor.fromAHSL(1, h, sat, l);
  return dark
      ? (c(.45, .30).toColor(), Colors.white, c(.65, .55).toColor())
      : (c(.75, .89).toColor(), c(.55, .22).toColor(), c(.65, .48).toColor());
}

/// A quick-settings tile: small icon and name; on (filled), off, or not available. The tooltip says why.
/// Turning on, its color grows from the point you touched (as on Alero Island) and the tile rounds a little more;
/// turning off, it shrinks back to that point.
class _Tile extends StatefulWidget {
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
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  Offset? _at;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final on = widget.on, label = widget.label, onTap = widget.onTap;
    final active = on == true;
    final (fill, ink, bubble) = controlTone(context, label);
    final state = on == null ? null : (active ? 'activado' : 'desactivado');
    final tip = [
      label,
      ?state,
      ?widget.hint,
      'Mantén presionado para cambiar su tamaño',
    ].map(tx).join(' · ');
    return Tooltip(
      message: tip,
      child: Semantics(
        button: true,
        toggled: on,
        enabled: onTap != null,
        label: tip,
        child: Listener(
          onPointerDown: (e) => _at = e.localPosition,
          // One 0..1 value drives every color, the fill's reach and the corners, so the tile eases between off and on.
          child: TweenValue(
            active ? 1 : 0,
            builder: (_, v) {
              Color mix(Color off, Color on) => Color.lerp(off, on, v)!;
              final fg = mix(s.onSurface, ink);
              final shape = RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.tile + 8 * v),
              );
              return Material(
                color: s.surfaceContainer,
                shape: shape,
                clipBehavior: Clip.antiAlias,
                child: CustomPaint(
                  painter: _FillFrom(_at, v, fill),
                  child: AleroPress(
                    radius: Radii.tile + 8 * v,
                    onTap: onTap,
                    child: AnimatedOpacity(
                      opacity: onTap == null ? 0.45 : 1,
                      duration: AleroMotion.micro(context, Fluent.d167),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: mix(s.surfaceContainerHighest, bubble),
                              ),
                              child: Icon(
                                widget.icon,
                                size: 18,
                                fill: active ? 1 : 0,
                                color: mix(s.onSurface, Colors.white),
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
                                    style: text.labelLarge?.copyWith(color: fg),
                                  ),
                                  if (on != null)
                                    MotionFade(
                                      child: Text(
                                        active ? 'Activado' : 'Desactivado',
                                        key: ValueKey(active),
                                        maxLines: 1,
                                        style: text.labelSmall?.copyWith(
                                          color: mix(
                                            s.onSurfaceVariant,
                                            ink.withValues(alpha: .8),
                                          ),
                                        ),
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
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A circle of [color] from [at] (the tile's center when unknown) that covers the whole tile at [t] = 1.
class _FillFrom extends CustomPainter {
  _FillFrom(this.at, this.t, this.color);
  final Offset? at;
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0) return;
    final c = at ?? size.center(Offset.zero);
    final far = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ].map((p) => (p - c).distance).reduce(math.max);
    canvas.drawCircle(c, far * t.clamp(0, 1), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_FillFrom o) => o.t != t || o.at != at || o.color != color;
}

/// Square action buttons in equal columns: five when they fit at 84 px or more, else four.
class _Squares extends StatelessWidget {
  const _Squares(this.tiles);
  final List<_Tile> tiles;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const gap = Gap.s;
      final cols = box.maxWidth >= 5 * 84 + 4 * gap ? 5 : 4;
      final w = (box.maxWidth - gap * (cols - 1)) / cols;
      // Tall enough for what goes inside (padding, icon, one line of label) at this tile size and text scale,
      // so the content never spills out of the square.
      final f = TileScale.of(context);
      final label = TextPainter(
        text: TextSpan(text: 'Ag', style: Theme.of(context).textTheme.labelSmall),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final h = math.max(72 * f, 2 * 8 * f + 34 * f + 4 * f + label.height + 2);
      label.dispose();
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final x in tiles)
            SizedBox(width: w, height: h, child: _Square(x)),
        ],
      );
    },
  );
}

/// A round icon with the label under it on a rounded surface; the icon fills in when the control is on.
class _Square extends StatelessWidget {
  const _Square(this.x);
  final _Tile x;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final f = TileScale.of(context);
    final on = x.on == true;
    final tip = [
      x.label,
      ?(x.on == null ? null : (x.on! ? 'activado' : 'desactivado')),
      ?x.hint,
    ].map(tx).join(' · ');
    return Tooltip(
      message: tip,
      child: Semantics(
        button: true,
        toggled: x.on,
        enabled: x.onTap != null,
        label: tip,
        child: AleroPress(
          radius: 18,
          onTap: x.onTap,
          child: AnimatedOpacity(
            opacity: x.onTap == null ? 0.45 : 1,
            duration: AleroMotion.micro(context, Fluent.d167),
            child: Material(
              color: s.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8 * f),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: on ? 1 : 0),
                      duration: AleroMotion.micro(context, Fluent.d167),
                      builder: (_, v, _) => Container(
                        width: 34 * f,
                        height: 34 * f,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          // On: the control's own color (torch amber, rotation green…), not the accent.
                          color: Color.lerp(
                            s.surfaceContainerHighest,
                            controlTone(context, x.label).$3,
                            v,
                          ),
                        ),
                        child: Icon(
                          x.icon,
                          size: 18 * f,
                          fill: on ? 1 : 0,
                          color: Color.lerp(s.onSurface, Colors.white, v),
                        ),
                      ),
                    ),
                    SizedBox(height: 4 * f),
                    Text(
                      x.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall,
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

/// Content that comes and goes in place: the space eases open or closed and the content crossfades.
/// Usage: `Presence(child: show ? Banner() : null)`. Not for scrolling builders.
class Presence extends StatelessWidget {
  const Presence({
    super.key,
    required this.child,
    this.alignment = Alignment.topCenter,
  });
  final Widget? child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => AnimatedSize(
    alignment: alignment,
    duration: AleroMotion.micro(context, Fluent.d250),
    curve: Fluent.enter,
    child: MotionFade(
      // Passthrough keeps full-width banners from shrinking and centering.
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.passthrough,
        alignment: alignment,
        children: [...previous, ?current],
      ),
      child: child == null
          ? const SizedBox.shrink(key: ValueKey('none'))
          : KeyedSubtree(key: const ValueKey('some'), child: child!),
    ),
  );
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
        message: tx(widget.label),
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
