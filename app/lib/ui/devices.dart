import 'package:flutter/material.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
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
    final c = context.pal;
    final t = Theme.of(context).textTheme;
    final paired = hub.peers.where((p) => p.trusted).toList();
    final nearby = hub.peers.where((p) => !p.trusted).toList();
    return ScreenFrame(
      title: 'Dispositivos',
      onRefresh: hub.refresh,
      children: [
        const SectionHeader('Emparejados'),
        if (paired.isEmpty)
          Text('Todavía no has emparejado ningún dispositivo.', style: TextStyle(color: c.muted))
        else
          for (final p in paired)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.s),
              child: _Paired(p, hub),
            ),
        const SectionHeader('En esta red'),
        if (nearby.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.l),
              child: Row(
                children: [
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: Text(
                      paired.isEmpty
                          ? 'Buscando… Abre la app en el otro dispositivo, en la misma red Wi-Fi.'
                          : 'Buscando otros dispositivos… Para añadir uno, abre la app en él.',
                      style: TextStyle(color: c.muted),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (final (i, p) in nearby.indexed) ...[
                  if (i > 0) const Divider(indent: Gap.l, endIndent: Gap.l),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.m, Gap.m),
                    child: Row(
                      children: [
                        const IconTile(Icons.devices_outlined),
                        const SizedBox(width: Gap.m),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.name, style: t.titleSmall),
                              Text(p.addr, style: t.bodySmall?.copyWith(color: c.muted)),
                            ],
                          ),
                        ),
                        FilledButton(onPressed: () => hub.pair(p.id), child: const Text('Emparejar')),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        const SectionHeader('Emparejar por dirección IP'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _addr,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Dirección IP',
                    hintText: '192.168.1.20',
                    helperText: 'Si no aparece arriba: la dirección está en Ajustes del otro dispositivo.',
                    helperMaxLines: 2,
                  ),
                  onSubmitted: hub.pairAddr,
                ),
                const SizedBox(height: Gap.m),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(onPressed: () => hub.pairAddr(_addr.text), child: const Text('Emparejar')),
                ),
              ],
            ),
          ),
        ),
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
    final c = context.pal;
    final t = Theme.of(context).textTheme;
    final connected = p.state == pb.PeerState.connected;
    final facts = [p.addr, p.detail].where((s) => s.isNotEmpty).join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.s, Gap.l),
        child: Row(
          children: [
            const IconTile(Icons.devices_outlined, size: 48),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name, style: t.titleMedium),
                  StatusLine(p),
                  if (facts.isNotEmpty) Text(facts, style: t.bodySmall?.copyWith(color: c.muted)),
                ],
              ),
            ),
            if (connected) FilledButton(onPressed: () => hub.send(p.id), child: const Text('Enviar')),
            if (p.state == pb.PeerState.rejected)
              OutlinedButton(onPressed: () => hub.pair(p.id), child: const Text('Emparejar de nuevo')),
            IconButton(
              tooltip: 'Olvidar ${p.name}',
              icon: Icon(Icons.delete_outline, color: c.danger),
              onPressed: () async {
                final ok = await confirm(
                  context,
                  '¿Olvidar ${p.name}?',
                  'Dejará de conectarse. Para volver a usarlo tendréis que emparejaros otra vez.',
                  'Olvidar',
                );
                if (ok) await hub.forget(p.id);
              },
            ),
          ],
        ),
      ),
    );
  }
}
