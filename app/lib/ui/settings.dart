import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../app_info.dart';
import '../hub.dart';
import '../native.dart';
import 'shell.dart';
import 'brand.dart';
import 'theme.dart';
import 'widgets.dart';

/// What Android has and has not granted, so the row never says "granted" for something that is not.
String _mediaStatus(Hub hub) {
  final m = hub.filesMedia;
  final missing = [
    if (!m.contains('images')) 'fotos',
    if (!m.contains('video')) 'vídeos',
    if (!m.contains('audio')) 'música y audio',
  ];
  final partial = hub.filesLimited
      ? 'Solo compartes las fotos que elegiste. '
      : '';
  return '$partial${missing.isEmpty ? '' : 'Sin acceso a: ${missing.join(', ')}. '}Sin el permiso esas secciones salen vacías.';
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen(this.hub, {super.key});
  final Hub hub;

  /// The engine reports `local address: <ip>` among its diagnostics.
  String get _ip => hub.diagnostics
      .firstWhere(
        (l) => l.startsWith('local address: '),
        orElse: () => 'local address: —',
      )
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
          decoration: const InputDecoration(
            labelText: 'Nombre',
            helperText: 'Así te verán los otros dispositivos.',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('Guardar'),
          ),
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
            trailing: Icon(
              Symbols.edit_rounded,
              size: 20,
              color: s.onSurfaceVariant,
            ),
            onTap: () => _rename(context),
          ),
          SettingTile(title: 'Dirección en la red', subtitle: _ip),
          SettingTile(
            title: 'Configuración inicial',
            subtitle: 'Revisar nombre, permisos y emparejamiento.',
            onTap: hub.reopenSetup,
          ),
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
            trailing: AleroSwitch(
              value: hub.autoAccept,
              onChanged: hub.setAutoAccept,
              label: 'Aceptar archivos sin preguntar',
            ),
            onTap: () => hub.setAutoAccept(!hub.autoAccept),
          ),
          SettingTile(
            title: 'Carpeta de recepción',
            subtitle: hub.downloads,
            trailing: Icon(
              Symbols.folder_open_rounded,
              size: 20,
              color: s.onSurfaceVariant,
            ),
            onTap: hub.openDownloads,
          ),
        ],
      ),
    );

    final phone = Platform.isAndroid
        ? Panel(
            title: 'Seguridad',
            icon: Symbols.lock_rounded,
            child: ValueListenableBuilder<bool>(
              valueListenable: Native.lock,
              builder: (context, enabled, _) => SettingTile(
                title: 'Bloquear Alero con huella o PIN',
                subtitle: 'Pide el desbloqueo del sistema al abrir o volver a la app. Las conexiones emparejadas continúan en segundo plano.',
                trailing: AleroSwitch(
                  value: enabled,
                  label: 'Bloquear Alero',
                  onChanged: (on) async {
                    try {
                      await Native.setLock(on);
                    } on PlatformException catch (e) {
                      hub.messages.add(
                        e.message ?? 'No se pudo configurar el bloqueo.',
                      );
                    }
                  },
                ),
              ),
            ),
          )
        : null;

    final remote = Platform.isAndroid
        ? null
        : Panel(
            title: 'Control remoto',
            icon: Symbols.settings_remote_rounded,
            child: Column(
              children: [
                SettingTile(
                  title: 'Permitir que mis teléfonos controlen este equipo',
                  subtitle: Platform.isWindows
                      ? 'Mover el ratón, escribir, cambiar el volumen y la música, ver la pantalla y pedir capturas. Solo desde dispositivos emparejados; verás un aviso cuando se use. Bloquear o suspender siempre se confirman en el teléfono. Apagado por defecto.'
                      : 'Todavía no está disponible en este sistema (hace falta uinput y el portal de pantalla). Solo Windows por ahora.',
                  trailing: AleroSwitch(
                    value: hub.remoteAllow,
                    onChanged: Platform.isWindows ? hub.setRemoteAllow : (_) {},
                    label: 'Control remoto',
                  ),
                  onTap: Platform.isWindows
                      ? () => hub.setRemoteAllow(!hub.remoteAllow)
                      : null,
                ),
              ],
            ),
          );

    final files = Platform.isAndroid
        ? Panel(
            title: 'Archivos para el ordenador',
            icon: Symbols.folder_shared_rounded,
            child: Column(
              children: [
                SettingTile(
                  title: 'Dejar que el ordenador explore mis archivos',
                  subtitle: 'Un ordenador emparejado podrá ver y descargar tus fotos, vídeos, música y las carpetas que añadas abajo. Las carpetas privadas de otras apps permanecen protegidas. Apagado por defecto.',
                  trailing: AleroSwitch(
                    value: hub.filesAllowed,
                    onChanged: hub.setFilesAllowed,
                    label: 'Explorar archivos desde el ordenador',
                  ),
                  onTap: () => hub.setFilesAllowed(!hub.filesAllowed),
                ),
                if (hub.filesAllowed &&
                    (hub.filesMedia.length < 3 || hub.filesLimited))
                  SettingTile(
                    title: 'Permisos de fotos, vídeos y música',
                    subtitle: _mediaStatus(hub),
                    trailing: TextButton(
                      onPressed: hub.requestMedia,
                      child: const Text('Conceder'),
                    ),
                  ),
                for (final (i, name) in hub.filesFolders.indexed)
                  SettingTile(
                    leading: Icon(
                      Symbols.folder_rounded,
                      size: 20,
                      color: s.onSurfaceVariant,
                    ),
                    title: name,
                    subtitle: 'Carpeta añadida',
                    trailing: IconButton(
                      tooltip: 'Quitar $name',
                      icon: Icon(
                        Symbols.close_rounded,
                        size: 20,
                        color: s.onSurfaceVariant,
                      ),
                      onPressed: () => hub.removeFilesFolder(i),
                    ),
                  ),
                SettingTile(
                  title: 'Todas las carpetas del dispositivo',
                  subtitle: hub.allFiles
                      ? 'Acceso concedido al almacenamiento compartido.'
                      : 'Permite explorar el almacenamiento compartido completo. Android mantiene privadas las carpetas de otras apps.',
                  trailing: TextButton(
                    onPressed: Native.requestAllFiles,
                    child: Text(hub.allFiles ? 'Gestionar' : 'Permitir'),
                  ),
                ),
                SettingTile(
                  title: 'Añadir una carpeta',
                  subtitle: 'Android te deja elegir cuál (por ejemplo Documentos). Solo se comparte esa carpeta.',
                  trailing: FilledButton.tonal(
                    onPressed: hub.addFilesFolder,
                    child: const Text('Añadir'),
                  ),
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
                ButtonSegment(
                  value: 'system',
                  label: Text('Sistema'),
                  icon: Icon(Symbols.brightness_auto_rounded, size: 18),
                ),
                ButtonSegment(
                  value: 'light',
                  label: Text('Claro'),
                  icon: Icon(Symbols.light_mode_rounded, size: 18),
                ),
                ButtonSegment(
                  value: 'dark',
                  label: Text('Oscuro'),
                  icon: Icon(Symbols.dark_mode_rounded, size: 18),
                ),
              ],
              selected: {hub.theme},
              showSelectedIcon: false,
              onSelectionChanged: (v) => hub.setTheme(v.first),
            ),
          ),
          SettingTile(
            title: 'Modo AMOLED',
            subtitle: 'Negro puro como fondo del tema oscuro. Ahorra batería en pantallas OLED. Solo se nota cuando el tema oscuro está en uso.',
            trailing: ValueListenableBuilder(
              valueListenable: hub.amoled,
              builder: (_, on, _) => AleroSwitch(
                value: on,
                onChanged: hub.setAmoled,
                label: 'Modo AMOLED',
              ),
            ),
            onTap: () => hub.setAmoled(!hub.amoled.value),
          ),
          const SizedBox(height: Gap.xs),
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
                  icon: Symbols.install_mobile_rounded,
                  title: 'Instalar apps recibidas',
                  body: 'Permite abrir el instalador al tocar un APK. Cada instalación requiere confirmación de Android.',
                  ok: null,
                  onFix: Native.requestInstallPermission,
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

    final about = Panel(
      title: 'Acerca de Alero',
      icon: Symbols.info_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AleroLogo(size: 28),
          const SizedBox(height: Gap.m),
          Text(
            'Versión $aleroVersion · Conexión directa entre tus dispositivos.',
            style: t.bodyMedium,
          ),
          const SizedBox(height: Gap.s),
          Text(
            'Software libre bajo GNU GPL v3 o posterior.',
            style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
          ),
          const SizedBox(height: Gap.s),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Symbols.description_rounded, size: 18),
              label: const Text('Licencias de código abierto'),
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Alero',
                applicationVersion: aleroVersion,
                applicationIcon: const Padding(
                  padding: EdgeInsets.all(Gap.l),
                  child: AleroMark(size: 56),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final diag = Panel(
      title: 'Diagnóstico',
      icon: Symbols.troubleshoot_rounded,
      action: TextButton.icon(
        onPressed: () async {
          await Clipboard.setData(
            ClipboardData(text: hub.diagnostics.join('\n')),
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Diagnóstico copiado')),
            );
          }
        },
        icon: const Icon(Symbols.content_copy_rounded, size: 18),
        label: const Text('Copiar'),
      ),
      child: SelectableText(
        hub.diagnostics.join('\n'),
        style: t.bodySmall?.copyWith(
          fontFamily: 'monospace',
          height: 1.6,
          color: s.onSurfaceVariant,
        ),
      ),
    );

    return ScreenFrame(
      title: 'Ajustes',
      children: wide
          ? [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        device,
                        gap,
                        receive,
                        gap,
                        ?phone,
                        if (phone != null) gap,
                        ?files,
                        if (files != null) gap,
                        ?perms,
                      ],
                    ),
                  ),
                  gap,
                  Expanded(
                    child: Column(
                      children: [
                        look,
                        gap,
                        ?remote,
                        if (remote != null) gap,
                        diag,
                        gap,
                        about,
                      ],
                    ),
                  ),
                ],
              ),
            ]
          : [
              device,
              gap,
              receive,
              gap,
              if (phone != null) ...[phone, gap],
              if (files != null) ...[files, gap],
              look,
              gap,
              if (remote != null) ...[remote, gap],
              if (perms != null) ...[perms, gap],
              diag,
              gap,
              about,
            ],
    );
  }
}

/// A permission: what it unlocks, whether it is on, and a way to the system setting.
class _Perm extends StatelessWidget {
  const _Perm({
    required this.icon,
    required this.title,
    required this.body,
    required this.ok,
    required this.onFix,
  });
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
      subtitle: ok == null
          ? body
          : '${ok! ? 'Activado' : 'Desactivado'}. $body',
      trailing: ok == true
          ? Icon(
              Symbols.check_circle_rounded,
              color: s.primary,
              fill: 1,
              semanticLabel: 'Activado',
            )
          : TextButton(
              onPressed: onFix,
              child: Text(ok == null ? 'Abrir' : 'Activar'),
            ),
    );
  }
}
