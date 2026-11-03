import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../phone_control.dart';
import '../scrcpy.dart';
import 'theme.dart';
import 'widgets.dart';

/// Phone apps in their own computer windows (one virtual display each, so the phone's screen stays free) and
/// the phone's camera in a window. Both are scrcpy sessions next to the main one; closing a window ends it.
class PhoneWindowsPanel extends StatelessWidget {
  const PhoneWindowsPanel({
    super.key,
    required this.serial,
    required this.deviceName,
  });
  final String serial, deviceName;

  Future<void> _app(BuildContext context) async {
    final pick = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _AppPicker(serial),
    );
    if (pick == null) return;
    await PhoneSessions.instance.start(
      serial,
      '${pick.$1} · $deviceName',
      SessionOptions(appWindow: true, startApp: pick.$2, maxSize: 1280),
      extra: 'app:${pick.$2}',
    );
  }

  Future<void> _camera(String facing) => PhoneSessions.instance.start(
    serial,
    'Cámara ${facing == 'front' ? 'frontal' : 'trasera'} · $deviceName',
    SessionOptions(camera: facing, maxSize: 1920, audio: false),
    extra: 'camera',
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: PhoneSessions.instance,
      builder: (context, _) {
        final cam = PhoneSessions.instance.runningExtra(serial, 'camera');
        return Panel(
          title: 'Ventanas y cámara',
          icon: Symbols.picture_in_picture_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Cada app se abre en su propia ventana, en una pantalla virtual: el teléfono sigue libre. '
                'Puedes abrir varias a la vez.',
                style: t.bodyMedium,
              ),
              const SizedBox(height: Gap.s),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: () => _app(context),
                  icon: const Icon(Symbols.open_in_new_rounded, size: 18),
                  label: const Text('Abrir una app en una ventana'),
                ),
              ),
              const SizedBox(height: Gap.l),
              Text(
                'La cámara del teléfono en una ventana (Android 12 o posterior). Para usarla como webcam en '
                'Meet, Teams o Zoom, captura esa ventana con la cámara virtual de OBS Studio (gratuito y libre).',
                style: t.bodyMedium,
              ),
              const SizedBox(height: Gap.s),
              Wrap(
                spacing: Gap.s,
                runSpacing: Gap.s,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => _camera('back'),
                    icon: const Icon(
                      Symbols.photo_camera_back_rounded,
                      size: 18,
                    ),
                    label: const Text('Cámara trasera'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _camera('front'),
                    icon: const Icon(
                      Symbols.photo_camera_front_rounded,
                      size: 18,
                    ),
                    label: const Text('Cámara frontal'),
                  ),
                  if (cam)
                    OutlinedButton.icon(
                      onPressed: () =>
                          PhoneSessions.instance.stop('$serial|camera'),
                      icon: const Icon(Symbols.videocam_off_rounded, size: 18),
                      label: const Text('Cerrar cámara'),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AppPicker extends StatefulWidget {
  const _AppPicker(this.serial);
  final String serial;

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  late final Future<List<(String, String)>> _apps = Scrcpy.appsWithNames(
    widget.serial,
  );
  String _q = '';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Abrir en una ventana'),
    content: SizedBox(
      width: 420,
      height: 480,
      child: Column(
        children: [
          TextField(
            autofocus: true,
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            decoration: const InputDecoration(
              hintText: 'Buscar apps',
              prefixIcon: Icon(Symbols.search_rounded),
            ),
          ),
          const SizedBox(height: Gap.s),
          Expanded(
            child: FutureBuilder(
              future: _apps,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = snap.data!
                    .where(
                      (a) =>
                          _q.isEmpty ||
                          a.$1.toLowerCase().contains(_q) ||
                          a.$2.contains(_q),
                    )
                    .toList();
                if (list.isEmpty) {
                  return const Center(child: Text('Ninguna app coincide.'));
                }
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) => ListTile(
                    leading: const Icon(Symbols.android_rounded),
                    title: Text(list[i].$1),
                    subtitle: list[i].$1 == list[i].$2
                        ? null
                        : Text(list[i].$2),
                    onTap: () => Navigator.pop(context, list[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
    ],
  );
}
