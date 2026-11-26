import 'qollqe_motion.dart';

import 'package:flutter/material.dart' hide Icon, Text;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'controls.dart' show Presence;
import 'pc_screen.dart';
import 'present.dart';
import 'remote_ui.dart';
import 'theme.dart';
import 'icon.dart';
import '../l10n.dart';

Future<void> openPcControl(
  BuildContext context,
  Hub hub,
  String peer,
  String name,
) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => PcControlPage(hub, peer, name)));

class PcControlPage extends StatefulWidget {
  const PcControlPage(this.hub, this.peer, this.name, {super.key});
  final Hub hub;
  final String peer, name;

  @override
  State<PcControlPage> createState() => _PcControlPageState();
}

class _PcControlPageState extends State<PcControlPage> {
  double _gain = 2.2;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.hub,
    builder: (context, _) {
      final hub = widget.hub;
      final info = hub.info[widget.peer];
      final online = hub.peers.any(
        (p) => p.id == widget.peer && p.state == pb.PeerState.connected,
      );
      final blocker =
          remoteBlocker(info, online) ??
          (info?.canInput == false
              ? 'Este ordenador no permite controlar el mouse ni el teclado.'
              : null);
      final t = Theme.of(context).textTheme;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            Presence(
              alignment: Alignment.centerRight,
              child: blocker != null
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PointerSensitivity(
                          value: _gain,
                          onChanged: (gain) => setState(() => _gain = gain),
                        ),
                        Presence(
                          alignment: Alignment.centerRight,
                          child: info?.canScreen ?? false
                              ? IconButton(
                                  tooltip: tx('Ver pantalla'),
                                  icon: const Icon(FluentIcons.cast_24_regular),
                                  onPressed: () => openPcScreen(
                                    context,
                                    hub,
                                    widget.peer,
                                    widget.name,
                                  ),
                                )
                              : null,
                        ),
                        IconButton(
                          tooltip: 'Alero Present',
                          icon: const Icon(FluentIcons.slide_play_24_regular),
                          onPressed: () => openAleroPresent(
                            context,
                            hub,
                            widget.peer,
                            widget.name,
                          ),
                        ),
                        IconButton(
                          tooltip: tx('Volumen y reproducción'),
                          icon: const Icon(FluentIcons.speaker_2_24_regular),
                          onPressed: () => showModalBottomSheet<void>(
                            sheetAnimationStyle: sheetMotion(context),
                            context: context,
                            showDragHandle: true,
                            builder: (_) => SafeArea(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  Gap.xl,
                                  0,
                                  Gap.xl,
                                  Gap.xl,
                                ),
                                child: PcMediaControls(hub, widget.peer),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
        body: SafeArea(
          child: MotionSwitch(
            axis: Axis.vertical,
            child: KeyedSubtree(
              key: ValueKey(blocker != null),
              child: blocker != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(Gap.xxl),
                        child: Text(
                          blocker,
                          textAlign: TextAlign.center,
                          style: t.bodyLarge,
                        ),
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.all(Gap.l),
                      child: LayoutBuilder(
                        builder: (context, box) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (box.maxHeight >= 380) ...[
                              Text(
                                'Control del mouse',
                                style: weight(t.titleLarge, 600),
                              ),
                              const SizedBox(height: Gap.xs),
                              Text(
                                tr('Un panel táctil para {}.', [widget.name]),
                                style: t.bodyMedium?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: Gap.l),
                            ],
                            Expanded(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: LayoutBuilder(
                                      builder: (_, area) => Touchpad(
                                        hub,
                                        widget.peer,
                                        height: area.maxHeight,
                                        gain: _gain,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: Gap.m),
                            MouseActionBar(hub, widget.peer),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ),
      );
    },
  );
}
