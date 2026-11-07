import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../phone_adb.dart';
import '../phone_control.dart';
import '../src/rust/api/engine.dart' as pb;
import 'phone_page.dart' show NeedsAdb;
import 'phone_windows.dart' show CameraFailure;
import 'shell.dart' show confirm;
import 'theme.dart';
import 'widgets.dart';

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
    action: IconButton(
      tooltip: 'Actualizar',
      onPressed: () => hub.phoneCmd(phone.id, 'state.request'),
      icon: const Icon(Symbols.refresh_rounded),
    ),
    // A new phone gets fresh state and its own adb lookup.
    child: _Controls(hub, phone, key: ValueKey(phone.id)),
  );
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
  (bool, bool)? _radios;
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
        : await PhoneAdb.radios(d.serial).catchError((_) => (false, false));
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hub,
    builder: (context, _) {
      final id = widget.phone.id;
      final st = hub.phoneState[id];
      final adb = _adb;
      void cmd(String what, [Map<String, Object?> b = const {}]) =>
          hub.phoneCmd(id, what, b);
      const needAdb = 'Requiere depuración del teléfono';
      const camHint = 'Abre la cámara en una ventana (Android 12+)';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Icon tiles that share the whole width, like the phone's quick settings.
          _Grid(hub, [
            _Tile(
              icon: Symbols.wifi_rounded,
              label: 'Wi-Fi',
              on: _radios?.$1,
              hint: adb == null ? needAdb : null,
              onTap: adb == null || _radios == null
                  ? null
                  : () => _wifi(!_radios!.$1),
            ),
            _Tile(
              icon: Symbols.bluetooth_rounded,
              label: 'Bluetooth',
              on: _radios?.$2,
              hint: adb == null ? needAdb : null,
              onTap: adb == null || _radios == null
                  ? null
                  : () => _bt(!_radios!.$2),
            ),
            _Tile(
              icon: Symbols.wifi_tethering_rounded,
              label: 'Zona Wi-Fi',
              hint: adb == null ? needAdb : 'Abre sus ajustes en el teléfono',
              onTap: adb == null
                  ? null
                  : () => PhoneAdb.openHotspot(adb.serial),
            ),
            _Tile(
              icon: Symbols.do_not_disturb_on_rounded,
              label: 'No molestar',
              on: st?.dnd,
              hint: st != null && !st.dndAccess
                  ? 'Pide permiso en el teléfono'
                  : null,
              onTap: st == null ? null : () => cmd('dnd', {'on': !st.dnd}),
            ),
            _Tile(
              icon: Symbols.flashlight_on_rounded,
              label: 'Linterna',
              on: st?.torch,
              onTap: st == null ? null : () => cmd('torch', {'on': !st.torch}),
            ),
            _Tile(
              icon: Symbols.lock_rounded,
              label: 'Bloquear',
              hint: adb == null ? needAdb : null,
              onTap: adb == null ? null : () => PhoneAdb.lock(adb.serial),
            ),
            _Tile(
              icon: Symbols.photo_camera_back_rounded,
              label: 'Trasera',
              hint: adb == null ? needAdb : camHint,
              onTap: adb == null ? null : () => _camera('back'),
            ),
            _Tile(
              icon: Symbols.photo_camera_front_rounded,
              label: 'Frontal',
              hint: adb == null ? needAdb : camHint,
              onTap: adb == null ? null : () => _camera('front'),
            ),
          ]),
          if (adb != null) CameraFailure(adb.serial),
          if (st != null) ...[
            const SizedBox(height: Gap.m),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: 'normal',
                  tooltip: 'Sonido',
                  icon: Icon(Symbols.notifications_active_rounded),
                ),
                ButtonSegment(
                  value: 'vibrate',
                  tooltip: 'Vibrar',
                  icon: Icon(Symbols.vibration_rounded),
                ),
                ButtonSegment(
                  value: 'silent',
                  tooltip: 'Silencio',
                  icon: Icon(Symbols.notifications_off_rounded),
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
          _FindRow(
            finding: st?.finding == true,
            onFind: () => cmd('find', {'on': true}),
            onStop: () => cmd('find', {'on': false}),
          ),
          if (_looked && adb == null) ...[
            const SizedBox(height: Gap.s),
            const NeedsAdb('Wi-Fi, Bluetooth, bloqueo y cámara', card: false),
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
      final cols = (box.maxWidth / 92).floor().clamp(3, 8);
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
                  height: 58,
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

/// "Buscar teléfono" as one quiet line under the controls.
class _FindRow extends StatelessWidget {
  const _FindRow({
    required this.finding,
    required this.onFind,
    required this.onStop,
  });
  final bool finding;
  final VoidCallback onFind, onStop;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(
          finding ? Symbols.ring_volume_rounded : Symbols.mobile_sound_rounded,
          size: 18,
          fill: finding ? 1 : 0,
          color: s.onSurfaceVariant,
        ),
        const SizedBox(width: Gap.s),
        Expanded(
          child: Text(
            finding
                ? 'Sonando: se detiene solo en un minuto'
                : 'Buscar teléfono',
            style: t.bodyMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton.icon(
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 36),
            visualDensity: VisualDensity.compact,
          ),
          onPressed: finding ? onStop : onFind,
          icon: Icon(
            finding ? Symbols.stop_rounded : Symbols.volume_up_rounded,
            size: 16,
          ),
          label: Text(finding ? 'Detener' : 'Hacer sonar'),
        ),
      ],
    );
  }
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
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      fill: active ? 1 : 0,
                      color: active ? s.onPrimary : s.onSurface,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: active ? s.onPrimary : s.onSurfaceVariant,
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
    ],
  );
}
