import 'package:flutter/material.dart' hide Icon;
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'pc_screen.dart';
import 'remote_ui.dart';
import 'media.dart';
import 'theme.dart';
import 'widgets.dart';
import 'icon.dart';

/// What a connected computer reports and what the phone may do with it: the advanced side of "controlling the
/// PC" (the everyday controls are on Home). Only facts the computer actually sent are shown; a laptop's battery
/// appears only if it has one, and the actions only if the computer's owner allowed remote control.
class PcDetails extends StatelessWidget {
  const PcDetails(this.hub, this.peer, {super.key});
  final Hub hub;
  final pb.Peer peer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final info = hub.info[peer.id];
    final online = peer.state == pb.PeerState.connected;
    final blocker = remoteBlocker(info, online);

    Widget fact(Widget icon, String title, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 28, child: Center(child: icon)),
          const SizedBox(width: Gap.m),
          Expanded(child: Text(title, style: t.bodyMedium)),
          Flexible(
            child: Text(
              value,
              style: weight(t.bodyMedium, 500),
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    return Panel(
      title: peer.name,
      icon: Symbols.computer_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          fact(
            Icon(
              online ? Symbols.link_rounded : Symbols.link_off_rounded,
              size: 20,
              color: s.onSurfaceVariant,
            ),
            'Conexión',
            online ? 'Conectado · ${hub.routeOf(peer)}' : 'Sin conexión',
          ),
          if (info != null) ...[
            fact(
              Icon(Symbols.laptop_rounded, size: 20, color: s.onSurfaceVariant),
              'Modelo',
              [
                info.manufacturer,
                info.model,
              ].where((s) => s.isNotEmpty).join(' '),
            ),
            if (info.screen != null)
              fact(
                Icon(
                  Symbols.aspect_ratio_rounded,
                  size: 20,
                  color: s.onSurfaceVariant,
                ),
                'Pantalla',
                '${info.screen!.w} × ${info.screen!.h} px',
              ),
            fact(
              Icon(
                Symbols.desktop_windows_rounded,
                size: 20,
                color: s.onSurfaceVariant,
              ),
              'Sistema',
              info.osLabel.isEmpty ? '—' : info.osLabel,
            ),
            if (info.hasBattery)
              fact(
                BatteryGlyph(info.battery, charging: info.charging, width: 22),
                'Batería',
                '${info.battery} % · ${info.charging ? 'cargando' : 'con batería'}',
              )
            else
              fact(
                Icon(
                  Symbols.power_rounded,
                  size: 20,
                  color: s.onSurfaceVariant,
                ),
                'Energía',
                'Sin batería (sobremesa)',
              ),
          ],
          if (blocker != null) ...[
            const SizedBox(height: Gap.s),
            Text(
              blocker,
              style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
            ),
          ] else ...[
            const Divider(height: Gap.xl),
            MediaPanel(hub, peer.id, computer: true, hideInactive: false),
            const Divider(height: Gap.xl),
            Wrap(
              spacing: Gap.s,
              runSpacing: Gap.s,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () {
                    hub.remote.shot(peer.id);
                    hub.messages.add('Pidiendo la captura a ${peer.name}…');
                  },
                  icon: const Icon(
                    Symbols.screenshot_monitor_rounded,
                    size: 18,
                  ),
                  label: const Text('Capturar pantalla'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () =>
                      openPcScreen(context, hub, peer.id, peer.name),
                  icon: const Icon(Symbols.cast_rounded, size: 18),
                  label: const Text('Ver pantalla'),
                ),
              ],
            ),
            if (info?.canPower ?? false) ...[
              const SizedBox(height: Gap.m),
              PowerActions(hub, peer.id, peer.name),
            ],
          ],
        ],
      ),
    );
  }
}
