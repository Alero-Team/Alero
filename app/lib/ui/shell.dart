import 'dart:async';
import 'dart:io';

import 'package:animations/animations.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:window_manager/window_manager.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'brand.dart';
import 'devices.dart';
import 'explorer.dart';
import 'expressive.dart';
import 'home.dart';
import 'nav.dart';
import 'pc_screen.dart';
import 'settings.dart';
import 'theme.dart';
import 'transfers.dart';
import 'widgets.dart';

/// Four top-level places. Clipboard, notifications, media and screen are things you do with a device, so they
/// live on Home as panels and actions, not as destinations (fewer places, each with one purpose).
enum Section { home, files, explorer, devices, settings }

class _Dest {
  const _Dest(this.section, this.label, this.icon);
  final Section section;
  final String label;
  final IconData icon;
}

/// The phone's own file browser is a computer feature: it reads another device's files, so it has no place on a phone.
final _dests = [
  const _Dest(Section.home, 'Inicio', Symbols.home_rounded),
  const _Dest(Section.files, 'Archivos', Symbols.folder_rounded),
  if (!Platform.isAndroid)
    const _Dest(Section.explorer, 'Explorador', Symbols.perm_media_rounded),
  const _Dest(Section.devices, 'Dispositivos', Symbols.devices_rounded),
  const _Dest(Section.settings, 'Ajustes', Symbols.settings_rounded),
];

/// App frame: side navigation on wide windows, floating glass bar on phones. Owns the questions the engine
/// asks the user (pairing code, incoming file), the share sheet and the toast messages. Reads Hub, never decides.
class Shell extends StatefulWidget {
  const Shell(
    this.hub, {
    super.key,
    this.onResume,
    this.initialSection = Section.home,
  });
  final Section initialSection;
  final Hub hub;
  final VoidCallback? onResume;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell>
    with WidgetsBindingObserver, WindowListener {
  Hub get hub => widget.hub;
  // ALERO_SECTION=explorer (etc.) opens that screen first: handy for screenshots and manual checks.
  late Section _section =
      Section.values
          .where((s) => s.name == Platform.environment['ALERO_SECTION'])
          .firstOrNull ??
      widget.initialSection;
  late final StreamSubscription<String> _msgs;
  bool _shareOpen = false, _shotOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) windowManager.addListener(this);
    _msgs = hub.messages.stream.listen((m) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
      }
    });
    hub.addListener(_questions);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows) windowManager.removeListener(this);
    _msgs.cancel();
    hub.removeListener(_questions);
    super.dispose();
  }

  /// Back from system settings or another app: permissions, shares and the system color may have changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    hub.remote.mediaForeground(s == AppLifecycleState.resumed);
    if (s == AppLifecycleState.resumed) {
      hub.checkPermissions();
      hub.takeShare();
      widget.onResume?.call();
    }
  }

  @override
  void onWindowMinimize() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    hub.remote.mediaForeground(false);
  }

  @override
  void onWindowRestore() {
    hub.remote.mediaForeground(true);
  }

  void _go(Section s) => setState(() => _section = s);

  /// Pairing code, incoming-file and share questions appear once each, and close by themselves when the
  /// engine no longer waits for an answer (the other side answered, it timed out, or it was answered by code).
  DialogRoute<bool>? _pairRoute, _offerRoute;

  void _questions() {
    final p = hub.pairPrompt;
    if (p != null && _pairRoute == null) {
      final route = _pairRoute = DialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _PairDialog(p),
      );
      Navigator.of(context).push(route).then((ok) {
        _pairRoute = null;
        if (hub.pairPrompt != null) hub.answerPair(ok ?? false);
      });
    } else if (p == null && _pairRoute != null && _pairRoute!.isActive) {
      Navigator.of(context).removeRoute(_pairRoute!);
    }
    final o = hub.offer;
    if (o != null && _offerRoute == null) {
      final route = _offerRoute = DialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _OfferDialog(o),
      );
      Navigator.of(context).push(route).then((ok) {
        _offerRoute = null;
        if (hub.offer != null) hub.answerOffer(ok ?? false);
      });
    } else if (o == null && _offerRoute != null && _offerRoute!.isActive) {
      Navigator.of(context).removeRoute(_offerRoute!);
    }
    if (hub.shot != null && !_shotOpen) {
      _shotOpen = true;
      showShot(context, hub).whenComplete(() => _shotOpen = false);
    }
    if (hub.share != null && !_shareOpen) {
      _shareOpen = true;
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (_) => _ShareSheet(hub),
      ).whenComplete(() {
        _shareOpen = false;
        if (hub.share != null) hub.dropShare();
      });
    }
  }

  Widget _page() => switch (_section) {
    Section.home => HomeScreen(hub, go: _go),
    Section.files => TransfersScreen(hub),
    Section.explorer => ExplorerScreen(hub),
    Section.devices => DevicesScreen(hub),
    Section.settings => SettingsScreen(hub),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hub,
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        // Fade through: the Material transition between top-level destinations. Pages keep their own
        // layout (top-aligned), so nothing jumps while the old page fades out.
        final page = PageTransitionSwitcher(
          duration: motion(context, const Duration(milliseconds: 300)),
          layoutBuilder: (entries) =>
              Stack(alignment: Alignment.topCenter, children: entries),
          transitionBuilder: (child, a, b) => FadeThroughTransition(
            animation: a,
            secondaryAnimation: b,
            fillColor: Colors.transparent,
            child: child,
          ),
          child: KeyedSubtree(key: ValueKey(_section), child: _page()),
        );
        return box.maxWidth >= wideLayout ? _wide(page) : _narrow(page);
      },
    ),
  );

  int _badge(Section s) => s == Section.files ? hub.active.length : 0;

  Widget _wide(Widget page) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final online = hub.peers
        .where((p) => p.trusted && p.state == pb.PeerState.connected)
        .toList();
    return Scaffold(
      backgroundColor: s.surfaceContainer,
      body: Row(
        children: [
          SizedBox(
            width: 240,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Gap.m,
                        Gap.xl,
                        Gap.m,
                        Gap.l,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const AleroLogo(size: 26),
                          const SizedBox(height: Gap.l),
                          Text(
                            hub.name,
                            style: t.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'Este equipo',
                            style: t.bodySmall?.copyWith(
                              color: s.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final d in _dests)
                      _NavItem(
                        icon: d.icon,
                        label: d.label,
                        selected: d.section == _section,
                        badge: _badge(d.section),
                        onTap: () => _go(d.section),
                      ),
                    const Spacer(),
                    _PhoneChip(online, hub, onTap: () => _go(Section.devices)),
                    const SizedBox(height: Gap.m),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, Gap.s, Gap.s, Gap.s),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.card),
                child: ColoredBox(
                  color: s.surface,
                  child: _Drop(hub, child: page),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _narrow(Widget page) => Scaffold(
    extendBody: true,
    body: page,
    bottomNavigationBar: SafeArea(
      minimum: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
      child: AleroNavBar(
        items: [
          for (final d in _dests)
            NavData(d.icon, d.label, badge: _badge(d.section)),
        ],
        selected: _dests.indexWhere((d) => d.section == _section),
        onSelect: (i) => _go(_dests[i].section),
      ),
    ),
  );
}

/// Sidebar destination: a full-width pill with icon and label on one line, so they line up exactly.
/// The pill and the icon fill change with spring motion.
class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge = 0,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final sel = widget.selected;
    final fg = sel ? s.onSurface : s.onSurfaceVariant;
    final bg = sel
        ? s.surfaceContainerHighest
        : (_hover ? s.onSurface.withValues(alpha: 0.06) : Colors.transparent);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        button: true,
        selected: sel,
        label: widget.label,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: motion(context, Spring.spatial.settle),
              curve: Spring.spatial,
              height: 48,
              padding: EdgeInsets.symmetric(horizontal: sel ? Gap.l : Gap.m),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: sel ? 1 : 0),
                      duration: motion(
                        context,
                        const Duration(milliseconds: 250),
                      ),
                      builder: (_, f, _) =>
                          Icon(widget.icon, size: 22, color: fg, fill: f),
                    ),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: Text(
                        widget.label,
                        style: (sel ? t.labelLarge : weight(t.labelLarge, 500))
                            ?.copyWith(color: fg),
                      ),
                    ),
                    if (widget.badge > 0) Badge(label: Text('${widget.badge}')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Mi teléfono" from the concept: who is connected; one tap to Devices.
class _PhoneChip extends StatelessWidget {
  const _PhoneChip(this.online, this.hub, {required this.onTap});
  final List<pb.Peer> online;
  final Hub hub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final look = online.isEmpty ? null : hub.look[online.first.id];
    return Material(
      color: s.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(Radii.tile),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.tile),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.m),
          child: Row(
            children: [
              // The exact back cover when Alero found one; the plain phone icon otherwise.
              SizedBox(
                width: 28,
                height: 40,
                child: Center(
                  child: online.isEmpty
                      ? const Icon(Symbols.mobile_off_rounded, size: 20)
                      : PhoneCover(look, online.first.name),
                ),
              ),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      online.isEmpty
                          ? 'Sin conexión'
                          : look?.name ?? online.first.name,
                      style: t.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      online.isEmpty
                          ? 'Ningún dispositivo'
                          : (online.length == 1
                                ? 'Conectado'
                                : '${online.length} conectados'),
                      style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const Icon(Symbols.chevron_right_rounded, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// Android share menu: pick the paired device that gets the files or text.
class _ShareSheet extends StatelessWidget {
  const _ShareSheet(this.hub);
  final Hub hub;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = hub.share;
    final online = hub.peers
        .where((p) => p.trusted && p.state == pb.PeerState.connected)
        .toList();
    final what = s == null
        ? ''
        : s.files.isNotEmpty
        ? (s.files.length == 1
              ? s.files.first.name ?? 'Un archivo'
              : '${s.files.length} archivos')
        : 'Texto: «${s.text.length > 60 ? '${s.text.substring(0, 60)}…' : s.text}»';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: SolidSurface(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Enviar a…', style: t.titleLarge),
              const SizedBox(height: Gap.xs),
              Text(
                what,
                style: t.bodyMedium?.copyWith(color: context.pal.muted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Gap.l),
              if (online.isEmpty)
                Text(
                  'Ningún dispositivo conectado. Abre la app en el ordenador.',
                  style: t.bodyMedium,
                )
              else
                for (final p in online)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.s),
                    child: FilledButton.icon(
                      onPressed: () {
                        hub.sendShare(p.id);
                        Navigator.pop(context);
                      },
                      icon: const Icon(Symbols.computer_rounded),
                      label: Text(p.name),
                    ),
                  ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Same 6-digit code on both screens; the user confirms they match (SAS).
class _PairDialog extends StatelessWidget {
  const _PairDialog(this.p);
  final pb.Event_PairRequest p;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final code = p.code.length == 6
        ? '${p.code.substring(0, 3)} ${p.code.substring(3)}'
        : p.code;
    return AlertDialog(
      icon: const Icon(Symbols.link_rounded),
      title: Text('Emparejar con ${p.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Comprueba que ${p.name} muestra este mismo código.',
            style: t.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Gap.l),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: Gap.l),
            decoration: BoxDecoration(
              color: s.secondaryContainer,
              borderRadius: BorderRadius.circular(Radii.tile),
            ),
            child: Semantics(
              label: 'Código ${p.code.split('').join(' ')}',
              child: ExcludeSemantics(
                child: Text(
                  code,
                  textAlign: TextAlign.center,
                  style: t.headlineMedium?.copyWith(
                    fontFeatures: tabular,
                    letterSpacing: 4,
                    color: s.onSecondaryContainer,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('No coinciden'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Coinciden'),
        ),
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
      icon: const Icon(Symbols.download_rounded),
      title: const Text('Archivo entrante'),
      content: Row(
        children: [
          FileTile(o.name),
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
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Rechazar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Aceptar'),
        ),
      ],
    );
  }
}

/// Asks before destructive actions. Returns true only on explicit confirmation.
Future<bool> confirm(
  BuildContext context,
  String title,
  String body,
  String yes,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: Text(yes),
          ),
        ],
      ),
    ) ??
    false;

/// Page scaffold shared by the screens: title, max width, padding that clears the floating bar.
class ScreenFrame extends StatelessWidget {
  const ScreenFrame({
    super.key,
    required this.title,
    required this.children,
    this.onRefresh,
    this.trailing,
  });
  final String title;
  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideLayout;
    final list = ListView(
      padding: EdgeInsets.fromLTRB(
        wide ? Gap.xxl : Gap.l,
        Gap.xl,
        wide ? Gap.xxl : Gap.l,
        wide ? Gap.xxl : 112,
      ),
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: wide
                              ? Theme.of(context).textTheme.headlineMedium
                              : Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
                const SizedBox(height: Gap.l),
                for (final (i, c) in children.indexed)
                  Reveal(index: i, child: c),
              ],
            ),
          ),
        ),
      ],
    );
    return SafeArea(
      bottom: false,
      child: onRefresh == null || !Platform.isAndroid
          ? list
          : RefreshIndicator(onRefresh: onRefresh!, child: list),
    );
  }
}

/// Desktop: drop files anywhere on the window to send them to the connected device.
class _Drop extends StatefulWidget {
  const _Drop(this.hub, {required this.child});
  final Hub hub;
  final Widget child;

  @override
  State<_Drop> createState() => _DropState();
}

class _DropState extends State<_Drop> {
  bool _over = false;

  List<pb.Peer> get _online => widget.hub.peers
      .where((p) => p.trusted && p.state == pb.PeerState.connected)
      .toList();

  Future<void> _done(DropDoneDetails d) async {
    setState(() => _over = false);
    final files = [
      for (final f in d.files)
        if (FileSystemEntity.isFileSync(f.path)) f.path,
    ];
    if (files.length < d.files.length) {
      widget.hub.messages.add(
        'Las carpetas aún no se pueden enviar; se envían solo los archivos.',
      );
    }
    if (files.isEmpty) return;
    final online = _online;
    if (online.isEmpty) {
      return widget.hub.messages.add('Ningún dispositivo conectado.');
    }
    var target = online.first;
    if (online.length > 1) {
      final pick = await showDialog<pb.Peer>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Enviar a…'),
          children: [
            for (final p in online)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, p),
                child: Text(p.name),
              ),
          ],
        ),
      );
      if (pick == null) return;
      target = pick;
    }
    await widget.hub.sendPaths(target.id, files);
  }

  @override
  Widget build(BuildContext context) {
    final online = _online;
    final s = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: _done,
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _over ? 1 : 0,
                duration: motion(context, const Duration(milliseconds: 180)),
                child: AnimatedScale(
                  scale: _over ? 1 : 0.96,
                  duration: motion(context, Spring.spatial.settle),
                  curve: Spring.spatial,
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: SolidSurface(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 88,
                              height: 88,
                              decoration: ShapeDecoration(
                                color: s.primaryContainer,
                                shape: const CookieBorder(),
                              ),
                              child: Icon(
                                Symbols.upload_rounded,
                                size: 36,
                                color: s.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(height: Gap.l),
                            Text(
                              online.isEmpty
                                  ? 'Conecta un dispositivo para enviar'
                                  : 'Suelta para enviar a ${online.length == 1 ? online.first.name : '…'}',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
