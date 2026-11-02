import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../native.dart';
import '../remote.dart';
import '../src/rust/api/engine.dart' as pb;
import 'connect_help.dart';
import 'pc_details.dart';
import 'qr.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

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
      icon: Symbols.verified_user_rounded,
      child: paired.isEmpty
          ? const EmptyState(
              card: false,
              icon: Symbols.devices_rounded,
              title: 'Ninguno todavía',
              body: 'Empareja tu teléfono con el código QR o desde la lista de la red.',
            )
          : Column(children: [for (final p in paired) _Paired(p, hub)]),
    );

    final nearbyPanel = Panel(
      title: 'En esta red',
      icon: Symbols.wifi_rounded,
      child: nearby.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.s),
              child: Text(
                'No hay nada a la vista. Abre Alero en el otro dispositivo, en la misma red Wi-Fi, o conéctalos con un cable.',
                style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
              ),
            )
          : Column(
              children: [
                for (final p in nearby)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.s),
                    child: Row(
                      children: [
                        const IconTile(Symbols.devices_rounded),
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
    );

    final qrPanel = Panel(
      title: 'Código QR',
      icon: Symbols.qr_code_rounded,
      child: Platform.isAndroid
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
                  icon: const Icon(Symbols.qr_code_scanner_rounded, size: 18),
                  label: const Text('Escanear'),
                ),
              ],
            )
          : Row(
              children: [
                if (hub.myId.isNotEmpty)
                  QrView(
                    hub.qrPayload,
                    size: 156,
                    label: 'Código QR para emparejar este equipo',
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
      icon: Symbols.lan_rounded,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _addr,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Dirección IP del otro dispositivo',
                hintText: '192.168.1.20',
                helperText: 'Está en Ajustes del otro dispositivo.',
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

    const gap = SizedBox(height: Gap.l, width: Gap.l);
    // A phone sees what each connected computer reports and can do with it (advanced controls).
    final details = Platform.isAndroid
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
                      children: [qrPanel, gap, cablePanel, gap, ipPanel],
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
              ipPanel,
            ],
    );
  }
}

class _Paired extends StatelessWidget {
  const _Paired(this.p, this.hub);
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: Row(
        children: [
          IconTile(
            info == null
                ? Symbols.devices_rounded
                : (info.phone
                      ? Symbols.smartphone_rounded
                      : Symbols.computer_rounded),
            tonal: connected,
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name, style: t.titleSmall),
                StatusLine(p),
                if (facts.isNotEmpty)
                  Text(
                    facts,
                    style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (connected)
            IconButton.filledTonal(
              tooltip: 'Enviar archivos a ${p.name}',
              onPressed: () => hub.send(p.id),
              icon: const Icon(Symbols.upload_rounded),
            ),
          if (p.state == pb.PeerState.rejected)
            TextButton(
              onPressed: () => hub.pair(p.id),
              child: const Text('Emparejar de nuevo'),
            ),
          if (connected || p.state == pb.PeerState.connecting)
            Padding(
              padding: const EdgeInsets.only(left: Gap.s),
              child: OutlinedButton.icon(
                onPressed: () => hub.disconnect(p.id),
                icon: const Icon(Symbols.link_off_rounded),
                label: const Text('Desconectar'),
              ),
            ),
          if (p.state == pb.PeerState.disconnected)
            Padding(
              padding: const EdgeInsets.only(left: Gap.s),
              child: FilledButton.tonalIcon(
                onPressed: () => hub.reconnect(p.id),
                icon: const Icon(Symbols.link_rounded),
                label: const Text('Conectar'),
              ),
            ),
          IconButton(
            tooltip: 'Olvidar ${p.name}',
            icon: Icon(Symbols.delete_rounded, color: s.error),
            onPressed: () async {
              final ok = await confirm(
                context,
                '¿Olvidar ${p.name}?',
                'Se borra el emparejamiento. Para volver a usarlo tendréis que emparejaros otra vez con el código QR. '
                    'Si solo quieres dejar de usarlo por ahora, pulsa Desconectar.',
                'Olvidar',
              );
              if (ok) await hub.forget(p.id);
            },
          ),
        ],
      ),
    );
  }
}
