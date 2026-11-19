import 'package:flutter/material.dart' hide Icon, Text;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../hub.dart';
import '../native.dart';
import '../remote.dart';
import '../src/rust/api/engine.dart' as pb;
import 'adb_connection.dart';
import 'connect_help.dart';
import 'pc_details.dart';
import 'alero_motion.dart';
import 'qr.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';
import 'icon.dart';
import '../l10n.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen(this.hub, {super.key});
  final Hub hub;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final _addr = TextEditingController();

  @override
  void dispose() {
    _addr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hub = widget.hub;
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final paired = hub.peers.where((p) => p.trusted).toList();
    final nearby = hub.peers.where((p) => !p.trusted).toList();
    final wide = MediaQuery.sizeOf(context).width >= 1180;

    final pairedPanel = Panel(
      title: 'Emparejados',
      icon: FluentIcons.shield_checkmark_24_regular,
      child: Column(
        children: [
          ArcExpand(
            expanded: paired.isEmpty,
            child: const EmptyState(
              card: false,
              icon: FluentIcons.phone_desktop_24_regular,
              title: 'Ninguno todavía',
              body: 'Empareja tu teléfono con el código QR o desde la lista de la red.',
            ),
          ),
          MotionList(
            children: [
              for (final p in paired) _Paired(p, hub, key: ValueKey(p.id)),
            ],
          ),
        ],
      ),
    );

    final nearbyPanel = Panel(
      title: 'En esta red',
      icon: FluentIcons.wifi_1_24_regular,
      child: Column(
        children: [
          ArcExpand(
            expanded: nearby.isEmpty,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.s),
              child: Text(
                'No hay nada a la vista. Abre Alero en el otro dispositivo, en la misma red Wi-Fi, o conéctalos con un cable.',
                style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
              ),
            ),
          ),
          MotionList(
            children: [
              for (final p in nearby)
                Padding(
                  key: ValueKey(p.id),
                  padding: const EdgeInsets.symmetric(vertical: Gap.s),
                  child: Row(
                    children: [
                      const IconTile(FluentIcons.phone_desktop_24_regular),
                      const SizedBox(width: Gap.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.name, style: t.titleSmall),
                            Text(
                              p.addr,
                              style: t.bodySmall?.copyWith(
                                color: s.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: () => hub.pair(p.id),
                        child: const Text('Emparejar'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    final qrPanel = Panel(
      title: 'Código QR',
      icon: FluentIcons.qr_code_24_regular,
      child: isPhone
          ? Row(
              children: [
                Expanded(
                  child: Text(
                    'En el ordenador abre Dispositivos y escanea el código que aparece.',
                    style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: Gap.m),
                FilledButton.icon(
                  onPressed: () async {
                    final code = await Native.scanQr();
                    if (code != null && code.isNotEmpty) await hub.pairQr(code);
                  },
                  icon: const Icon(FluentIcons.scan_qr_code_24_regular, size: 18),
                  label: const Text('Escanear'),
                ),
              ],
            )
          : Row(
              children: [
                MotionFade(
                  child: hub.myId.isNotEmpty
                      ? QrView(
                          hub.qrPayload,
                          key: const ValueKey('qr'),
                          size: 156,
                          label: tx('Código QR para emparejar este equipo'),
                        )
                      : const SizedBox.shrink(key: ValueKey('no-qr')),
                ),
                const SizedBox(width: Gap.xl),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Escanéalo con el teléfono', style: t.titleSmall),
                      const SizedBox(height: Gap.xs),
                      Text(
                        'En la app del teléfono: Dispositivos › Escanear. Sirve aunque el teléfono no vea este equipo en la lista. Solo tendrás que confirmar aquí.',
                        style: t.bodyMedium?.copyWith(
                          color: s.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );

    final ipPanel = Panel(
      title: 'Dirección IP',
      icon: FluentIcons.organization_24_regular,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _addr,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: tx('Dirección IP del otro dispositivo'),
                hintText: '192.168.1.20',
                helperText: tx('Está en Ajustes del otro dispositivo.'),
              ),
              onSubmitted: hub.pairAddr,
            ),
          ),
          const SizedBox(width: Gap.s),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: FilledButton.tonal(
              onPressed: () => hub.pairAddr(_addr.text),
              child: const Text('Emparejar'),
            ),
          ),
        ],
      ),
    );

    final cablePanel = ConnectionPanel(hub);
    final adbPanel = isPhone
        ? null
        : AdbConnectionPanel(
            hub: hub,
            phone:
                hub.connectedPhone ??
                paired
                    .where((p) => hub.info[p.id]?.phone == true)
                    .firstOrNull ??
                paired.firstOrNull,
          );

    const gap = SizedBox(height: Gap.l, width: Gap.l);
    // A phone sees what each connected computer reports and can do with it (advanced controls).
    final details = isPhone
        ? [
            for (final p in paired.where(
              (p) =>
                  p.state == pb.PeerState.connected &&
                  (hub.info[p.id]?.phone != true),
            )) ...[PcDetails(hub, p), gap],
          ]
        : const <Widget>[];
    return ScreenFrame(
      title: 'Dispositivos',
      onRefresh: hub.refresh,
      children: wide
          ? [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(children: [pairedPanel, gap, nearbyPanel]),
                  ),
                  gap,
                  Expanded(
                    child: Column(
                      children: [
                        qrPanel,
                        gap,
                        cablePanel,
                        gap,
                        if (adbPanel != null) ...[adbPanel, gap],
                        ipPanel,
                      ],
                    ),
                  ),
                ],
              ),
            ]
          : [
              ...details,
              pairedPanel,
              gap,
              qrPanel,
              gap,
              nearbyPanel,
              gap,
              cablePanel,
              gap,
              if (adbPanel != null) ...[adbPanel, gap],
              ipPanel,
            ],
    );
  }
}

class _Paired extends StatelessWidget {
  const _Paired(this.p, this.hub, {super.key});
  final pb.Peer p;
  final Hub hub;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final connected = p.state == pb.PeerState.connected;
    final info = hub.info[p.id];
    final facts = [
      info?.osLabel ?? '',
      p.addr,
      es(p.detail),
    ].where((x) => x.isNotEmpty).join(' · ');

    final actions = <Widget>[
      if (connected)
        IconButton.filledTonal(
          tooltip: tr('Enviar archivos a {}', [p.name]),
          onPressed: () => hub.send(p.id),
          icon: const Icon(FluentIcons.arrow_upload_24_regular),
        ),
      if (p.state == pb.PeerState.rejected)
        TextButton(
          onPressed: () => hub.pair(p.id),
          child: const Text('Emparejar de nuevo'),
        ),
      if (connected || p.state == pb.PeerState.connecting)
        OutlinedButton.icon(
          onPressed: () => hub.disconnect(p.id),
          icon: const Icon(FluentIcons.link_dismiss_24_regular),
          label: const Text('Desconectar'),
        ),
      if (p.state == pb.PeerState.disconnected)
        FilledButton.tonalIcon(
          onPressed: () => hub.reconnect(p.id),
          icon: const Icon(FluentIcons.link_24_regular),
          label: const Text('Conectar'),
        ),
      IconButton(
        tooltip: tr('Olvidar {}', [p.name]),
        icon: Icon(FluentIcons.delete_24_regular, color: s.error),
        onPressed: () async {
          final ok = await confirm(
            context,
            tr('¿Olvidar {}?', [p.name]),
            'Se borra el emparejamiento. Para volver a usarlo tendréis que emparejaros otra vez con el código QR. '
                'Si solo quieres dejar de usarlo por ahora, pulsa Desconectar.',
            'Olvidar',
          );
          if (ok) await hub.forget(p.id);
        },
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Connected peers gain extra buttons. On narrow screens they belong
          // on a second line, not in the name/status line.
          final compact = constraints.maxWidth < 680;
          final summary = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconTile(
                info == null
                    ? FluentIcons.phone_desktop_24_regular
                    : (info.phone
                          ? FluentIcons.phone_24_regular
                          : FluentIcons.desktop_24_regular),
                tonal: connected,
              ),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      style: t.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    StatusLine(p),
                    if (facts.isNotEmpty)
                      MotionFade(
                        child: Text(
                          facts,
                          key: ValueKey(facts),
                          style: t.bodySmall?.copyWith(
                            color: s.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              // The buttons depend on the state: the group crossfades when it changes.
              if (!compact)
                MotionFade(
                  child: Row(
                    key: ValueKey(p.state),
                    mainAxisSize: MainAxisSize.min,
                    children: actions
                        .map(
                          (action) => Padding(
                            padding: const EdgeInsets.only(left: Gap.s),
                            child: action,
                          ),
                        )
                        .toList(),
                  ),
                ),
            ],
          );
          if (!compact) return summary;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              summary,
              const SizedBox(height: Gap.xs),
              Align(
                alignment: Alignment.centerRight,
                child: MotionFade(
                  child: Wrap(
                    key: ValueKey(p.state),
                    alignment: WrapAlignment.end,
                    spacing: Gap.s,
                    runSpacing: Gap.xs,
                    children: actions,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
