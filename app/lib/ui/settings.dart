import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../native.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen(this.hub, {super.key});
  final Hub hub;

  /// The engine reports `local address: <ip>` among its diagnostics.
  String get _ip => hub.diagnostics
      .firstWhere((l) => l.startsWith('local address: '), orElse: () => 'local address: —')
      .substring('local address: '.length);

  Future<void> _rename(BuildContext context) async {
    final c = TextEditingController(text: hub.name);
    final n = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nombre de este dispositivo'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(labelText: 'Nombre', helperText: 'Así te verán los otros dispositivos.'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Guardar')),
        ],
      ),
    );
    c.dispose();
    if (n != null) await hub.setName(n);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    const gap = SizedBox(height: Gap.l, width: Gap.l);
    final wide = MediaQuery.sizeOf(context).width >= 1180;

    final device = Panel(
      title: 'Este dispositivo',
      icon: Symbols.badge_rounded,
      child: Column(
        children: [
          SettingTile(
            title: 'Nombre',
            subtitle: hub.name,
            trailing: Icon(Symbols.edit_rounded, size: 20, color: s.onSurfaceVariant),
            onTap: () => _rename(context),
          ),
          SettingTile(title: 'Dirección en la red', subtitle: _ip),
        ],
      ),
    );

    final receive = Panel(
      title: 'Recepción',
      icon: Symbols.download_rounded,
      child: Column(
        children: [
          SettingTile(
            title: 'Aceptar archivos sin preguntar',
            subtitle: 'Solo de dispositivos emparejados.',
            trailing: AleroSwitch(value: hub.autoAccept, onChanged: hub.setAutoAccept, label: 'Aceptar archivos sin preguntar'),
            onTap: () => hub.setAutoAccept(!hub.autoAccept),
          ),
          SettingTile(
            title: 'Carpeta de recepción',
            subtitle: hub.downloads,
            trailing: Icon(Symbols.folder_open_rounded, size: 20, color: s.onSurfaceVariant),
            onTap: hub.openDownloads,
          ),
        ],
      ),
    );

    final phone = Platform.isAndroid
        ? Panel(
            title: 'En el teléfono',
            icon: Symbols.smartphone_rounded,
            child: Column(
              children: [
                SettingTile(
                  title: 'Esperar al ordenador',
                  subtitle:
                      'Mantiene Alero activo con una notificación silenciosa. Apagado, solo trabaja con la app abierta o con un ordenador conectado.',
                  trailing: AleroSwitch(value: hub.background, onChanged: hub.setBackground, label: 'Esperar al ordenador'),
                  onTap: () => hub.setBackground(!hub.background),
                ),
                SettingTile(
                  title: 'Fondo en el ordenador',
                  subtitle: hub.customWallpaper
                      ? 'Se muestra la imagen que elegiste.'
                      : 'Se usan los colores de tu fondo. Android no deja leerlo sin un permiso amplio de archivos: elige la imagen aquí.',
                  trailing: hub.customWallpaper
                      ? TextButton(onPressed: hub.clearWallpaper, child: const Text('Quitar'))
                      : FilledButton.tonal(onPressed: hub.pickWallpaper, child: const Text('Elegir')),
                ),
              ],
            ),
          )
        : null;

    final look = Panel(
      title: 'Apariencia',
      icon: Symbols.palette_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.s),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('Sistema'), icon: Icon(Symbols.brightness_auto_rounded, size: 18)),
                ButtonSegment(value: 'light', label: Text('Claro'), icon: Icon(Symbols.light_mode_rounded, size: 18)),
                ButtonSegment(value: 'dark', label: Text('Oscuro'), icon: Icon(Symbols.dark_mode_rounded, size: 18)),
              ],
              selected: {hub.theme},
              showSelectedIcon: false,
              onSelectionChanged: (v) => hub.setTheme(v.first),
            ),
          ),
          Text(
            Platform.isAndroid
                ? 'Los colores siguen los de tu fondo de pantalla (Material You).'
                : 'Los colores siguen el color de acento de Windows (Configuración › Personalización › Colores).',
            style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
          ),
        ],
      ),
    );

    final perms = Platform.isAndroid
        ? Panel(
            title: 'Permisos',
            icon: Symbols.shield_rounded,
            child: Column(
              children: [
                _Perm(
                  icon: Symbols.notifications_rounded,
                  title: 'Avisos de la app',
                  body: 'Para avisarte de archivos recibidos y solicitudes de emparejamiento.',
                  ok: hub.notifPermission,
                  onFix: Native.openAppSettings,
                ),
                _Perm(
                  icon: Symbols.notifications_active_rounded,
                  title: 'Acceso a notificaciones',
                  body: 'Permiso especial: muestra tus notificaciones en el ordenador y deja controlar la música desde él.',
                  ok: hub.notifAccess,
                  onFix: hub.openNotifAccess,
                ),
                _Perm(
                  icon: Symbols.cast_rounded,
                  title: 'Ver la pantalla desde el ordenador',
                  body: 'Opcional. Requiere «Depuración USB» o inalámbrica; el ordenador te guía paso a paso.',
                  ok: null,
                  onFix: Native.openDevSettings,
                ),
              ],
            ),
          )
        : null;

    final diag = Panel(
      title: 'Diagnóstico',
      icon: Symbols.troubleshoot_rounded,
      action: TextButton.icon(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: hub.diagnostics.join('\n')));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Diagnóstico copiado')));
          }
        },
        icon: const Icon(Symbols.content_copy_rounded, size: 18),
        label: const Text('Copiar'),
      ),
      child: SelectableText(
        hub.diagnostics.join('\n'),
        style: t.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.6, color: s.onSurfaceVariant),
      ),
    );

    return ScreenFrame(
      title: 'Ajustes',
      children: wide
          ? [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Column(children: [device, gap, receive, gap, ?phone, if (phone != null) gap, ?perms])),
                  gap,
                  Expanded(child: Column(children: [look, gap, diag])),
                ],
              ),
            ]
          : [
              device,
              gap,
              receive,
              gap,
              if (phone != null) ...[phone, gap],
              look,
              gap,
              if (perms != null) ...[perms, gap],
              diag,
            ],
    );
  }
}

/// A permission: what it unlocks, whether it is on, and a way to the system setting.
class _Perm extends StatelessWidget {
  const _Perm({required this.icon, required this.title, required this.body, required this.ok, required this.onFix});
  final IconData icon;
  final String title, body;

  /// null: optional, no state to show.
  final bool? ok;
  final Future<void> Function() onFix;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return SettingTile(
      leading: IconTile(icon, tonal: ok == true),
      title: title,
      subtitle: ok == null ? body : '${ok! ? 'Activado' : 'Desactivado'}. $body',
      trailing: ok == true
          ? Icon(Symbols.check_circle_rounded, color: s.primary, fill: 1, semanticLabel: 'Activado')
          : TextButton(onPressed: onFix, child: Text(ok == null ? 'Abrir' : 'Activar')),
    );
  }
}
