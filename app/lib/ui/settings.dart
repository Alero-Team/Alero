import 'package:flutter/material.dart' hide Icon, Text;
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../app_info.dart';
import '../hub.dart';
import '../native.dart';
import 'shell.dart';
import 'brand.dart';
import 'theme.dart';
import 'vault.dart';
import 'widgets.dart';
import 'icon.dart';
import 'island_panel.dart';
import '../l10n.dart';
import 'expressive.dart';
import 'alero_motion.dart';

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
  return tr('{}{}Sin el permiso esas secciones salen vacías.', [
    partial,
    missing.isEmpty
        ? ''
        : tr('Sin acceso a: {}. ', [missing.map(tx).join(', ')]),
  ]);
}

/// Material 3 Expressive connected button group: each option is its own button (round outer ends, small inner
/// corners). The chosen one fills with the primary color and rounds fully; the one under the finger widens a
/// little while its neighbours make room, and squares its corners. Same segments and callback shape as
/// SegmentedButton; each button is a [AleroPress], so keyboard and screen readers keep working.
/// A null [selected] shows none chosen; a null [onChanged] disables it.
class AleroSegments<T> extends StatefulWidget {
  const AleroSegments({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });
  final List<ButtonSegment<T>> segments;
  final T? selected;
  final ValueChanged<T>? onChanged;

  @override
  State<AleroSegments<T>> createState() => _AleroSegmentsState<T>();
}

class _AleroSegmentsState<T> extends State<AleroSegments<T>> {
  static const _outer = 20.0, _inner = 8.0, _pressed = 12.0;
  int _down = -1;

  void _press(int k) {
    if (_down != k) setState(() => _down = k);
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final segments = widget.segments;
    final n = segments.length;
    final i = segments.indexWhere((e) => e.value == widget.selected);
    final on = widget.onChanged != null;
    final spring = motion(context, Spring.fast.settle);
    final fade = AleroMotion.micro(context, Fluent.d167);
    return IntrinsicWidth(
      child: SizedBox(
        height: 40,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (k, seg) in segments.indexed) ...[
              if (k > 0) const SizedBox(width: 3),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: k == _down ? 1.18 : 1.0),
                duration: spring,
                curve: Spring.fast,
                builder: (_, w, child) =>
                    Expanded(flex: (w * 100).round(), child: child!),
                child: _segment(context, s, k, seg, k == i, n, on, spring, fade),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    ColorScheme s,
    int k,
    ButtonSegment<T> seg,
    bool chosen,
    int n,
    bool on,
    Duration spring,
    Duration fade,
  ) {
    final enabled = on && seg.enabled;
    // Outer ends round, inner corners small; the chosen one rounds fully, the pressed one squares a little.
    final left = chosen ? _outer : (k == 0 ? _outer : _inner);
    final right = chosen ? _outer : (k == n - 1 ? _outer : _inner);
    final down = k == _down;
    final fg = chosen
        ? s.onPrimary
        : s.onSurface.withValues(alpha: on ? 1 : .38);
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: chosen,
        enabled: enabled,
        child: Listener(
          onPointerDown: enabled ? (_) => _press(k) : null,
          onPointerUp: (_) => _press(-1),
          onPointerCancel: (_) => _press(-1),
          child: TweenAnimationBuilder<BorderRadius?>(
            tween: BorderRadiusTween(
              end: down
                  ? BorderRadius.circular(_pressed)
                  : BorderRadius.horizontal(
                      left: Radius.circular(left),
                      right: Radius.circular(right),
                    ),
            ),
            duration: spring,
            curve: Spring.fast,
            builder: (_, r, child) => AnimatedContainer(
              duration: fade,
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: chosen ? s.primary : s.surfaceContainerHighest,
                borderRadius: r,
              ),
              child: ClipRRect(borderRadius: r ?? BorderRadius.zero, child: child),
            ),
            child: AleroPress(
              radius: _inner,
              onTap: enabled ? () => widget.onChanged!(seg.value) : null,
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: fg),
                duration: fade,
                builder: (_, c, child) => IconTheme.merge(
                  data: IconThemeData(color: c),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: c),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    child: child!,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (seg.icon != null) ...[
                        seg.icon!,
                        const SizedBox(width: Gap.xs),
                      ],
                      Flexible(child: seg.label ?? const SizedBox()),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where the Expressive palette comes from: the wallpaper (system color) or one of a few fixed colors.
/// Small circles; the chosen one shows a check and a ring, with room around it so the ring is never cut.
class _SeedPicker extends StatelessWidget {
  const _SeedPicker(this.hub);
  final Hub hub;

  static const seeds = [
    ('wallpaper', 'Fondo de pantalla', null),
    ('ff00838f', 'Turquesa', Color(0xFF00838F)),
    ('ff7c7a12', 'Oliva', Color(0xFF7C7A12)),
    ('ff6750a4', 'Violeta', Color(0xFF6750A4)),
    ('ffc2414b', 'Coral', Color(0xFFC2414B)),
  ];

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.s, Gap.xs, Gap.s),
      child: Wrap(
        spacing: Gap.m,
        runSpacing: Gap.s,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Color', style: t.bodySmall?.copyWith(color: s.onSurfaceVariant)),
          for (final (id, name, color) in seeds)
            Tooltip(
              message: tx(name),
              child: Semantics(
                button: true,
                selected: hub.colorSeed.value == id,
                label: tx(name),
                child: GestureDetector(
                  onTap: () => hub.setColorSeed(id),
                  child: _Seed(
                    // The wallpaper's circle shows the color the system gives now.
                    color: color ?? s.primary,
                    chosen: hub.colorSeed.value == id,
                    wallpaper: color == null,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Seed extends StatelessWidget {
  const _Seed({required this.color, required this.chosen, this.wallpaper = false});
  final Color color;
  final bool chosen, wallpaper;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final on = ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return AnimatedContainer(
      duration: motion(context, Spring.fast.settle),
      curve: Curves.easeOutCubic,
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: chosen ? s.onSurface : Colors.transparent,
          width: 2,
          strokeAlign: BorderSide.strokeAlignOutside,
        ),
      ),
      child: AnimatedScale(
        scale: chosen ? 1 : .4,
        duration: motion(context, Spring.fast.settle),
        curve: Spring.fast,
        child: AnimatedOpacity(
          opacity: chosen ? 1 : (wallpaper ? .9 : 0),
          duration: AleroMotion.micro(context, Fluent.d167),
          child: Icon(
            chosen ? FluentIcons.checkmark_24_regular : FluentIcons.image_24_regular,
            size: 16,
            color: on,
          ),
        ),
      ),
    );
  }
}

final _appearanceKey = GlobalKey();

/// Set before opening Ajustes to land on Apariencia (Inicio › Personalizar › Tema y apariencia).
final showAppearance = ValueNotifier(false);

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
    final n = await showAleroDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nombre de este dispositivo'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 64,
          decoration: InputDecoration(
            labelText: tx('Nombre'),
            helperText: tx('Así te verán los otros dispositivos.'),
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

  /// A prominent, informed choice before requesting sensitive SMS access.
  /// The feature remains off until the phone owner explicitly confirms.
  Future<void> _setSmsAllowed(BuildContext context, bool enabled) async {
    if (enabled && !hub.smsAllowed) {
      final confirmed = await showAleroDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Autorizar mensajes en el ordenador'),
          content: const Text(
            'Si activas esta función, Alero podrá leer el historial de SMS '
            'y MMS del teléfono y los nombres de tus contactos. '
            'Un ordenador que hayas emparejado podrá ver esas '
            'conversaciones y enviar mensajes SMS usando tu teléfono.\n\n'
            'El contenido se transmite directamente y cifrado entre tus '
            'dispositivos, sin subirlo a una nube. La función está '
            'desactivada por defecto y puedes desactivarla aquí '
            'cuando quieras.\n\n'
            'Android te pedirá por separado los permisos necesarios '
            'para SMS y Contactos.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Entiendo y activar'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await hub.setSmsAllowed(enabled);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    const gap = SizedBox(height: Gap.l, width: Gap.l);
    final wide = MediaQuery.sizeOf(context).width >= 1180;
    if (showAppearance.value) {
      showAppearance.value = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _appearanceKey.currentContext;
        if (c != null) {
          Scrollable.ensureVisible(
            c,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }

    final device = Panel(
      title: 'Este dispositivo',
      icon: FluentIcons.contact_card_24_regular,
      child: Column(
        children: [
          SettingTile(
            title: 'Nombre',
            subtitle: hub.name,
            trailing: Icon(
              FluentIcons.edit_24_regular,
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
      icon: FluentIcons.arrow_download_24_regular,
      child: Column(
        children: [
          SettingTile(
            title: 'Aceptar archivos sin preguntar',
            subtitle: 'Solo de dispositivos emparejados.',
            trailing: AleroSwitch(
              value: hub.autoAccept,
              onChanged: hub.setAutoAccept,
              label: tx('Aceptar archivos sin preguntar'),
            ),
            onTap: () => hub.setAutoAccept(!hub.autoAccept),
          ),
          SettingTile(
            title: 'Carpeta de recepción',
            subtitle: hub.downloads,
            trailing: Icon(
              FluentIcons.folder_open_24_regular,
              size: 20,
              color: s.onSurfaceVariant,
            ),
            onTap: hub.openDownloads,
          ),
        ],
      ),
    );

    final phone = isPhone
        ? Panel(
            title: 'Seguridad',
            icon: FluentIcons.lock_closed_24_regular,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // On a phone the vault stays out of the bottom bar: it opens from here.
                SettingTile(
                  title: 'Alero Vault',
                  subtitle: 'Notas y archivos cifrados en este teléfono.',
                  trailing: const Icon(FluentIcons.chevron_right_24_regular),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const VaultScreen(),
                    ),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: Native.lock,
                  builder: (context, enabled, _) => SettingTile(
                    title: 'Bloquear Alero con huella o PIN',
                    subtitle: 'Pide el desbloqueo del sistema al abrir o volver a la app. Las conexiones emparejadas continúan en segundo plano.',
                    trailing: AleroSwitch(
                      value: enabled,
                      label: tx('Bloquear Alero'),
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
              ],
            ),
          )
        : null;

    final remote = isPhone
        ? null
        : Panel(
            title: 'Control remoto',
            icon: FluentIcons.phone_key_24_regular,
            child: Column(
              children: [
                SettingTile(
                  title: 'Permitir que mis teléfonos controlen este equipo',
                  subtitle: Native.pc
                      ? 'Mover el ratón, escribir, cambiar el volumen y la música, ver la pantalla y pedir capturas. Solo desde dispositivos emparejados; verás un aviso cuando se use. Bloquear, suspender o apagar siempre se confirman en el teléfono. Apagado por defecto.'
                      : 'Todavía no está disponible en este sistema. Solo Windows y Linux por ahora.',
                  trailing: AleroSwitch(
                    value: hub.remoteAllow,
                    onChanged: Native.pc ? hub.setRemoteAllow : (_) {},
                    label: tx('Control remoto'),
                  ),
                  onTap: Native.pc
                      ? () => hub.setRemoteAllow(!hub.remoteAllow)
                      : null,
                ),
                if (Native.pc) ...[
                  const SizedBox(height: Gap.m),
                  SettingTile(
                    title: 'Compartir carpeta con el teléfono',
                    subtitle: 'Solo se permite explorar y descargar archivos de las carpetas que elijas. La conexión debe estar emparejada. No se comparte ninguna carpeta por defecto.',
                    trailing: FilledButton.tonal(
                      onPressed: hub.addPcFolder,
                      child: const Text('Añadir'),
                    ),
                  ),
                  MotionList(
                    children: [
                      for (final folder in hub.pcFolders)
                        SettingTile(
                          key: ValueKey(folder),
                          title: folder,
                          subtitle:
                              'Carpeta compartida con teléfonos emparejados',
                          trailing: IconButton(
                            tooltip: tx('Dejar de compartir'),
                            icon: const Icon(FluentIcons.dismiss_24_regular),
                            onPressed: () => hub.removePcFolder(folder),
                          ),
                        ),
                    ],
                  ),
                  ArcExpand(
                    expanded: hub.pcFolders.isNotEmpty,
                    child: SettingTile(
                      title: 'Permitir cambios en los archivos compartidos',
                      subtitle: 'Autoriza también renombrar y eliminar archivos desde Android. Desactivado por defecto. No permite eliminar carpetas completas.',
                      trailing: AleroSwitch(
                        value: hub.pcFilesWrite,
                        onChanged: hub.setPcFileEdits,
                        label: tx('Editar archivos compartidos'),
                      ),
                      onTap: () => hub.setPcFileEdits(!hub.pcFilesWrite),
                    ),
                  ),
                ],
              ],
            ),
          );

    final files = isPhone
        ? Panel(
            title: 'Archivos para el ordenador',
            icon: FluentIcons.folder_people_24_regular,
            child: Column(
              children: [
                SettingTile(
                  title: 'Dejar que el ordenador explore mis archivos',
                  subtitle: 'Un ordenador emparejado podrá ver, descargar, renombrar y eliminar tus fotos, vídeos, música y las carpetas que añadas abajo. Las carpetas privadas de otras apps permanecen protegidas. Apagado por defecto.',
                  trailing: AleroSwitch(
                    value: hub.filesAllowed,
                    onChanged: hub.setFilesAllowed,
                    label: tx('Explorar archivos desde el ordenador'),
                  ),
                  onTap: () => hub.setFilesAllowed(!hub.filesAllowed),
                ),
                ArcExpand(
                  expanded:
                      hub.filesAllowed &&
                      (hub.filesMedia.length < 3 || hub.filesLimited),
                  child: SettingTile(
                    title: 'Permisos de fotos, vídeos y música',
                    subtitle: _mediaStatus(hub),
                    trailing: TextButton(
                      onPressed: hub.requestMedia,
                      child: const Text('Conceder'),
                    ),
                  ),
                ),
                MotionList(
                  children: [
                    for (final (i, name) in hub.filesFolders.indexed)
                      SettingTile(
                        // Names can repeat: name plus repeat count stays stable when an earlier folder is removed.
                        key: ValueKey(
                          '$name#${hub.filesFolders.take(i).where((e) => e == name).length}',
                        ),
                        leading: Icon(
                          FluentIcons.folder_24_regular,
                          size: 20,
                          color: s.onSurfaceVariant,
                        ),
                        title: name,
                        subtitle: 'Carpeta añadida',
                        trailing: IconButton(
                          tooltip: tr('Quitar {}', [name]),
                          icon: Icon(
                            FluentIcons.dismiss_24_regular,
                            size: 20,
                            color: s.onSurfaceVariant,
                          ),
                          onPressed: () => hub.removeFilesFolder(i),
                        ),
                      ),
                  ],
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

    final sms = isPhone
        ? Panel(
            title: 'Mensajes en el ordenador',
            icon: FluentIcons.chat_24_regular,
            child: SettingTile(
              title: 'Leer y enviar SMS desde el ordenador',
              subtitle: hub.smsAllowed && !hub.smsPermission
                  ? 'Falta el permiso de SMS de Android. Toca para concederlo.'
                  : 'Un ordenador emparejado verá tus conversaciones SMS y MMS (con los nombres de tus contactos) y podrá enviar SMS. Los mensajes van cifrados y directos, sin nube. Apagado por defecto.',
              trailing: AleroSwitch(
                value: hub.smsAllowed,
                onChanged: (enabled) => _setSmsAllowed(context, enabled),
                label: tx('Mensajes en el ordenador'),
              ),
              onTap: () => _setSmsAllowed(
                context,
                !hub.smsAllowed || !hub.smsPermission,
              ),
            ),
          )
        : null;

    final calls = isPhone
        ? Panel(
            title: 'Llamadas en el ordenador',
            icon: FluentIcons.call_24_regular,
            child: SettingTile(
              title: 'Contestar, colgar y llamar desde el ordenador',
              subtitle: hub.callsAllowed && !hub.callsPermission
                  ? 'Faltan los permisos de llamadas de Android. Toca para concederlos.'
                  : 'Un ordenador emparejado verá quién llama y podrá contestar, rechazar, colgar y marcar números. Hablas por el teléfono o sus auriculares. Apagado por defecto.',
              trailing: AleroSwitch(
                value: hub.callsAllowed,
                onChanged: hub.setCallsAllowed,
                label: tx('Llamadas en el ordenador'),
              ),
              onTap: () => hub.setCallsAllowed(
                !hub.callsAllowed || !hub.callsPermission,
              ),
            ),
          )
        : null;

    final look = KeyedSubtree(
      key: _appearanceKey,
      child: Panel(
        title: 'Apariencia',
        icon: FluentIcons.color_24_regular,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.s),
              child: AleroSegments<String>(
                segments: const [
                  ButtonSegment(
                    value: 'system',
                    label: FitLabel('Sistema'),
                    icon: Icon(FluentIcons.brightness_high_24_regular, size: 18),
                  ),
                  ButtonSegment(
                    value: 'light',
                    label: FitLabel('Claro'),
                    icon: Icon(FluentIcons.weather_sunny_24_regular, size: 18),
                  ),
                  ButtonSegment(
                    value: 'dark',
                    label: FitLabel('Oscuro'),
                    icon: Icon(FluentIcons.dark_theme_24_regular, size: 18),
                  ),
                ],
                selected: hub.theme,
                onChanged: hub.setTheme,
              ),
            ),
            // Material 3 Expressive's color style is an Android choice; Windows and Linux keep Alero's identity.
            if (isPhone) ...[
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.xs),
              child: Text('Estilo de color', style: t.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: AleroSegments<String>(
                segments: const [
                  ButtonSegment(value: 'alero', label: FitLabel('Alero')),
                  ButtonSegment(
                    value: 'expressive',
                    label: FitLabel('Expressive'),
                  ),
                ],
                selected: hub.colorStyle.value,
                onChanged: hub.setColorStyle,
              ),
            ),
            ArcExpand(
              expanded: hub.colorStyle.value == 'expressive',
              child: _SeedPicker(hub),
            ),
            ],
            // Named in both languages on purpose: it has to be findable whichever one the app is in now.
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.xs),
              child: Text('Idioma / Language', style: t.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.s),
              child: AleroSegments<String>(
                segments: const [
                  ButtonSegment(value: 'system', label: FitLabel('Sistema')),
                  ButtonSegment(value: 'es', label: FitLabel('Español')),
                  ButtonSegment(value: 'en', label: FitLabel('English')),
                ],
                selected: L10n.instance.pref,
                onChanged: hub.setLanguage,
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
                  label: tx('Modo AMOLED'),
                ),
              ),
              onTap: () => hub.setAmoled(!hub.amoled.value),
            ),
            const SizedBox(height: Gap.xs),
            Text(
              isPhone && hub.colorStyle.value == 'expressive'
                  ? 'Paleta tonal de Material 3 Expressive, del fondo de pantalla o del color que elijas. El reproductor toma el color de la carátula. Formas, iconos y animaciones no cambian.'
                  : 'Identidad monocroma de Alero: el mismo aspecto en Windows y Android, con el color reservado al estado (conectado, avisos, errores).',
              style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );

    final perms = isPhone
        ? Panel(
            title: 'Permisos',
            icon: FluentIcons.shield_24_regular,
            child: Column(
              children: [
                _Perm(
                  icon: FluentIcons.alert_24_regular,
                  title: 'Avisos de la app',
                  body: 'Para avisarte de archivos recibidos y solicitudes de emparejamiento.',
                  ok: hub.notifPermission,
                  onFix: Native.openAppSettings,
                ),
                _Perm(
                  icon: FluentIcons.alert_on_24_regular,
                  title: 'Acceso a notificaciones',
                  body: 'Permiso especial: muestra tus notificaciones en el ordenador y deja controlar la música desde él.',
                  ok: hub.notifAccess,
                  onFix: hub.openNotifAccess,
                ),
                MotionList(
                  children: [
                    for (final (pkg, name) in hub.mutedApps)
                      SettingTile(
                        key: ValueKey(pkg),
                        leading: Icon(
                          FluentIcons.alert_off_24_regular,
                          size: 20,
                          color: s.onSurfaceVariant,
                        ),
                        title: name,
                        subtitle: 'Silenciada en el ordenador',
                        trailing: TextButton(
                          onPressed: () => hub.unmuteApp(pkg),
                          child: const Text('Reactivar'),
                        ),
                      ),
                  ],
                ),
                _Perm(
                  icon: FluentIcons.phone_arrow_right_24_regular,
                  title: 'Instalar apps recibidas',
                  body: 'Permite abrir el instalador al tocar un APK. Cada instalación requiere confirmación de Android.',
                  ok: hub.installAllowed,
                  onFix: Native.requestInstallPermission,
                ),
                _Perm(
                  icon: FluentIcons.cast_24_regular,
                  title: 'Ver la pantalla desde el ordenador',
                  body: 'Opcional. Requiere «Depuración USB» o inalámbrica; el ordenador te guía paso a paso.',
                  ok: null,
                  onFix: Native.openDevSettings,
                ),
              ],
            ),
          )
        : null;

    // Alero Island: the overlay of the desktop app (the phone has no such thing).
    final island = Native.pc ? IslandPanel(hub) : null;

    final about = Panel(
      title: 'Acerca de Alero',
      icon: FluentIcons.info_24_regular,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AleroLogo(size: 28),
          const SizedBox(height: Gap.m),
          Text(
            tr('Alero {} · Conexión directa entre tus dispositivos.', [
              aleroRelease,
            ]),
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
              icon: const Icon(FluentIcons.document_text_24_regular, size: 18),
              label: const Text('Licencias de código abierto'),
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Alero',
                applicationVersion: '$aleroRelease ($aleroVersion)',
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
      icon: FluentIcons.stethoscope_24_regular,
      action: TextButton.icon(
        onPressed: () async {
          await Clipboard.setData(
            ClipboardData(text: hub.diagnostics.join('\n')),
          );
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showToast(const SnackBar(content: Text('Diagnóstico copiado')));
          }
        },
        icon: const Icon(FluentIcons.copy_24_regular, size: 18),
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
                        ?sms,
                        if (sms != null) gap,
                        ?calls,
                        if (calls != null) gap,
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
                        ?island,
                        if (island != null) gap,
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
              if (sms != null) ...[sms, gap],
              if (calls != null) ...[calls, gap],
              look,
              gap,
              if (remote != null) ...[remote, gap],
              if (island != null) ...[island, gap],
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
      trailing: MotionFade(
        child: ok == true
            ? Icon(
                FluentIcons.checkmark_circle_24_regular,
                key: const ValueKey('ok'),
                color: s.primary,
                fill: 1,
                semanticLabel: tx('Activado'),
              )
            : TextButton(
                key: const ValueKey('fix'),
                onPressed: onFix,
                child: Text(ok == null ? 'Abrir' : 'Activar'),
              ),
      ),
    );
  }
}
