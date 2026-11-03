import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../phone_adb.dart';
import '../phone_control.dart';
import '../src/rust/api/engine.dart' as pb;
import 'phone_page.dart' show NeedsAdb;
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
    final d =
        _adb ??
        await PhoneAdb.find(
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
    await PhoneAdb.setWifi(_adb!.serial, on);
    await Future.delayed(const Duration(seconds: 1));
    await _find();
  }

  Future<void> _bt(bool on) async {
    await PhoneAdb.setBluetooth(_adb!.serial, on);
    await Future.delayed(const Duration(seconds: 1));
    await _find();
  }

  Future<void> _camera(String facing) => PhoneSessions.instance.start(
    _adb!.serial,
    'Cámara ${facing == 'front' ? 'frontal' : 'trasera'} · ${widget.phone.name}',
    SessionOptions(camera: facing, maxSize: 1920, audio: false),
    extra: 'camera',
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hub,
    builder: (context, _) {
      final id = widget.phone.id;
      final st = hub.phoneState[id];
      final adb = _adb;
      final t = Theme.of(context).textTheme;
      void cmd(String what, [Map<String, Object?> b = const {}]) =>
          hub.phoneCmd(id, what, b);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FindCard(
            finding: st?.finding == true,
            onFind: () => cmd('find', {'on': true}),
            onStop: () => cmd('find', {'on': false}),
          ),
          const SizedBox(height: Gap.l),
          Text('Ajustes rápidos', style: t.titleSmall),
          const SizedBox(height: Gap.s),
          Wrap(
            spacing: Gap.m,
            runSpacing: Gap.m,
            children: [
              _Tile(
                icon: Symbols.wifi_rounded,
                label: 'Wi-Fi',
                on: _radios?.$1,
                hint: adb == null ? 'Requiere depuración' : null,
                onTap: adb == null || _radios == null
                    ? null
                    : () => _wifi(!_radios!.$1),
              ),
              _Tile(
                icon: Symbols.bluetooth_rounded,
                label: 'Bluetooth',
                on: _radios?.$2,
                hint: adb == null ? 'Requiere depuración' : null,
                onTap: adb == null || _radios == null
                    ? null
                    : () => _bt(!_radios!.$2),
              ),
              _Tile(
                icon: Symbols.wifi_tethering_rounded,
                label: 'Zona Wi-Fi',
                hint: adb == null
                    ? 'Requiere depuración'
                    : 'Abre sus ajustes en el teléfono',
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
                onTap: st == null
                    ? null
                    : () => cmd('torch', {'on': !st.torch}),
              ),
              _Tile(
                icon: Symbols.lock_rounded,
                label: 'Bloquear pantalla',
                hint: adb == null ? 'Requiere depuración' : null,
                onTap: adb == null ? null : () => PhoneAdb.lock(adb.serial),
              ),
            ],
          ),
          if (st != null) ...[
            const SizedBox(height: Gap.xl),
            Text('Sonido', style: t.titleSmall),
            const SizedBox(height: Gap.s),
            Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'normal',
                        label: Text('Sonido'),
                        icon: Icon(Symbols.notifications_active_rounded),
                      ),
                      ButtonSegment(
                        value: 'vibrate',
                        label: Text('Vibrar'),
                        icon: Icon(Symbols.vibration_rounded),
                      ),
                      ButtonSegment(
                        value: 'silent',
                        label: Text('Silencio'),
                        icon: Icon(Symbols.notifications_off_rounded),
                      ),
                    ],
                    selected: {st.ringer},
                    onSelectionChanged: (v) => cmd('ringer', {'mode': v.first}),
                  ),
                  const SizedBox(height: Gap.m),
                  _Volume(
                    'Multimedia',
                    st.media,
                    st.mediaMax,
                    (v) => cmd('volume', {'stream': 'media', 'value': v}),
                  ),
                  _Volume(
                    'Tono de llamada',
                    st.ring,
                    st.ringMax,
                    (v) => cmd('volume', {'stream': 'ring', 'value': v}),
                  ),
                ],
            ),
          ],
          const SizedBox(height: Gap.xl),
          Text('Cámara del teléfono', style: t.titleSmall),
          const SizedBox(height: Gap.s),
          adb == null
                ? const NeedsAdb('La cámara', card: false)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Abre la cámara del teléfono en una ventana del ordenador (Android 12 o posterior). '
                        'Para usarla como webcam en Meet, Teams o Zoom, captura esa ventana con la cámara virtual '
                        'de OBS Studio.',
                      ),
                      const SizedBox(height: Gap.s),
                      Wrap(
                        spacing: Gap.s,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: () => _camera('back'),
                            icon: const Icon(
                              Symbols.photo_camera_back_rounded,
                              size: 18,
                            ),
                            label: const Text('Trasera'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: () => _camera('front'),
                            icon: const Icon(
                              Symbols.photo_camera_front_rounded,
                              size: 18,
                            ),
                            label: const Text('Frontal'),
                          ),
                        ],
                      ),
                    ],
                  ),
        ],
      );
    },
  );
}

class _FindCard extends StatelessWidget {
  const _FindCard({
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
    return Card(
      color: finding ? s.tertiaryContainer : s.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Row(
          children: [
            Icon(
              finding
                  ? Symbols.ring_volume_rounded
                  : Symbols.mobile_sound_rounded,
              size: 40,
              fill: finding ? 1 : 0,
              color: finding ? s.onTertiaryContainer : s.onSurface,
            ),
            const SizedBox(width: Gap.l),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Buscar teléfono', style: t.titleLarge),
                  Text(
                    finding
                        ? 'Sonando a todo volumen. Se detiene solo en un minuto o al tocar el aviso en el teléfono.'
                        : 'Hace sonar el teléfono a todo volumen, aunque esté en silencio o en No molestar.',
                    style: t.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(width: Gap.l),
            finding
                ? FilledButton.icon(
                    onPressed: onStop,
                    icon: const Icon(Symbols.stop_rounded, size: 18),
                    label: const Text('Detener'),
                  )
                : FilledButton.icon(
                    onPressed: onFind,
                    icon: const Icon(Symbols.volume_up_rounded, size: 18),
                    label: const Text('Hacer sonar'),
                  ),
          ],
        ),
      ),
    );
  }
}

/// A quick-settings tile: on (filled), off, or not available (with why).
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
    final t = Theme.of(context).textTheme;
    final active = on == true;
    final fg = active ? s.onPrimaryContainer : s.onSurface;
    return Semantics(
      button: true,
      toggled: on,
      enabled: onTap != null,
      label: label,
      child: SizedBox(
        width: 210,
        height: 76,
        child: Material(
          color: active ? s.primaryContainer : s.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.tile + 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.tile + 8),
            onTap: onTap,
            child: Opacity(
              opacity: onTap == null ? 0.55 : 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.l),
                child: Row(
                  children: [
                    Icon(icon, fill: active ? 1 : 0, color: fg),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: ExcludeSemantics(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: t.titleSmall?.copyWith(color: fg),
                            ),
                            Text(
                              hint ??
                                  (on == null
                                      ? 'Abrir'
                                      : active
                                      ? 'Activado'
                                      : 'Desactivado'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.bodySmall?.copyWith(
                                color: fg.withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ),
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
  const _Volume(this.label, this.value, this.max, this.onChanged);
  final String label;
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
      SizedBox(width: 140, child: Text(widget.label)),
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
