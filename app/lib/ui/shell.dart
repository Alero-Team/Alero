import 'dart:async';

import 'package:flutter/material.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'devices.dart';
import 'home.dart';
import 'settings.dart';
import 'theme.dart';
import 'transfers.dart';
import 'widgets.dart';

/// App frame: side navigation on wide windows, floating bottom bar on phones. Owns the questions the engine
/// asks the user (pairing code, incoming file) and the toast messages. Reads Hub, never decides.
class Shell extends StatefulWidget {
  const Shell(this.hub, {super.key});
  final Hub hub;

  @override
  State<Shell> createState() => _ShellState();
}

class _Dest {
  const _Dest(this.label, this.icon, this.selected);
  final String label;
  final IconData icon, selected;
}

const _dests = [
  _Dest('Inicio', Icons.home_outlined, Icons.home),
  _Dest('Transferencias', Icons.swap_vert, Icons.swap_vert),
  _Dest('Dispositivos', Icons.devices_outlined, Icons.devices),
  _Dest('Ajustes', Icons.settings_outlined, Icons.settings),
];

class _ShellState extends State<Shell> {
  Hub get hub => widget.hub;
  int _tab = 0;
  late final StreamSubscription<String> _msgs;
  String? _shownPair, _shownOffer;

  @override
  void initState() {
    super.initState();
    _msgs = hub.messages.stream.listen((m) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    });
    hub.addListener(_questions);
  }

  @override
  void dispose() {
    _msgs.cancel();
    hub.removeListener(_questions);
    super.dispose();
  }

  void _go(int i) => setState(() => _tab = i);

  /// Pairing code and incoming-file questions appear once each.
  void _questions() {
    final p = hub.pairPrompt;
    if (p != null && _shownPair != p.peerId) {
      _shownPair = p.peerId;
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _PairDialog(p),
      ).then((ok) => hub.answerPair(ok ?? false)).whenComplete(() => _shownPair = null);
    }
    final o = hub.offer;
    if (o != null && _shownOffer != o.id) {
      _shownOffer = o.id;
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _OfferDialog(o),
      ).then((ok) => hub.answerOffer(ok ?? false));
    }
  }

  Widget _page() => switch (_tab) {
    0 => HomeScreen(hub, go: _go),
    1 => TransfersScreen(hub),
    2 => DevicesScreen(hub),
    _ => SettingsScreen(hub),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hub,
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= wideLayout;
        final still = MediaQuery.of(context).disableAnimations;
        final page = AnimatedSwitcher(
          duration: still ? Duration.zero : const Duration(milliseconds: 180),
          child: KeyedSubtree(key: ValueKey(_tab), child: _page()),
        );
        return wide ? _wide(page) : _narrow(page);
      },
    ),
  );

  Widget _badge(int i, Widget icon) =>
      i == 1 && hub.active.isNotEmpty ? Badge(label: Text('${hub.active.length}'), child: icon) : icon;

  Widget _wide(Widget page) {
    final c = context.pal;
    final t = Theme.of(context).textTheme;
    final online = hub.peers.where((p) => p.trusted && p.state == pb.PeerState.connected).length;
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 248,
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(right: BorderSide(color: c.line)),
            ),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xl, Gap.l, Gap.l),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(hub.name, style: t.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text('Este equipo', style: t.bodySmall?.copyWith(color: c.muted)),
                      ],
                    ),
                  ),
                  Expanded(
                    child: NavigationRail(
                      extended: true,
                      minExtendedWidth: 248,
                      selectedIndex: _tab,
                      onDestinationSelected: _go,
                      destinations: [
                        for (final (i, d) in _dests.indexed)
                          NavigationRailDestination(
                            icon: _badge(i, Icon(d.icon)),
                            selectedIcon: _badge(i, Icon(d.selected)),
                            label: Text(d.label),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: online > 0 ? c.signal : c.muted, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: Gap.s),
                        Expanded(
                          child: Text(
                            online == 0 ? 'Ningún dispositivo conectado' : '$online conectado${online == 1 ? '' : 's'}',
                            style: t.bodySmall?.copyWith(color: c.muted),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: page),
        ],
      ),
    );
  }

  Widget _narrow(Widget page) => Scaffold(
    extendBody: true,
    body: page,
    bottomNavigationBar: SafeArea(
      minimum: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.card + 8),
          border: Border.all(color: context.pal.line),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 24, offset: const Offset(0, 8)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.card + 8),
          child: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _go,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: [
              for (final (i, d) in _dests.indexed)
                NavigationDestination(
                  icon: _badge(i, Icon(d.icon)),
                  selectedIcon: _badge(i, Icon(d.selected)),
                  label: d.label == 'Transferencias' ? 'Envíos' : d.label,
                  tooltip: d.label,
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Same 6-digit code on both screens; the user confirms they match (SAS).
class _PairDialog extends StatelessWidget {
  const _PairDialog(this.p);
  final pb.Event_PairRequest p;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final code = p.code.length == 6 ? '${p.code.substring(0, 3)} ${p.code.substring(3)}' : p.code;
    return AlertDialog(
      title: Text('Emparejar con ${p.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Comprueba que ${p.name} muestra este mismo código.', style: t.bodyMedium),
          const SizedBox(height: Gap.l),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: Gap.l),
            decoration: BoxDecoration(color: context.pal.alt, borderRadius: BorderRadius.circular(Radii.tile)),
            child: Semantics(
              label: 'Código ${p.code.split('').join(' ')}',
              child: ExcludeSemantics(
                child: Text(
                  code,
                  textAlign: TextAlign.center,
                  style: t.headlineMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    letterSpacing: 4,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('No coinciden')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Coinciden')),
      ],
    );
  }
}

class _OfferDialog extends StatelessWidget {
  const _OfferDialog(this.o);
  final pb.Event_TransferOffer o;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Archivo entrante'),
      content: Row(
        children: [
          IconTile(fileIcon(o.name)),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(o.name, style: t.titleSmall),
                Text(
                  '${size(o.size.toInt())} · de ${o.peerName}',
                  style: t.bodySmall?.copyWith(color: context.pal.muted),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Rechazar')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Aceptar')),
      ],
    );
  }
}

/// Asks before destructive actions. Returns true only on explicit confirmation.
Future<bool> confirm(BuildContext context, String title, String body, String yes) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.pal.danger, foregroundColor: c.pal.surface),
            onPressed: () => Navigator.pop(c, true),
            child: Text(yes),
          ),
        ],
      ),
    ) ??
    false;

/// Page scaffold shared by the four screens: title, max width, padding that clears the floating bar.
class ScreenFrame extends StatelessWidget {
  const ScreenFrame({super.key, required this.title, required this.children, this.onRefresh});
  final String title;
  final List<Widget> children;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideLayout;
    final list = ListView(
      padding: EdgeInsets.fromLTRB(wide ? Gap.xxl : Gap.l, Gap.xl, wide ? Gap.xxl : Gap.l, wide ? Gap.xxl : 120),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.headlineMedium)),
                ...children,
              ],
            ),
          ),
        ),
      ],
    );
    return SafeArea(
      bottom: false,
      child: onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list),
    );
  }
}
