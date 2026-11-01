import 'dart:io';

import 'package:flutter/material.dart';

import '../hub.dart';
import '../native.dart';
import 'brand.dart';
import 'theme.dart';

/// Explanations are visible before any button opens a system permission prompt.
class SetupScreen extends StatefulWidget {
  const SetupScreen(this.hub, {super.key, required this.onDone});
  final Hub hub;
  final void Function(bool pair) onDone;
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final _name = TextEditingController(text: widget.hub.name);
  int _step = 0;
  bool _busy = false, _startup = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _act(() async {
        _startup = await Native.startupEnabled();
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        _error = 'No se pudo completar. Puedes intentarlo desde Ajustes.';
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _permission(
    String title,
    String why,
    String action,
    Future<void> Function() onTap,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Gap.s),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        Text(why),
        TextButton(
          onPressed: _busy ? null : () => _act(onTap),
          child: Text(action),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hub = widget.hub;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Configurar Alero',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => widget.onDone(false),
            child: const Text('Omitir'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(Gap.xl),
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: AleroMark(size: 48),
                ),
                const SizedBox(height: Gap.xl),
                Text(switch (_step) {
                  0 => 'Bienvenido a Alero',
                  1 => 'Elige qué compartir',
                  _ => 'Conecta tus dispositivos',
                }, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: Gap.m),
                if (_step == 0) ...[
                  const Text(
                    'Conecta tu teléfono y tu ordenador por Wi-Fi o USB. Tus archivos viajan directamente entre dispositivos emparejados.',
                  ),
                  const SizedBox(height: Gap.xl),
                  // Keep the label OUTSIDE the filled field. Flutter's floating
                  // label overlaid the default device name on both platforms,
                  // especially with Google Sans Flex and larger text scaling.
                  Text(
                    'Nombre del dispositivo',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: Gap.s),
                  TextField(
                    controller: _name,
                    maxLength: 64,
                    textAlignVertical: TextAlignVertical.center,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      counterText: '',
                      hintText: 'Escribe el nombre del equipo',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: Gap.l,
                        vertical: Gap.l,
                      ),
                    ),
                  ),
                  const SizedBox(height: Gap.s),
                  Text(
                    'Así aparecerá en el otro equipo.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_step == 1 && Platform.isAndroid) ...[
                  const Text(
                    'Todo es opcional. Android te pedirá confirmar cada permiso; puedes cambiarlo después en Ajustes.',
                  ),
                  _permission(
                    'Avisos de Alero',
                    'Para avisarte de transferencias y solicitudes de emparejamiento.',
                    'Permitir avisos',
                    Native.requestNotifications,
                  ),
                  _permission(
                    'Notificaciones del teléfono',
                    'Muestra tus notificaciones y permite responder y controlar la música desde el PC.',
                    'Revisar acceso',
                    hub.openNotifAccess,
                  ),
                  _permission(
                    'Fotos, vídeos y música',
                    'Un ordenador emparejado podrá explorar y descargar los archivos que autorices.',
                    'Elegir archivos compartidos',
                    () => hub.setFilesAllowed(true),
                  ),
                  _permission(
                    'Todas las carpetas',
                    'Comparte el almacenamiento común. Las carpetas privadas de otras apps siguen protegidas.',
                    'Revisar acceso a carpetas',
                    Native.requestAllFiles,
                  ),
                  _permission(
                    'Instalar apps recibidas',
                    'Abre el instalador al tocar un APK. Android seguirá pidiendo confirmar cada instalación.',
                    'Revisar instalación de apps',
                    Native.requestInstallPermission,
                  ),
                ],
                if (_step == 1 && !Platform.isAndroid) ...[
                  const Text(
                    'Solo los dispositivos emparejados pueden usar estas funciones. Puedes cambiarlas después en Ajustes.',
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Permitir control remoto'),
                    subtitle: const Text(
                      'El teléfono podrá mover el ratón, escribir, controlar música y ver la pantalla.',
                    ),
                    value: hub.remoteAllow,
                    onChanged: _busy
                        ? null
                        : (on) => setState(() => hub.setRemoteAllow(on)),
                  ),
                  if (Platform.isWindows)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Abrir Alero al iniciar sesión'),
                      subtitle: const Text(
                        'Inicia la app y su conexión al entrar en Windows.',
                      ),
                      value: _startup,
                      onChanged: _busy
                          ? null
                          : (on) => _act(() async {
                              await Native.setStartup(on);
                              _startup = on;
                            }),
                    ),
                ],
                if (_step == 2)
                  const Text(
                    'Abre Alero en el otro dispositivo y usa la misma red Wi-Fi o un cable USB. En Dispositivos, elige el equipo y comprueba el código en ambos.',
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.m),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: Gap.xl),
                Wrap(
                  spacing: Gap.m,
                  runSpacing: Gap.s,
                  children: [
                    if (_step > 0)
                      TextButton(
                        onPressed: _busy ? null : () => setState(() => _step--),
                        child: const Text('Atrás'),
                      ),
                    FilledButton(
                      onPressed:
                          _busy || (_step == 0 && _name.text.trim().isEmpty)
                          ? null
                          : () async {
                              if (_step == 2) {
                                widget.onDone(true);
                                return;
                              }
                              await _act(() async {
                                if (_step == 0) await hub.setName(_name.text);
                                if (mounted) _step++;
                              });
                            },
                      child: Text(
                        _step == 2 ? 'Ir a Dispositivos' : 'Continuar',
                      ),
                    ),
                    if (_step == 2)
                      TextButton(
                        onPressed: () => widget.onDone(false),
                        child: const Text('Terminar sin emparejar'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
