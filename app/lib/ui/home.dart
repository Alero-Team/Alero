import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../remote.dart';
import '../src/rust/api/engine.dart' as pb;
import 'brand.dart';
import 'clipboard.dart';
import 'expressive.dart';
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
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final online = p.state == pb.PeerState.connected;
    final phone = info?.phone ?? !Platform.isAndroid;
    final facts = [
      info?.model ?? '',
      info?.osLabel ?? '',
      info?.network ?? '',
      if (online) hub.routeOf(p),
    ].where((x) => x.isNotEmpty).join(' · ');
    final picture = phone
        ? PhoneMockup(
            info: info,
            wallpaper: hub.wallpaper[p.id],
            width: 72,
            online: online,
          )
        : LaptopMockup(info: info, wallpaper: hub.wallpaper[p.id], width: 104);
    return Card(
      color: s.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Semantics(
                  button: true,
                  label: 'Ver ${p.name} en Dispositivos',
                  child: InkWell(
                    onTap: () => go(Section.devices),
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.s),
                      child: picture,
                    ),
                  ),
                ),
                const SizedBox(width: Gap.xl),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name,
                        style: t.headlineSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: Gap.xs),
                      StatusLine(p),
                      const SizedBox(height: Gap.s),
                      Wrap(
                        spacing: Gap.m,
                        runSpacing: Gap.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (facts.isNotEmpty)
                            Text(
                              facts,
                              style: t.bodyMedium?.copyWith(
                                color: s.onSurfaceVariant,
                              ),
                            ),
                          if ((info?.battery ?? -1) >= 0) BatteryLine(info!),
                          if (online)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Symbols.lock_rounded,
                                  size: 16,
                                  color: s.onSurfaceVariant,
                                ),
                                const SizedBox(width: Gap.xs),
                                Text(
                                  'Cifrada',
                                  style: t.bodyMedium?.copyWith(
                                    color: s.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      if (!online) ...[
                        const SizedBox(height: Gap.s),
                        Text(
                          p.state == pb.PeerState.rejected
                              ? 'Ese dispositivo te quitó de su lista. Vuelve a emparejarlos desde Dispositivos.'
                              : 'Abre Alero en ${p.name} y comprueba que ambos están en la misma red Wi-Fi o conéctalos con un cable USB.',
                          style: t.bodyMedium?.copyWith(
                            color: s.onSurfaceVariant,
                          ),
                        ),
                        if (!Platform.isAndroid &&
                            p.state != pb.PeerState.rejected) ...[
                          const SizedBox(height: Gap.s),
                          OutlinedButton.icon(
                            onPressed: hub.connectCable,
                            icon: const Icon(Symbols.usb_rounded, size: 18),
                            label: const Text('Conectar por cable'),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (!Platform.isAndroid) ...[
              const SizedBox(height: Gap.xl),
              // M3 Expressive button group: one primary action, the rest tonal.
              Wrap(
                spacing: Gap.s,
                runSpacing: Gap.s,
                children: [
                  FilledButton.icon(
                    onPressed: online ? () => hub.send(p.id) : null,
                    icon: const Icon(Symbols.upload_rounded, size: 18),
                    label: const Text('Enviar archivos'),
                  ),
                  ClipboardButton(hub, p.id, enabled: online),
                  if (!Platform.isAndroid && phone)
                    FilledButton.tonalIcon(
                      onPressed: online
                          ? () => openScreen(context, hub, p)
                          : null,
                      icon: const Icon(Symbols.cast_rounded, size: 18),
                      label: const Text('Controlar teléfono'),
                    ),
                ],
              ),
            ],
          ],
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

class _StatusPanel extends StatelessWidget {
  const _StatusPanel(this.info);
  final PeerInfo info;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    Widget row(
      IconData i,
      String label,
      String value,
      double? f, {
      Widget? icon,
    }) => Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Center(
              child: icon ?? Icon(i, size: 20, color: s.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(label, style: t.bodyMedium)),
                    Text(
                      value,
                      style: t.labelLarge?.copyWith(fontFeatures: tabular),
                    ),
                  ],
                ),
                if (f != null) ...[
                  const SizedBox(height: 6),
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: f.clamp(0, 1)),
                    duration: motion(
                      context,
                      const Duration(milliseconds: 600),
                    ),
                    curve: Curves.easeOutCubic,
                    builder: (_, v, _) => LinearProgressIndicator(
                      value: v,
                      semanticsLabel: label,
                      semanticsValue: value,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    final used = info.storageTotal == 0
        ? null
        : 1 - info.storageFree / info.storageTotal;
    return Panel(
      title: 'Estado',
      icon: Symbols.monitoring_rounded,
      child: Column(
        children: [
          if (info.battery >= 0)
            row(
              Symbols.battery_full_rounded,
              info.charging ? 'Batería (cargando)' : 'Batería',
              '${info.battery} %',
              info.battery / 100,
              icon: BatteryGlyph(
                info.battery,
                charging: info.charging,
                width: 20,
              ),
            ),
          if (info.chargeLabel != null)
            row(
              Symbols.bolt_rounded,
              'Carga: ${info.chargeState}',
              info.chargeLabel!,
              null,
            ),
          if (used != null)
            row(
              Symbols.hard_drive_rounded,
              'Almacenamiento',
              '${size(info.storageTotal - info.storageFree)} de ${size(info.storageTotal)}',
              used,
            ),
          if (info.network.isNotEmpty)
            row(Symbols.wifi_rounded, 'Red', info.network, null),
        ],
      ),
    );
  }
}

class _Recent extends StatelessWidget {
  const _Recent(this.hub, {required this.go});
  final Hub hub;
  final void Function(Section s) go;

  @override
  Widget build(BuildContext context) {
    final recent = hub.history.take(8).toList();
    return Panel(
      title: 'Recientes',
      icon: Symbols.history_rounded,
      action: TextButton(
        onPressed: hub.openDownloads,
        child: const Text('Abrir carpeta'),
      ),
      child: AnimatedSize(
        duration: motion(context, Spring.spatial.settle),
        curve: Spring.spatial,
        alignment: Alignment.topCenter,
        child: Column(
          children: [
            for (final x in hub.active) TransferRow(x, hub),
            if (recent.isEmpty && hub.active.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.m),
                child: Text(
                  Platform.isAndroid
                      ? 'Lo que envíes y recibas aparecerá aquí.'
                      : 'Lo que envíes y recibas aparecerá aquí. También puedes soltar archivos sobre la ventana.',
                  style: TextStyle(color: context.pal.muted),
                ),
              ),
            for (final h in recent) HistoryTile(h, hub),
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
