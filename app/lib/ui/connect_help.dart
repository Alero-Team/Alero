import 'dart:io';

import 'package:flutter/material.dart' hide Icon;
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../native.dart';
import 'theme.dart';
import 'widgets.dart';
import 'icon.dart';

/// Supported local connections: Alero's USB tunnel and Android's file-transfer mode.
class ConnectionPanel extends StatelessWidget {
  const ConnectionPanel(this.hub, {super.key});
  final Hub hub;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final android = Platform.isAndroid;
    Widget row(IconData icon, String title, String body, Widget action) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.s),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconTile(icon),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: weight(t.bodyLarge, 500)),
                    const SizedBox(height: 2),
                    Text(
                      body,
                      style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                    ),
                    const SizedBox(height: Gap.s),
                    action,
                  ],
                ),
              ),
            ],
          ),
        );

    return Panel(
      title: 'Cable y conexiones',
      icon: Symbols.usb_rounded,
      child: Column(
        children: [
          row(
            Symbols.cable_rounded,
            'Alero por cable USB',
            android
                ? 'Conecta Alero con el ordenador por el cable, sin Wi-Fi. Se inicia desde el ordenador (Dispositivos › Cable y conexiones › Conectar) y necesita «Depuración USB» activada en este teléfono.'
                : 'Conecta Alero con el teléfono por el cable, sin Wi-Fi. Activa «Depuración USB» en el teléfono (Opciones de desarrollador) y acepta la autorización que aparece. Archivos, portapapeles, notificaciones y pantalla funcionan igual.',
            android
                ? OutlinedButton.icon(
                    onPressed: Native.openDevSettings,
                    icon: const Icon(Symbols.developer_mode_rounded, size: 18),
                    label: const Text('Opciones de desarrollador'),
                  )
                : FilledButton.tonalIcon(
                    onPressed: hub.connectCable,
                    icon: const Icon(Symbols.usb_rounded, size: 18),
                    label: const Text('Conectar por cable'),
                  ),
          ),
          if (android) ...[
            row(
              Symbols.folder_open_rounded,
              'Transferir archivos por USB (MTP)',
              'Para ver el teléfono en el Explorador de Windows y copiar fotos y archivos con el cable. Android te permite elegir el modo USB desde sus ajustes.',
              FilledButton.tonalIcon(
                onPressed: () => _mtpGuide(context),
                icon: const Icon(Symbols.help_rounded, size: 18),
                label: const Text('Cómo activarlo'),
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(
                'Para copiar archivos con el Explorador de Windows, en el teléfono elige «Transferencia de archivos» al conectar el cable. Encontrarás los pasos en Dispositivos › Cable y conexiones.',
                style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  void _mtpGuide(BuildContext context) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Transferir archivos por USB'),
      content: const SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Step(
              1,
              'Conecta el teléfono al ordenador con un cable de datos (algunos cables solo cargan).',
            ),
            _Step(2, 'Desbloquea el teléfono.'),
            _Step(
              3,
              'Baja el panel de notificaciones y toca «Carga de este dispositivo mediante USB» (o «USB»).',
            ),
            _Step(4, 'Elige «Transferencia de archivos».'),
            _Step(
              5,
              'En Windows aparece en «Este equipo». Si no, prueba otro puerto o cable.',
            ),
            SizedBox(height: Gap.m),
            Text(
              'Si Android no muestra ese aviso, puedes fijarlo en Opciones de desarrollador › «Configuración USB predeterminada». Alero no puede cambiar el modo USB por ti: Android lo reserva al usuario.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cerrar'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            Native.openUsbSettings();
          },
          child: const Text('Abrir ajustes USB'),
        ),
      ],
    ),
  );
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.text);
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.s),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 24,
          child: Text(
            '$n.',
            style: weight(Theme.of(context).textTheme.bodyMedium, 600),
          ),
        ),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
