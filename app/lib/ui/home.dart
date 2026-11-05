import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../remote.dart';
import '../src/rust/api/engine.dart' as pb;
import 'brand.dart';
import 'clipboard.dart';
import 'expressive.dart';
import 'alero_motion.dart';
import 'media.dart';
import 'notifications.dart';
import 'phone_home.dart';
import 'screen.dart';
import 'shell.dart';
import 'theme.dart';
import 'controls.dart';
import 'widgets.dart';

/// The connected device Home is about: the first paired one online, else the first paired.
pb.Peer? mainPeer(Hub hub) {
  final trusted = hub.peers.where((p) => p.trusted);
  return trusted.where((p) => p.state == pb.PeerState.connected).firstOrNull ??
      trusted.firstOrNull;
}

/// Everything you do with the connected device, in one place: who it is and its state, what you can do
/// (send, clipboard, screen), what it is playing, its notifications and what moved recently.
class HomeScreen extends StatelessWidget {
  const HomeScreen(this.hub, {super.key, required this.go});
  final Hub hub;
  final void Function(Section s) go;

  @override
  Widget build(BuildContext context) {
    final main = mainPeer(hub);
    final wide = MediaQuery.sizeOf(context).width >= 1180;
    final online = main?.state == pb.PeerState.connected;
    final info = main == null ? null : hub.info[main.id];
    final phone = info?.phone ?? false;

    if (main == null) {
      return ScreenFrame(
        title: 'Inicio',
        children: [
          if (hub.startError.isNotEmpty) ...[
            ErrorBanner(hub.startError),
            const SizedBox(height: Gap.l),
          ],
          _Welcome(go: go),
        ],
      );
    }

    final hero = _Hero(main, info, hub, go: go);
    final recent = _Recent(hub, go: go);
    final filePanel = _FilePanel(hub, main, go: go);
    final media = online && phone ? MediaPanel(hub, main.id, compact: !Platform.isAndroid) : null;
    final notifs = online && phone ? NotificationsPanel(hub, main.id) : null;
    final controls = online && phone && !Platform.isAndroid
        ? PhoneControlsPanel(hub, main)
        : null;
    final status = phone && info != null ? _StatusPanel(info, online: online) : null;
    const gap = SizedBox(height: Gap.l, width: Gap.l);

    if (Platform.isAndroid && !phone) {
      return ScreenFrame(
        title: 'Inicio',
        maxWidth: 980,
        onRefresh: hub.refresh,
        children: [
          Text('Resumen de ' + main.name,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              )),
          gap,
          hero,
          gap,
          QuickActions(hub, main),
          gap,
          ControlCard(hub, main),
          gap,
          MediaPanel(hub, main.id, computer: true),
          gap,
          filePanel,
          gap,
          recent,
        ],
      );
    }

    final dashboard = <Widget>[
      if (hub.startError.isNotEmpty) ...[ErrorBanner(hub.startError), gap],
      if (Platform.isAndroid && !hub.notifAccess) ...[_AccessHint(hub), gap],
      Text('Resumen de ' + main.name,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          )),
      gap,
      if (wide && !Platform.isAndroid) ...[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 2, child: hero),
            gap,
            Expanded(
              child: media ?? const Panel(
                title: 'Reproductor',
                icon: Symbols.music_note_rounded,
                child: Text('No hay música en reproducción.'),
              ),
            ),
          ],
        ),
        gap,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: notifs ?? const Panel(
                title: 'Notificaciones',
                icon: Symbols.notifications_rounded,
                child: Text('Sin notificaciones.'),
              ),
            ),
            gap,
            Expanded(child: filePanel),
            gap,
            Expanded(
              child: status ?? const Panel(
                title: 'Estado del dispositivo',
                icon: Symbols.info_rounded,
                child: Text('Conecta el teléfono para ver su estado.'),
              ),
            ),
          ],
        ),
        gap,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: controls ?? const Panel(
                title: 'Controles rápidos',
                icon: Symbols.tune_rounded,
                child: Text('El teléfono no está conectado.'),
              ),
            ),
            gap,
            Expanded(flex: 2, child: recent),
          ],
        ),
      ] else ...[
        hero,
        gap,
        if (media != null) ...[media, gap],
        if (notifs != null) ...[notifs, gap],
        filePanel,
        gap,
        if (status != null) ...[status, gap],
        if (controls != null) ...[controls, gap],
        recent,
      ],
    ];

    return ScreenFrame(
      title: 'Inicio',
      maxWidth: 1920,
      trailing: !Platform.isAndroid
          ? OutlinedButton.icon(
              onPressed: () => go(Section.settings),
              icon: const Icon(Symbols.dashboard_customize_rounded),
              label: const Text('Personalizar'),
            )
          : null,
      children: dashboard,
    );
  }
}

/// First run (nothing paired yet): the mark draws itself and the next step is one button.
class _Welcome extends StatelessWidget {
  const _Welcome({required this.go});
  final void Function(Section s) go;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    return Card(
      color: s.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(
          children: [
            const AleroIntro(size: 72),
            const SizedBox(height: Gap.l),
            Text(
              'Bienvenido a Alero',
              style: t.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Gap.s),
            Text(
              'Abre Alero en el otro dispositivo, en la misma red Wi-Fi o con un cable USB, y empareja los dos.',
              style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Gap.xl),
            FilledButton.icon(
              onPressed: () => go(Section.devices),
              icon: const Icon(Symbols.add_link_rounded, size: 18),
              label: const Text('Emparejar un dispositivo'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero(this.p, this.info, this.hub, {required this.go});
  final pb.Peer p;
  final PeerInfo? info;
  final Hub hub;
  final void Function(Section s) go;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    final online = p.state == pb.PeerState.connected;
    final phone = info?.phone ?? !Platform.isAndroid;
    final picture = phone
        ? PhoneMockup(
            info: info,
            wallpaper: hub.wallpaper[p.id],
            width: 84,
            online: online,
          )
        : LaptopMockup(info: info, wallpaper: hub.wallpaper[p.id], width: 104);

    Widget property(IconData icon, String value) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: colors.onSurfaceVariant),
          const SizedBox(width: 7),
          Text(value, style: type.labelSmall),
        ],
      ),
    );

    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: online ? () => hub.send(p.id) : null,
          icon: const Icon(Symbols.upload_rounded, size: 18),
          label: const Text('Enviar archivos'),
        ),
        ClipboardButton(hub, p.id, enabled: online),
        if (phone && !Platform.isAndroid)
          OutlinedButton.icon(
            onPressed: () => go(Section.explorer),
            icon: const Icon(Symbols.folder_open_rounded, size: 18),
            label: const Text('Explorar archivos'),
          ),
        if (phone && !Platform.isAndroid)
          OutlinedButton.icon(
            onPressed: online ? () => openScreen(context, hub, p) : null,
            icon: const Icon(Symbols.cast_rounded, size: 18),
            label: const Text('Controlar teléfono'),
          ),
      ],
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: LayoutBuilder(
          builder: (context, box) {
            final phoneSize = box.maxWidth < 420 ? 70.0 : 104.0;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: phoneSize,
                      child: Semantics(
                        button: true,
                        label: 'Dispositivo ' + p.name,
                        child: InkWell(
                          onTap: () => go(Section.devices),
                          borderRadius: BorderRadius.circular(12),
                          child: Center(child: picture),
                        ),
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 10,
                            runSpacing: 6,
                            children: [
                              Text(p.name, style: type.headlineSmall,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              StatusLine(p),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 7,
                            runSpacing: 7,
                            children: [
                              if ((info?.model ?? '').isNotEmpty)
                                property(Symbols.smartphone_rounded, info!.model),
                              if ((info?.osLabel ?? '').isNotEmpty)
                                property(Symbols.layers_rounded, info!.osLabel),
                              if ((info?.network ?? '').isNotEmpty)
                                property(Symbols.wifi_rounded, info!.network),
                              if (online)
                                property(Symbols.verified_user_rounded, 'Conexión cifrada'),
                            ],
                          ),
                          if ((info?.battery ?? -1) >= 0) ...[
                            const SizedBox(height: 13),
                            Row(
                              children: [
                                BatteryGlyph(info!.battery, charging: info!.charging),
                                const SizedBox(width: 8),
                                Text(
                                  '${info!.battery}%',
                                  style: type.titleLarge,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: LinearProgressIndicator(
                                    value: (info!.battery / 100).clamp(0, 1),
                                    minHeight: 7,
                                    borderRadius: BorderRadius.circular(30),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (!online) ...[
                  const SizedBox(height: 12),
                  Text('Comprueba que ambos dispositivos estén conectados a la misma red.',
                      style: type.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      )),
                ],
                const SizedBox(height: 18),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

class BatteryLine extends StatelessWidget {
  const BatteryLine(this.info, {super.key});
  final PeerInfo info;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        BatteryGlyph(info.battery, charging: info.charging),
        const SizedBox(width: Gap.xs + 2),
        Text(
          '${info.battery} %${info.charging ? ' · cargando' : ''}',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: s.onSurfaceVariant, fontFeatures: tabular),
        ),
      ],
    );
  }
}

class _FilePanel extends StatelessWidget {
  const _FilePanel(this.hub, this.peer, {required this.go});
  final Hub hub;
  final pb.Peer peer;
  final void Function(Section s) go;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final online = peer.state == pb.PeerState.connected;
    return Panel(
      title: 'Archivos',
      icon: Symbols.folder_rounded,
      child: Column(
        children: [
          InkWell(
            onTap: online ? () => hub.send(peer.id) : null,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.outlineVariant,
                    style: BorderStyle.solid),
                color: colors.surfaceContainerLow,
              ),
              child: Column(
                children: [
                  Icon(Symbols.upload_rounded, size: 26, color: colors.onSurface),
                  const SizedBox(height: 8),
                  Text('Arrastra archivos aquí', style: text.titleSmall),
                  const SizedBox(height: 4),
                  Text('o selecciónalos desde tu equipo',
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: online ? () => hub.send(peer.id) : null,
                    child: const Text('Seleccionar archivos'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton(
                onPressed: online ? () => hub.send(peer.id) : null,
                child: const Text('Enviar archivos'),
              ),
              const Spacer(),
              TextButton(
                onPressed: Platform.isAndroid
                    ? hub.openDownloads
                    : () => go(Section.explorer),
                child: const Text('Abrir explorador'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel(this.info, {required this.online});
  final PeerInfo info;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final total = info.storageTotal;
    final used = total > 0 ? total - info.storageFree : 0;

    Widget metric(IconData icon, String label, String value, {double? progress}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: colors.onSurfaceVariant),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(child: Text(label, style: text.titleSmall)),
                        Flexible(
                          child: Text(value,
                            maxLines: 2,
                            textAlign: TextAlign.end,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (progress != null) ...[
                      const SizedBox(height: 9),
                      LinearProgressIndicator(
                        value: progress.clamp(0, 1),
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );

    return Panel(
      title: 'Estado del dispositivo',
      icon: Symbols.info_rounded,
      child: Column(
        children: [
          if (total > 0)
            metric(Symbols.hard_drive_rounded, 'Almacenamiento',
                '${size(used)} de ${size(total)}',
                progress: used / total),
          metric(Symbols.wifi_rounded, 'Conectividad',
              info.network.isEmpty ? 'Sin conexión' : info.network),
          metric(Symbols.shield_rounded, 'Seguridad',
              online ? 'Conexión cifrada' : 'Desconectado'),
          metric(Symbols.content_paste_rounded, 'Sincronización',
              online ? 'Portapapeles activo' : 'Sin conexión'),
          if (info.chargeLabel != null)
            metric(Symbols.bolt_rounded, 'Carga',
                info.chargeLabel!),
        ],
      ),
    );
  }
}

class _Recent extends StatefulWidget {
  const _Recent(this.hub, {required this.go});
  final Hub hub;
  final void Function(Section s) go;

  @override
  State<_Recent> createState() => _RecentState();
}

class _RecentState extends State<_Recent> {
  String filter = 'Todo';

  Widget filters() => Wrap(
    spacing: 4,
    children: [
      for (final value in const ['Todo', 'Enviados', 'Recibidos'])
        ChoiceChip(
          label: Text(value),
          selected: filter == value,
          onSelected: (_) => setState(() => filter = value),
          visualDensity: VisualDensity.compact,
          labelStyle: Theme.of(context).textTheme.labelSmall,
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final hub = widget.hub;
    final matches = (bool incoming) => filter == 'Todo' ||
        (filter == 'Recibidos' && incoming) ||
        (filter == 'Enviados' && !incoming);
    final recent = hub.history.where((h) => matches(h.incoming)).take(8).toList();
    final active = hub.active.where((x) => matches(x.incoming)).toList();
    final wide = MediaQuery.sizeOf(context).width >= 1180;
    return Panel(
      title: 'Actividad reciente',
      icon: Symbols.history_rounded,
      action: wide ? filters() : null,
      child: AnimatedSize(
        duration: AleroMotion.duration(context, 320),
        curve: AleroMotion.spatial,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!wide) ...[
              filters(),
              const SizedBox(height: 12),
            ],
            for (final x in active) TransferRow(x, hub),
            if (recent.isEmpty && active.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.m),
                child: Text(
                  'Todavía no hay archivos en esta categoría.',
                  style: TextStyle(color: context.pal.muted),
                ),
              ),
            for (final h in recent) HistoryTile(h, hub),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: hub.openDownloads,
                child: const Text('Abrir carpeta de descargas'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Phone without notification access: what it unlocks and where to turn it on.
class _AccessHint extends StatelessWidget {
  const _AccessHint(this.hub);
  final Hub hub;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Symbols.notifications_active_rounded,
    title: 'Ver tus notificaciones y tu música en el ordenador',
    body: 'Android pide «Acceso a notificaciones» para leerlas y controlar lo que suena.',
    action: 'Activar',
    onAction: hub.openNotifAccess,
  );
}
