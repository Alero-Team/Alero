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
import 'settings.dart' show showAppearance;
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

    final recent = _Recent(hub, go: go);
    final media = online && phone
        ? MediaPanel(hub, main.id, compact: !Platform.isAndroid)
        : null;
    final notifs = online && phone ? NotificationsPanel(hub, main.id) : null;
    final controls = online && phone && !Platform.isAndroid
        ? PhoneControlsPanel(hub, main)
        : null;
    final status = phone && info != null
        ? _StatusPanel(info, online: online)
        : null;
    // The device card carries its state too: one tile for who it is, what it has and what you can do.
    final hero = _Hero(main, info, hub, go: go, status: status);
    final scale = TileScale.forSize(hub.tileSize.value);
    final gap = SizedBox(height: Gap.l * scale, width: Gap.l * scale);

    if (Platform.isAndroid && !phone) {
      return ScreenFrame(
        title: 'Inicio',
        maxWidth: 980,
        onRefresh: hub.refresh,
        trailing: IconButton(
          tooltip: 'Personalizar',
          onPressed: () => _customize(context, hub, go),
          icon: const Icon(Symbols.dashboard_customize_rounded),
        ),
        children: [
          Text(
            'Resumen de ${main.name}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          gap,
          // Same order as the computer's Inicio: device, what it plays, its controls, then activity.
          TileScale(
            scale,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                hero,
                gap,
                MediaPanel(hub, main.id, computer: true),
                gap,
                recent,
              ],
            ),
          ),
        ],
      );
    }

    final dashboard = <Widget>[
      if (hub.startError.isNotEmpty) ...[ErrorBanner(hub.startError), gap],
      if (Platform.isAndroid && !hub.notifAccess) ...[_AccessHint(hub), gap],
      Text(
        'Resumen de ${main.name}',
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      gap,
      if (wide && !Platform.isAndroid) ...[
        // Left: the device, its state and what it plays; right: its controls and notifications.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  hero,
                  gap,
                  media ??
                      const Panel(
                        title: 'Reproductor',
                        icon: Symbols.music_note_rounded,
                        child: Text('No hay música en reproducción.'),
                      ),
                ],
              ),
            ),
            gap,
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  controls ??
                      const Panel(
                        title: 'Controles rápidos',
                        icon: Symbols.tune_rounded,
                        child: Text(
                          'Conecta el teléfono para usar sus controles.',
                        ),
                      ),
                  gap,
                  notifs ??
                      const Panel(
                        title: 'Notificaciones',
                        icon: Symbols.notifications_rounded,
                        child: Text('Sin notificaciones.'),
                      ),
                ],
              ),
            ),
          ],
        ),
        gap,
        recent,
      ] else ...[
        hero,
        gap,
        if (media != null) ...[media, gap],
        if (controls != null) ...[controls, gap],
        if (notifs != null) ...[notifs, gap],
        recent,
      ],
    ];

    return ScreenFrame(
      title: 'Inicio',
      maxWidth: 1920,
      trailing: !Platform.isAndroid
          ? OutlinedButton.icon(
              onPressed: () => _customize(context, hub, go),
              icon: const Icon(Symbols.dashboard_customize_rounded),
              label: const Text('Personalizar'),
            )
          : null,
      children: [
        TileScale(
          scale,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: dashboard,
          ),
        ),
      ],
    );
  }
}

/// Personalizar: the size of Home's tiles, applied at once; theme and the rest stay in Ajustes.
Future<void> _customize(
  BuildContext context,
  Hub hub,
  void Function(Section) go,
) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: const Text('Personalizar inicio'),
    content: ListenableBuilder(
      listenable: hub.tileSize,
      builder: (ctx, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tamaño de los mosaicos'),
          const SizedBox(height: Gap.s),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'compact', label: Text('Compacto')),
              ButtonSegment(value: 'normal', label: Text('Normal')),
              ButtonSegment(value: 'large', label: Text('Amplio')),
            ],
            selected: {hub.tileSize.value},
            onSelectionChanged: (v) => hub.setTileSize(v.first),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          Navigator.pop(ctx);
          showAppearance.value = true;
          go(Section.settings);
        },
        child: const Text('Tema y apariencia'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Listo'),
      ),
    ],
  ),
);

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
  const _Hero(this.p, this.info, this.hub, {required this.go, this.status});
  final Widget? status;
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

    // Every shortcut lives in this card, as the prototype's buttons, on the computer and on the phone.
    final actions = Platform.isAndroid
        ? QuickActions(hub, p)
        : Wrap(
            spacing: Gap.s,
            runSpacing: Gap.s,
            children: [
              FilledButton.icon(
                onPressed: online ? () => hub.send(p.id) : null,
                icon: const Icon(Symbols.upload_rounded, size: 18),
                label: const Text('Enviar archivos'),
              ),
              FilledButton.tonalIcon(
                onPressed: online
                    ? () => openClipboard(context, hub, p.id)
                    : null,
                icon: const Icon(Symbols.content_paste_go_rounded, size: 18),
                label: const Text('Portapapeles'),
              ),
              if (phone)
                OutlinedButton.icon(
                  onPressed: () => go(Section.explorer),
                  icon: const Icon(Symbols.folder_open_rounded, size: 18),
                  label: const Text('Explorar archivos'),
                ),
              if (phone)
                OutlinedButton.icon(
                  onPressed: online ? () => openScreen(context, hub, p) : null,
                  icon: const Icon(Symbols.cast_rounded, size: 18),
                  label: const Text('Controlar teléfono'),
                ),
            ],
          );

    return Card(
      child: Padding(
        padding: EdgeInsets.all(20 * TileScale.of(context)),
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
                        label: 'Ver ${p.name} en Dispositivos',
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
                              Text(
                                p.name,
                                style: type.headlineSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              StatusLine(p),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 7,
                            runSpacing: 7,
                            children: [
                              if ((info?.model ?? '').isNotEmpty)
                                property(
                                  Symbols.smartphone_rounded,
                                  info!.model,
                                ),
                              if ((info?.osLabel ?? '').isNotEmpty)
                                property(Symbols.layers_rounded, info!.osLabel),
                              if ((info?.network ?? '').isNotEmpty)
                                property(Symbols.wifi_rounded, info!.network),
                              if (online)
                                property(
                                  Symbols.verified_user_rounded,
                                  'Conexión cifrada',
                                ),
                            ],
                          ),
                          if ((info?.battery ?? -1) >= 0) ...[
                            const SizedBox(height: 13),
                            Row(
                              children: [
                                BatteryGlyph(
                                  info!.battery,
                                  charging: info!.charging,
                                ),
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
                  Text(
                    'Comprueba que ambos dispositivos estén conectados a la misma red.',
                    style: type.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                actions,
                if (status != null) ...[
                  const SizedBox(height: Gap.l),
                  Divider(color: colors.outlineVariant),
                  status!,
                ],
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
        AleroMotion.number(
          '${info.battery} %${info.charging ? ' · cargando' : ''}',
          Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: s.onSurfaceVariant, fontFeatures: tabular),
        ),
      ],
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

    Widget metric(
      IconData icon,
      String label,
      String value, {
      double? progress,
    }) => Padding(
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
                    Text(label, style: text.titleSmall),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: Text(
                        value,
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

    return Column(
      children: [
        if (total > 0)
          metric(
            Symbols.hard_drive_rounded,
            'Almacenamiento',
            '${size(used)} de ${size(total)}',
            progress: used / total,
          ),
        metric(
          Symbols.wifi_rounded,
          'Conectividad',
          info.network.isEmpty ? 'Sin conexión' : info.network,
        ),
        if (info.chargeLabel != null)
          metric(Symbols.bolt_rounded, 'Carga', info.chargeLabel!),
      ],
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
    bool matches(bool incoming) =>
        filter == 'Todo' ||
        (filter == 'Recibidos' && incoming) ||
        (filter == 'Enviados' && !incoming);
    final recent = hub.history
        .where((h) => matches(h.incoming))
        .take(8)
        .toList();
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
            if (!wide) ...[filters(), const SizedBox(height: 12)],
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
