import 'package:flutter/material.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

/// Answers three questions: which device is connected, what can I do, what is moving.
class HomeScreen extends StatelessWidget {
  const HomeScreen(this.hub, {super.key, required this.go});
  final Hub hub;
  final void Function(int tab) go;

  @override
  Widget build(BuildContext context) {
    final trusted = hub.peers.where((p) => p.trusted).toList();
    final main = trusted.where((p) => p.state == pb.PeerState.connected).firstOrNull ?? trusted.firstOrNull;
    final others = trusted.where((p) => p != main).toList();
    final wide = MediaQuery.sizeOf(context).width >= 1100;

    final left = <Widget>[
      SectionHeader(trusted.length > 1 ? 'Dispositivo principal' : 'Tu dispositivo', top: false),
      if (main == null)
        EmptyState(
          icon: Icons.devices_outlined,
          title: 'Aún no hay dispositivos',
          body: 'Abre la app en el otro dispositivo, conectado a la misma red Wi-Fi, y emparéjalos.',
          action: 'Emparejar un dispositivo',
          onAction: () => go(2),
        )
      else
        _DeviceHero(main, hub, go: go),
      if (others.isNotEmpty) ...[
        const SectionHeader('Otros dispositivos'),
        Card(
          child: Column(
            children: [
              for (final (i, p) in others.indexed) ...[
                if (i > 0) const Divider(indent: Gap.l, endIndent: Gap.l),
                _PeerRow(p, hub),
              ],
            ],
          ),
        ),
      ],
      if (hub.active.isNotEmpty) ...[
        const SectionHeader('En curso'),
        for (final x in hub.active)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.s),
            child: TransferCard(x, hub),
          ),
      ],
    ];

    final recent = hub.history.reversed.take(4).toList();
    final right = <Widget>[
      SectionHeader('Recientes', top: !wide, action: recent.isEmpty ? null : 'Ver todo', onAction: () => go(1)),
      Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
          child: recent.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.m),
                  child: Text('Lo que envíes y recibas aparecerá aquí.', style: TextStyle(color: context.pal.muted)),
                )
              : Column(children: [for (final h in recent) HistoryTile(h, hub)]),
        ),
      ),
    ];

    return ScreenFrame(
      title: 'Inicio',
      onRefresh: hub.refresh,
      children: [
        if (hub.startError.isNotEmpty) ...[const SizedBox(height: Gap.l), ErrorBanner(hub.startError)],
        const SizedBox(height: Gap.l),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left),
              ),
              const SizedBox(width: Gap.xl),
              Expanded(
                flex: 2,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right),
              ),
            ],
          )
        else ...[
          ...left,
          ...right,
        ],
      ],
    );
  }
}

class _DeviceHero extends StatelessWidget {
  const _DeviceHero(this.p, this.hub, {required this.go});
  final pb.Peer p;
  final Hub hub;
  final void Function(int tab) go;

  @override
  Widget build(BuildContext context) {
    final c = context.pal;
    final t = Theme.of(context).textTheme;
    final connected = p.state == pb.PeerState.connected;
    final facts = [p.addr, p.detail].where((s) => s.isNotEmpty).join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const IconTile(Icons.devices_outlined, size: 56),
                const SizedBox(width: Gap.l),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name, style: t.headlineSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: Gap.xs),
                      StatusLine(p),
                      if (facts.isNotEmpty) ...[
                        const SizedBox(height: Gap.xs),
                        Text(facts, style: t.bodySmall?.copyWith(color: c.muted)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (connected) ...[
              const SizedBox(height: Gap.l),
              Row(
                children: [
                  Icon(Icons.lock_outline, size: 16, color: c.muted),
                  const SizedBox(width: Gap.xs),
                  Text('Conexión cifrada', style: t.bodySmall?.copyWith(color: c.muted)),
                ],
              ),
            ] else ...[
              const SizedBox(height: Gap.l),
              Text(
                p.state == pb.PeerState.rejected
                    ? 'Ese dispositivo te quitó de su lista. Vuelve a emparejarlos desde Dispositivos.'
                    : 'Abre la app en ${p.name} y comprueba que ambos están en la misma red Wi-Fi.',
                style: t.bodyMedium?.copyWith(color: c.muted),
              ),
            ],
            const SizedBox(height: Gap.xl),
            Wrap(
              spacing: Gap.s,
              runSpacing: Gap.s,
              children: [
                FilledButton.icon(
                  onPressed: connected ? () => hub.send(p.id) : null,
                  icon: const Icon(Icons.upload_outlined),
                  label: const Text('Enviar archivos'),
                ),
                OutlinedButton.icon(
                  onPressed: () => go(2),
                  icon: const Icon(Icons.devices_outlined),
                  label: const Text('Dispositivos'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PeerRow extends StatelessWidget {
  const _PeerRow(this.p, this.hub);
  final pb.Peer p;
  final Hub hub;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.m),
    child: Row(
      children: [
        const IconTile(Icons.devices_outlined),
        const SizedBox(width: Gap.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.name, style: Theme.of(context).textTheme.titleSmall),
              StatusLine(p),
            ],
          ),
        ),
        if (p.state == pb.PeerState.connected)
          TextButton.icon(
            onPressed: () => hub.send(p.id),
            icon: const Icon(Icons.upload_outlined),
            label: const Text('Enviar'),
          ),
      ],
    ),
  );
}
