import 'dart:io';

import 'package:flutter/material.dart' hide Icon;
import 'package:material_symbols_icons/symbols.dart';

import '../phone_control.dart';
import '../scrcpy.dart';
import '../native.dart';
import '../obs_webcam.dart';
import 'alero_motion.dart';
import 'theme.dart';
import 'widgets.dart';
import 'icon.dart';

/// Phone apps in their own computer windows (one virtual display each, so the phone's screen stays free) and
/// the phone's camera in a window. Both are scrcpy sessions next to the main one; closing a window ends it.
class PhoneWindowsPanel extends StatelessWidget {
  const PhoneWindowsPanel({
    super.key,
    required this.serial,
    required this.deviceName,
  });
  final String serial, deviceName;

  Future<void> _camera(String facing) => PhoneSessions.instance.startCamera(
    serial,
    'Cámara ${facing == 'front' ? 'frontal' : 'trasera'} · $deviceName',
    facing,
  );

  Future<void> _webcam(BuildContext context, String facing) async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Activar webcam de Windows'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Inicia OBS Studio, activa Herramientas › Servidor WebSocket '
              '(puerto 4455) y escribe la contraseña de OBS. Alero utilizará '
              'la cámara virtual que Windows muestra en Zoom, Meet y Teams.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Contraseña de OBS WebSocket',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Activar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (password == null || !context.mounted) return;
    final title =
        'Cámara ${facing == 'front' ? 'frontal' : 'trasera'} · $deviceName';
    try {
      await _camera(facing);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await ObsWebcam.start(windowTitle: title, password: password);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Webcam de Alero activada: selecciona OBS Virtual Camera en tu videollamada.',
            ),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo iniciar la webcam: $error')),
        );
      }
    }
  }

  Future<void> _stopCamera() async {
    await ObsWebcam.stop(silent: true);
    PhoneSessions.instance.stop('$serial|camera');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: PhoneSessions.instance,
      builder: (context, _) {
        final cam = PhoneSessions.instance.runningExtra(serial, 'camera');
        return Panel(
          title: 'Cámara y webcam',
          icon: Symbols.picture_in_picture_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: Gap.l),
              Text(
                'La cámara de Android puede abrirse en una ventana o convertirse en una webcam real de Windows a través de OBS Studio. La webcam aparecerá como dispositivo de vídeo en Zoom, Teams y Meet.',
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

                  FilledButton.icon(
                    onPressed: () => _webcam(context, 'back'),
                    icon: const Icon(Symbols.videocam_rounded),
                    label: const Text('Webcam trasera'),
                  ),
                  FilledButton.icon(
                    onPressed: () => _webcam(context, 'front'),
                    icon: const Icon(Symbols.videocam_rounded),
                    label: const Text('Webcam frontal'),
                  ),
                  if (cam)
                    OutlinedButton.icon(
                      onPressed: () => _stopCamera(),
                      icon: const Icon(Symbols.videocam_off_rounded, size: 18),
                      label: const Text('Cerrar cámara'),
                    ),
                ],
              ),
              CameraFailure(serial),
            ],
          ),
        );
      },
    );
  }
}

/// Why the camera window could not open or closed with an error; nothing while it works.
class CameraFailure extends StatelessWidget {
  const CameraFailure(this.serial, {super.key});
  final String serial;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: PhoneSessions.instance,
    builder: (context, _) {
      final why = PhoneSessions.instance.failures['$serial|camera'];
      if (why == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: Gap.s),
        child: ErrorBanner(why),
      );
    },
  );
}

/// Records the phone's screen (and sound, Android 11+) into a video in the computer's Alero folder, with
/// no window. A scrcpy session next to the others: «Detener grabación» ends it and the file stays.
class PhoneRecordPanel extends StatefulWidget {
  const PhoneRecordPanel({
    super.key,
    required this.serial,
    required this.folder,
  });
  final String serial, folder;

  @override
  State<PhoneRecordPanel> createState() => _PhoneRecordPanelState();
}

class _PhoneRecordPanelState extends State<PhoneRecordPanel> {
  String? _file;

  String get _key => '${widget.serial}|record';

  Future<void> _start() async {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        'Grabacion-${n.year}${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}${two(n.second)}.mkv';
    Directory(widget.folder).createSync(recursive: true);
    final path = '${widget.folder}${Platform.pathSeparator}$name';
    setState(() => _file = path);
    final sdk =
        int.tryParse(
          await Scrcpy.shell(
            widget.serial,
            'getprop ro.build.version.sdk',
          ).catchError((Object _) => ''),
        ) ??
        0;
    await PhoneSessions.instance.start(
      widget.serial,
      'Grabación',
      // Never a second capture of the whole output (see SessionOptions.audioDup): a copy on Android 13+,
      // and before that no sound while the session window already has it.
      SessionOptions(
        record: path,
        audioDup: sdk >= 33,
        audio: sdk >= 33 || !PhoneSessions.instance.running(widget.serial),
      ),
      extra: 'record',
    );
  }

  Future<void> _stop() async {
    PhoneSessions.instance.stop(_key);
    final f = _file;
    if (f == null) return;
    // scrcpy writes nothing during its first seconds: a recording stopped that early is an empty file.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final file = File(f);
    if (!file.existsSync() || file.lengthSync() == 0) {
      try {
        file.deleteSync();
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('La grabación fue demasiado corta y no se guardó.'),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Grabación guardada: ${f.split(Platform.pathSeparator).last}',
        ),
        action: SnackBarAction(
          label: 'Abrir carpeta',
          onPressed: () => Native.openFolder(widget.folder),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: PhoneSessions.instance,
    builder: (context, _) {
      final on = PhoneSessions.instance.runningExtra(widget.serial, 'record');
      final why = PhoneSessions.instance.failures[_key];
      return Panel(
        title: 'Grabar pantalla',
        icon: Symbols.screen_record_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: Gap.l),
            Text(
              on
                  ? 'Grabando la pantalla del teléfono…'
                  : 'Graba la pantalla del teléfono (con sonido en Android 11 o posterior) en un vídeo .mkv dentro de ${widget.folder}.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.s),
            Align(
              alignment: Alignment.centerLeft,
              child: on
                  ? FilledButton.tonalIcon(
                      onPressed: _stop,
                      icon: AleroPulse(
                        active: true,
                        child: Icon(
                          Symbols.stop_circle_rounded,
                          size: 18,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      label: const Text('Detener grabación'),
                    )
                  : FilledButton.icon(
                      onPressed: _start,
                      icon: const Icon(
                        Symbols.fiber_manual_record_rounded,
                        size: 18,
                      ),
                      label: const Text('Grabar'),
                    ),
            ),
            if (why != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.s),
                child: ErrorBanner(why),
              ),
          ],
        ),
      );
    },
  );
}
