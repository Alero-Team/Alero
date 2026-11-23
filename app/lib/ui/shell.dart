import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:animations/animations.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart' hide Icon, Text;
import 'package:flutter/physics.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../hub.dart';
import '../native.dart';
import '../src/rust/api/engine.dart' as pb;
import 'brand.dart';
import 'clipboard.dart';
import 'controls.dart' show runIslandControl;
import 'devices.dart';
import 'explorer.dart';
import 'expressive.dart';
import 'home.dart';
import 'notifications.dart';
import 'alero_motion.dart';
import 'call_bar.dart';
import 'calls_screen.dart';
import 'vault.dart';
import 'messages.dart';
import 'nav.dart';
import 'pc_control.dart';
import 'pc_screen.dart';
import 'send_preview.dart';
import 'settings.dart';
import 'theme.dart';
import 'widgets.dart';
import 'icon.dart';
import '../l10n.dart';

/// Four top-level places. Clipboard, notifications, media and screen are things you do with a device, so they
/// live on Home as panels and actions, not as destinations (fewer places, each with one purpose).
enum Section {
  home,
  messages,
  calls,
  notifications,
  photos,
  explorer,
  vault,
  devices,
  settings,
}

class _Dest {
  const _Dest(this.section, this.label, this.icon, {this.group});
  final Section section;
  final String label;
  final IconData icon;

  /// A small heading shown above the first destination of a group in the side menu.
  final String? group;
}

/// The phone's own file browser is a computer feature: it reads another device's files, so it has no place on a phone.
List<_Dest> get _dests => [
  const _Dest(Section.home, 'Inicio', FluentIcons.home_24_regular),
  if (!isPhone) ...const [
    _Dest(
      Section.messages,
      'Mensajes',
      FluentIcons.chat_24_regular,
      group: 'COMUNICACIÓN',
    ),
    _Dest(Section.calls, 'Llamadas', FluentIcons.call_24_regular),
    _Dest(
      Section.notifications,
      'Notificaciones',
      FluentIcons.alert_24_regular,
    ),
    _Dest(
      Section.photos,
      'Fotos',
      FluentIcons.image_multiple_24_regular,
      group: 'CONTENIDO',
    ),
    _Dest(Section.explorer, 'Explorador', FluentIcons.folder_24_regular),
  ],
  if (!isPhone) const _Dest(Section.vault, 'Alero Vault', FluentIcons.lock_closed_24_regular),
  const _Dest(
    Section.devices,
    'Dispositivos',
    FluentIcons.phone_desktop_24_regular,
    group: 'SISTEMA',
  ),
  const _Dest(Section.settings, 'Ajustes', FluentIcons.options_24_regular),
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
    with WidgetsBindingObserver, WindowListener, SingleTickerProviderStateMixin {
  bool _sidebarCollapsed = false;

  /// The side menu's width, moved by a soft spring: it overshoots about 4 px and settles in ~620 ms.
  late final _menu = AnimationController.unbounded(
    vsync: this,
    value: _menuOpen,
  );
  static const _menuSpring = SpringDescription(
    mass: 1,
    stiffness: 180,
    damping: 2 * .75 * 13.416, // ratio 0.75: 2·ratio·√stiffness
  );

  void _toggleMenu() {
    Entrance.hush();
    setState(() => _sidebarCollapsed = !_sidebarCollapsed);
    final to = _sidebarCollapsed ? _menuShut : _menuOpen;
    if (MediaQuery.of(context).disableAnimations) {
      _menu.value = to;
    } else {
      _menu.animateWith(
        SpringSimulation(_menuSpring, _menu.value, to, _menu.velocity),
      );
    }
  }

  Hub get hub => widget.hub;
  // ALERO_SECTION=explorer (etc.) opens that screen first: handy for screenshots and manual checks.
  late Section _section =
      Section.values
          .where((s) => s.name == Platform.environment['ALERO_SECTION'])
          .firstOrNull ??
      widget.initialSection;
  late final StreamSubscription<String> _msgs;
  bool _shareOpen = false, _shotOpen = false, _receiveOpen = false;
  final _received = <String>{};

  /// Phone layout: true while the page is scrolled away from its top; the bottom bar shrinks meanwhile.
  final _compactBar = ValueNotifier<bool>(false);

  /// Scroll offsets where the phone's bottom bar and title bar go compact (past [compactOn]) and back (under
  /// [compactOff]), shared so both change on the same frame. Between them each keeps its state: no flicker.
  static const compactOn = 24.0, compactOff = 4.0;

  bool _onScroll(ScrollNotification n) {
    final m = n.metrics;
    if (m.axis != Axis.vertical ||
        n is! ScrollUpdateNotification && n is! ScrollEndNotification) {
      return false;
    }
    // A screen that fits without scrolling leaves the bar alone. Between 4 and 24 px it keeps its state, so a
    // finger resting near the top does not make it flicker.
    if (m.maxScrollExtent <= m.minScrollExtent) return false;
    final off = m.pixels - m.minScrollExtent;
    if (off > compactOn) {
      _compactBar.value = true;
    } else if (off < compactOff) {
      _compactBar.value = false;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Native.pc) windowManager.addListener(this);
    _msgs = hub.messages.stream.listen((m) {
      if (mounted) {
        ScaffoldMessenger.of(context).showToast(SnackBar(content: Text(m)));
      }
    });
    hub.addListener(_questions);
    hub.confirmSend = (files, to) async {
      if (!mounted) return true;
      final ok = await showSendPreview(context, files, to);
      if (ok && mounted) showSendProgress(context, hub, files.length);
      return ok;
    };
    hub.onIslandControl = (id, what) {
      if (mounted) runIslandControl(context, hub, id, what);
    };
    // Once the phones are known (the island may have started the app for one of these).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final (id, what) in [...hub.islandQueue]) {
        hub.onIslandControl?.call(id, what);
      }
      hub.islandQueue.clear();
    });
  }

  @override
  void dispose() {
    hub.confirmSend = null;
    hub.onIslandControl = null;
    WidgetsBinding.instance.removeObserver(this);
    if (Native.pc) windowManager.removeListener(this);
    _msgs.cancel();
    hub.removeListener(_questions);
    _compactBar.dispose();
    _menu.dispose();
    super.dispose();
  }

  /// The window was resized: what rebuilds now is not new (no entrance animations).
  @override
  void didChangeMetrics() => Entrance.hush();

  /// Back from system settings or another app: permissions, shares and the system color may have changed.
  @override
  void didChangeLocales(List<Locale>? locales) => hub.systemLocaleChanged();

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    hub.remote.mediaForeground(s == AppLifecycleState.resumed);
    // In the background the phone needs its memory more than Alero needs decoded pictures it is not showing; the
    // ones on screen stay, and the rest decode again on return (as after minimising on the computer).
    if (isPhone && s == AppLifecycleState.paused) {
      PaintingBinding.instance.imageCache.clear();
    }
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

  void _go(Section s) {
    _compactBar.value = false; // a new screen starts at its top
    setState(() => _section = s);
  }

  /// Pairing code, incoming-file and share questions appear once each, and close by themselves when the
  /// engine no longer waits for an answer (the other side answered, it timed out, or it was answered by code).
  DialogRoute<bool>? _pairRoute, _offerRoute;

  /// A home-screen widget's button: the same screens the app's own buttons open.
  void _widgetAction() {
    final a = hub.widgetAction;
    if (a == null) return;
    final main = mainPeer(hub);
    final pc = main?.state == pb.PeerState.connected
        ? main
        : hub.peers
              .where((p) => p.trusted && p.state == pb.PeerState.connected)
              .firstOrNull;
    if (pc == null && const {'send', 'clip', 'control', 'screen'}.contains(a)) {
      if (!hub.widgetWaited) return; // still connecting
      hub.widgetAction = null;
      _go(Section.devices);
      hub.messages.add('Tu ordenador no está conectado.');
      return;
    }
    hub.widgetAction = null;
    switch (a) {
      case 'devices':
        _go(Section.devices);
      case 'files':
        hub.openDownloads();
      case 'send':
        hub.send(pc!.id);
      case 'clip':
        openClipboard(context, hub, pc!.id);
      case 'control':
        openPcControl(context, hub, pc!.id, pc.name);
      case 'screen':
        openPcScreen(context, hub, pc!.id, pc.name);
      default:
        _go(Section.home);
    }
  }

  void _questions() {
    _widgetAction();
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
    // A file starts arriving: its progress, then «Finalizado» with the file. Hidden ones do not come back.
    final arriving = {
      for (final x in hub.active)
        if (x.incoming && !x.quiet) x.id,
    };
    if (arriving.difference(_received).isNotEmpty && !_receiveOpen) {
      _receiveOpen = true;
      showTransfer(
        context,
        hub,
        incoming: true,
        before: {
          for (final x in hub.active)
            if (!arriving.contains(x.id)) x.id,
          for (final d in hub.ended) d.x.id,
        },
      ).whenComplete(() => _receiveOpen = false);
    }
    _received.addAll(arriving);
    if (hub.shot != null && !_shotOpen) {
      _shotOpen = true;
      showShot(context, hub).whenComplete(() => _shotOpen = false);
    }
    if (hub.share != null && !_shareOpen) {
      _shareOpen = true;
      showModalBottomSheet<void>(
        sheetAnimationStyle: sheetMotion(context),
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
    Section.messages => MessagesScreen(hub),
    Section.calls => CallsScreen(hub),
    Section.notifications => NotificationsScreen(hub),
    Section.photos => PhotosScreen(hub),
    Section.explorer => ExplorerScreen(hub),
    Section.vault => const VaultScreen(),
    Section.devices => DevicesScreen(hub),
    Section.settings => SettingsScreen(hub),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // sms too: the Mensajes badge follows unread conversations.
    listenable: Listenable.merge([hub, hub.sms]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        // Adapted from Orion Store's AnimatedContent(tab): 0.98 -> 1 scale
        // and effect fade, reversed naturally when the destination leaves.
        // Both Windows and Android use this same transition.
        final page = PageTransitionSwitcher(
          duration: AleroMotion.duration(context, 300),
          layoutBuilder: (entries) =>
              Stack(alignment: Alignment.topCenter, children: entries),
          transitionBuilder: AleroMotion.tab,
          child: KeyedSubtree(key: ValueKey(_section), child: _page()),
        );
        // The computer always has the side menu: its phone sections do not fit a bottom bar.
        return isPhone ? _narrow(page) : _wide(page);
      },
    ),
  );

  int _badge(Section s) => switch (s) {
    Section.notifications => hub.notifs.values.expand((items) => items).length,
    Section.messages =>
      hub.sms.threads.where((t) => !t.read).length +
          hub.notifs.values.expand((l) => l).where((n) => n.chat).length,
    _ => 0,
  };

  Widget _wide(Widget page) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final online = hub.peers
        .where((p) => p.trusted && p.state == pb.PeerState.connected)
        .toList();
    // [o]: how open the menu reads, 0 (icons only) to 1 (names), eased from its width so labels, group titles and
    // counters cross-fade as it moves instead of swapping at a threshold.
    Widget menu(double w) {
      final o = _smooth((w - 96) / (_menuOpen - 96));
      return SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 13, 10, 12),
              child: Row(
                children: [
                  const AleroMark(size: 22),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _MenuLabel(o, 'Alero', style: t.titleSmall),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextButton.icon(
                onPressed: _toggleMenu,
                // The two glyphs differ only in the arrow: cross-fade them with the width.
                icon: Stack(
                  children: [
                    Opacity(
                      opacity: o,
                      child: const Icon(
                        FluentIcons.panel_left_contract_24_regular,
                      ),
                    ),
                    Opacity(
                      opacity: 1 - o,
                      child: const Icon(
                        FluentIcons.panel_left_expand_24_regular,
                      ),
                    ),
                  ],
                ),
                label: _MenuLabel(
                  o,
                  _sidebarCollapsed ? 'Expandir menú' : 'Contraer menú',
                ),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  foregroundColor: s.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 7),
                children: [
                  // One highlight glides between destinations (group headers count as children too). While the
                  // menu moves it sticks to its item, which the folding group titles shift every frame.
                  SlidingSelection(
                    color: s.surfaceContainerHighest,
                    inset: const EdgeInsets.only(bottom: 2),
                    glide: !_menu.isAnimating,
                    selected: [
                      for (final d in _dests) ...[
                        if (d.group != null) null,
                        d.section,
                      ],
                    ].indexOf(_section),
                    children: [
                      for (final d in _dests) ...[
                        if (d.group != null) _GroupTitle(d.group!, o),
                        _NavItem(
                          icon: d.icon,
                          label: d.label,
                          reveal: o,
                          selected: d.section == _section,
                          badge: _badge(d.section),
                          onTap: () => _go(d.section),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.all(8),
              child: AnimatedSwitcher(
                duration: AleroMotion.micro(context, Fluent.d167),
                child: o < .5
                    ? IconButton(
                        key: const ValueKey('icon'),
                        icon: BrandMark(
                          online.isEmpty
                              ? ''
                              : _PhoneChip._maker(hub, online.first.id),
                          online: online.isNotEmpty,
                          size: 28,
                        ),
                        onPressed: () => _go(Section.devices),
                        tooltip: tx('Dispositivos'),
                      )
                    : _PhoneChip(
                        online,
                        hub,
                        key: const ValueKey('chip'),
                        onTap: () => _go(Section.devices),
                      ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: s.surface,
      body: Row(
        children: [
          // The menu springs its width and the page's left edge follows it on every frame, so the cards stretch
          // with it instead of jumping to their final size first. Home picks its columns from the window width
          // (MediaQuery), so those stay put; a card's own LayoutBuilder switches once, as the edge passes it.
          Expanded(
            child: AnimatedBuilder(
              animation: _menu,
              builder: (context, content) {
                // The spring's overshoot is a few px; never thinner than the icons need.
                final w = math.max(_menu.value, _menuShut - 6);
                return Stack(
                  children: [
                    Positioned(
                      left: w,
                      top: 0,
                      right: 0,
                      bottom: 0,
                      child: content!,
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: w,
                      child: ClipRect(
                        child: ColoredBox(color: s.surface, child: menu(w)),
                      ),
                    ),
                  ],
                );
              },
              child: ColoredBox(
                color: s.surface,
                child: Column(
                  children: [
                    CallBar(hub),
                    Expanded(child: _Drop(hub, child: page)),
                  ],
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
    body: NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: page,
    ),
    bottomNavigationBar: SafeArea(
      minimum: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
      child: AleroNavBar(
        items: [
          for (final d in _dests)
            NavData(d.icon, d.label, badge: _badge(d.section)),
        ],
        selected: _dests.indexWhere((d) => d.section == _section),
        onSelect: (i) => _go(_dests[i].section),
        compact: _compactBar,
      ),
    ),
  );
}

/// Sidebar destination: a full-width pill with icon and label on one line, so they line up exactly.
/// The pill and the icon fill change with spring motion.
/// Side menu widths on the computer: open with names, and folded to its icons.
const _menuOpen = 226.0, _menuShut = 76.0;

double _smooth(double x) {
  final p = x.clamp(0.0, 1.0);
  return p * p * (3 - 2 * p);
}

/// A name in the side menu: fades and slides 10 px with how open the menu is ([o], 0 to 1); kept on one line
/// and clipped, so a narrowing menu never wraps or overflows it.
class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.o, this.text, {this.style});
  final double o;
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: o.clamp(0.0, 1.0),
    child: Transform.translate(
      offset: Offset(-10 * (1 - o), 0),
      child: Text(
        text,
        style: style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
      ),
    ),
  );
}

/// A group title in the side menu ("COMUNICACIÓN"). As the menu folds it shrinks from 41 to 13 px and turns into a
/// short line, so the items below glide up instead of jumping when the titles go.
class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text, this.o);
  final String text;
  final double o;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final v = o.clamp(0.0, 1.0);
    return SizedBox(
      height: 13 + 28 * v,
      child: Stack(
        children: [
          Positioned(
            left: 12,
            bottom: 9,
            child: Opacity(
              opacity: v * v,
              child: Text(
                text,
                maxLines: 1,
                softWrap: false,
                style: t.labelSmall?.copyWith(
                  color: s.onSurfaceVariant,
                  letterSpacing: .8,
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            bottom: 6,
            width: 38,
            height: 1,
            child: Opacity(
              opacity: 1 - v,
              child: ColoredBox(color: s.outlineVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge = 0,
    this.reveal = 1,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  /// How open the menu is, 0 to 1: the name and counter fade with it, and the counter becomes a dot on the icon.
  final double reveal;

  /// Room for the name and counter when the menu is open (226 − list and item padding − icon and gap). They are
  /// laid out at this width always and clipped by the narrower menu, so nothing reflows or overflows mid-way.
  static const _labelRoom = 226.0 - 7 * 2 - Gap.m * 2 - 22 - Gap.m;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final sel = selected;
    // The selected pill is drawn by the sliding highlight behind the list; hover is AleroPress's tint.
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        button: true,
        selected: sel,
        label: label,
        child: AleroPress(
          radius: 12,
          onTap: onTap,
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.m),
              child: ExcludeSemantics(
                // Icon fill, color and label weight all follow the selection together.
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: sel ? 1 : 0),
                  duration: AleroMotion.micro(context, Fluent.d167),
                  curve: Fluent.enter,
                  builder: (_, f, _) {
                    final fg = Color.lerp(s.onSurfaceVariant, s.onSurface, f)!;
                    final o = reveal.clamp(0.0, 1.0);
                    return Row(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Icon(icon, size: 22, color: fg, fill: f),
                            if (badge > 0)
                              Positioned(
                                right: -3,
                                top: -2,
                                child: Opacity(
                                  opacity: 1 - o,
                                  child: Container(
                                    width: 9,
                                    height: 9,
                                    decoration: BoxDecoration(
                                      color: s.error,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: s.surface,
                                        width: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: Gap.m),
                        Expanded(
                          child: ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.centerLeft,
                              minWidth: _labelRoom,
                              maxWidth: _labelRoom,
                              child: Opacity(
                                opacity: o,
                                child: Transform.translate(
                                  offset: Offset(-10 * (1 - o), 0),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle.lerp(
                                            weight(t.labelLarge, 500),
                                            t.labelLarge,
                                            f,
                                          )?.copyWith(color: fg),
                                        ),
                                      ),
                                      if (badge > 0)
                                        Transform.scale(
                                          scale: .6 + .4 * o,
                                          child: Badge(label: Text('$badge')),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
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
  const _PhoneChip(this.online, this.hub, {super.key, required this.onTap});
  final List<pb.Peer> online;
  final Hub hub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final peer = online.firstOrNull;
    final look = peer == null ? null : hub.look[peer.id];
    final name = peer == null ? null : look?.name ?? peer.name;
    final status = online.isEmpty
        ? tx('Ningún dispositivo conectado.')
        : (online.length == 1
              ? '$name · ${tx('Conectado')}'
              : tr('{} conectados', [online.length]));
    // Only the maker's mark here: the big picture of the phone, with its wallpaper, is on Inicio.
    return Tooltip(
      message: status,
      child: Semantics(
        button: true,
        label: status,
        child: Material(
          color: s.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.tile),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.tile),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(Gap.s),
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    BrandMark(
                      peer == null ? '' : _maker(hub, peer.id),
                      online: peer != null,
                    ),
                    const SizedBox(width: Gap.s + 2),
                    Expanded(
                      child: Text(
                        peer == null
                            ? 'Sin conexión'
                            : (online.length == 1
                                  ? name!
                                  : tr('{} conectados', [online.length])),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: peer == null
                              ? s.onSurfaceVariant
                              : s.onSurface,
                        ),
                      ),
                    ),
                    Icon(
                      FluentIcons.chevron_right_24_regular,
                      size: 20,
                      color: s.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _maker(Hub hub, String id) {
    final i = hub.info[id];
    if (i == null) return '';
    return i.manufacturer.isNotEmpty ? i.manufacturer : i.phoneId.brand;
  }
}

/// The maker of a phone as a round mark (its initial, in the maker's own color when known) with a dot that says
/// it is connected. Without a maker, the plain phone icon.
class BrandMark extends StatelessWidget {
  const BrandMark(this.maker, {super.key, this.online = false, this.size = 32});
  final String maker;
  final bool online;
  final double size;

  static const _colors = {
    'google': Color(0xFF4285F4),
    'samsung': Color(0xFF1428A0),
    'xiaomi': Color(0xFFFF6900),
    'redmi': Color(0xFFFF6900),
    'poco': Color(0xFFFFC107),
    'motorola': Color(0xFF5C92FA),
    'oneplus': Color(0xFFEB0029),
    'oppo': Color(0xFF1BA784),
    'realme': Color(0xFFFFC915),
    'vivo': Color(0xFF415FFF),
    'huawei': Color(0xFFCF0A2C),
    'honor': Color(0xFF00A4E4),
    'nothing': Color(0xFF111111),
    'sony': Color(0xFF111111),
    'nokia': Color(0xFF124191),
    'asus': Color(0xFF00539B),
    'fairphone': Color(0xFF3E8F85),
  };

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final key = maker.trim().toLowerCase().split(' ').first;
    final tint = _colors[key];
    final letter = maker.trim().isEmpty ? '' : maker.trim()[0].toUpperCase();
    return SizedBox(
      width: size + 2,
      height: size + 2,
      child: Stack(
        children: [
          // Google's phones get the four-color G on white instead of a letter.
          if (key == 'google')
            Container(
              width: size,
              height: size,
              padding: EdgeInsets.all(size * .2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: s.shadow.withValues(alpha: .12),
                    blurRadius: 2,
                    offset: const Offset(0, .5),
                  ),
                ],
              ),
              child: const CustomPaint(painter: _GoogleG()),
            )
          else
            Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tint ?? s.surfaceContainerHighest,
              ),
              child: letter.isEmpty
                  ? Icon(FluentIcons.phone_24_regular, size: size * .55)
                  : Text(
                      letter,
                      style: TextStyle(
                        fontSize: size * .52,
                        fontWeight: FontWeight.w700,
                        height: 1,
                        color: tint == null
                            ? s.onSurface
                            : (ThemeData.estimateBrightnessForColor(tint) ==
                                      Brightness.dark
                                  ? Colors.white
                                  : Colors.black),
                      ),
                    ),
            ),
          Positioned(
            right: 0,
            bottom: 0,
            child: AnimatedOpacity(
              opacity: online ? 1 : 0,
              duration: AleroMotion.micro(context, Fluent.d167),
              child: Container(
                width: size * .3,
                height: size * .3,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.pal.signal,
                  border: Border.all(color: s.surfaceContainerHigh, width: 2),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The four-color G of Google, drawn as a thick ring cut open at the upper right, with its blue bar.
class _GoogleG extends CustomPainter {
  const _GoogleG();

  static const _blue = Color(0xFF4285F4),
      _green = Color(0xFF34A853),
      _yellow = Color(0xFFFBBC05),
      _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final d = math.min(size.width, size.height);
    final w = d * .22;
    final c = size.center(Offset.zero);
    final r = (d - w) / 2;
    final ring = Rect.fromCircle(center: c, radius: r);
    double deg(double a) => a * math.pi / 180;
    Paint p(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w;
    canvas
      ..drawArc(ring, deg(-42), deg(-100), false, p(_red))
      ..drawArc(ring, deg(-142), deg(-76), false, p(_yellow))
      ..drawArc(ring, deg(142), deg(-100), false, p(_green))
      ..drawArc(ring, deg(42), deg(-42), false, p(_blue))
      ..drawRect(
        Rect.fromLTRB(
          c.dx - w * .05,
          c.dy - w / 2,
          c.dx + r + w / 2,
          c.dy + w / 2,
        ),
        Paint()..color = _blue,
      );
  }

  @override
  bool shouldRepaint(_GoogleG old) => false;
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
              : tr('{} archivos', [s.files.length]))
        : tr('Texto: «{}»', [
            s.text.length > 60 ? '${s.text.substring(0, 60)}…' : s.text,
          ]);
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
                      icon: const Icon(FluentIcons.desktop_24_regular),
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
      icon: const Icon(FluentIcons.link_24_regular),
      title: Text(tr('Emparejar con {}', [p.name])),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr('Comprueba que {} muestra este mismo código.', [p.name]),
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
              label: tr('Código {}', [p.code.split('').join(' ')]),
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
      icon: const Icon(FluentIcons.arrow_download_24_regular),
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
                  tr('{} · de {}', [size(o.size.toInt()), o.peerName]),
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
    await showAleroDialog<bool>(
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
/// On the phone the title collapses as the page scrolls: the large one fades out with the content and a compact
/// one fades into a pinned bar, and each section fades up as it scrolls into view ([ScrollReveal]).
class ScreenFrame extends StatefulWidget {
  const ScreenFrame({
    super.key,
    required this.title,
    required this.children,
    this.onRefresh,
    this.trailing,
    this.maxWidth = 1120,
    this.revealEach = true,
  });
  final String title;
  final double maxWidth;
  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  final Widget? trailing;

  /// Off when the screen reveals its own pieces (Home on the phone wraps each tile), so nothing moves twice.
  final bool revealEach;

  /// Height of the phone's pinned title bar; the large title sits in a row of the same height under it.
  static const barHeight = 64.0;

  @override
  State<ScreenFrame> createState() => _ScreenFrameState();
}

class _ScreenFrameState extends State<ScreenFrame> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideLayout;
    final collapsing = isPhone && !wide;
    final side = wide ? Gap.xxl : Gap.l;
    final style = wide
        ? Theme.of(context).textTheme.headlineMedium
        : Theme.of(context).textTheme.headlineSmall;
    final title = Semantics(
      header: true,
      child: Text(widget.title, style: style),
    );
    // Sections fade up as they scroll into view on the phone and, since Beta 2.5, on the computer too (no pinned
    // bar or floating navigation there, so nothing to clear at the edges). Narrow windows keep the list reveal.
    Widget reveal(int i, Widget c) => !widget.revealEach
        ? c
        : collapsing
        ? ScrollReveal(child: c)
        : wide && !isPhone
        ? ScrollReveal(topInset: 0, bottomInset: 0, child: c)
        : Reveal(index: i, child: c);
    final list = ListView(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(
        side,
        collapsing ? 0 : Gap.xl,
        side,
        wide ? Gap.xxl : 112,
      ),
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (collapsing)
                  // Leaves room on the right for the bar's button, which stays pinned above this row.
                  SizedBox(
                    height: ScreenFrame.barHeight,
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: widget.trailing == null ? 0 : 56,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _LargeTitle(_scroll, child: title),
                      ),
                    ),
                  )
                else
                  Row(
                    children: [
                      Expanded(child: title),
                      ?widget.trailing,
                    ],
                  ),
                SizedBox(height: collapsing ? Gap.s : Gap.l),
                for (final (i, c) in widget.children.indexed) reveal(i, c),
              ],
            ),
          ),
        ),
      ],
    );
    final body = widget.onRefresh == null || !isPhone
        ? list
        : RefreshIndicator(
            onRefresh: widget.onRefresh!,
            // Below the pinned bar, not under it.
            edgeOffset: collapsing ? ScreenFrame.barHeight : 0,
            child: list,
          );
    return SafeArea(
      bottom: false,
      child: !collapsing
          ? body
          : Stack(
              children: [
                body,
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _CollapsingBar(
                    _scroll,
                    title: widget.title,
                    trailing: widget.trailing,
                    side: side,
                  ),
                ),
              ],
            ),
    );
  }
}

/// How far the page has scrolled past the large title, 0 to 1 over 28 px, smoothstepped so it starts and ends soft;
/// nearly done (0.94) by [_ShellState.compactOn], where the compact title takes over.
double _collapse(ScrollController c) {
  final y = c.hasClients ? math.max(0.0, c.offset) : 0.0;
  final p = math.min(1.0, y / 28);
  return p * p * (3 - 2 * p);
}

/// The large title: follows the content up and fades out, shrinking slightly, as it reaches the pinned bar.
class _LargeTitle extends StatelessWidget {
  const _LargeTitle(this.scroll, {required this.child});
  final ScrollController scroll;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: scroll,
    child: child,
    builder: (_, c) {
      final e = _collapse(scroll);
      return Opacity(
        opacity: 1 - e,
        child: Transform.scale(
          scale: 1 - .04 * e,
          alignment: Alignment.centerLeft,
          child: c,
        ),
      );
    },
  );
}

/// The phone's pinned bar: see-through at rest so the large title shows under it; its surface fades in with the
/// scroll, and once the large title is gone a compact one slides in, with a hairline under the bar. It goes compact
/// at the same offsets as the bottom bar, so the two change together.
class _CollapsingBar extends StatefulWidget {
  const _CollapsingBar(
    this.scroll, {
    required this.title,
    required this.trailing,
    required this.side,
  });
  final ScrollController scroll;
  final String title;
  final Widget? trailing;
  final double side;

  @override
  State<_CollapsingBar> createState() => _CollapsingBarState();
}

class _CollapsingBarState extends State<_CollapsingBar> {
  bool _collapsed = false;

  // Easing.emphasizedDecelerate's lighter sibling (M3 "standard decelerate"): quick in, soft stop.
  static const Curve _in = Cubic(.2, 0, 0, 1);

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final line = Theme.of(context).colorScheme.outlineVariant;
    final d = AleroMotion.micro(context, const Duration(milliseconds: 300));
    return AnimatedBuilder(
      animation: widget.scroll,
      builder: (_, _) {
        final scroll = widget.scroll, side = widget.side;
        final trailing = widget.trailing;
        final e = _collapse(scroll);
        final y = scroll.hasClients ? scroll.offset : 0.0;
        if (y > _ShellState.compactOn) {
          _collapsed = true;
        } else if (y < _ShellState.compactOff) {
          _collapsed = false;
        }
        final collapsed = _collapsed;
        // Only the button takes touches: a drag that starts on the bar still scrolls the page under it.
        return SizedBox(
          height: ScreenFrame.barHeight,
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: bg.withValues(alpha: e),
                    child: Stack(
                      children: [
                        Padding(
                          padding: EdgeInsets.only(
                            left: side,
                            right: side + (trailing == null ? 0 : 56),
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            // The large title is the heading for screen readers; this copy is only visual.
                            child: ExcludeSemantics(
                              child: AnimatedSlide(
                                offset: collapsed
                                    ? Offset.zero
                                    : const Offset(0, .3),
                                duration: d,
                                curve: _in,
                                child: AnimatedOpacity(
                                  opacity: collapsed ? 1 : 0,
                                  duration: d,
                                  curve: _in,
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: AnimatedOpacity(
                            opacity: collapsed ? 1 : 0,
                            duration: d,
                            curve: _in,
                            child: SizedBox(
                              height: 1,
                              child: ColoredBox(color: line),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (trailing != null)
                Positioned(
                  right: side,
                  top: 0,
                  bottom: 0,
                  child: Center(child: trailing),
                ),
            ],
          ),
        );
      },
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
      final pick = await showAleroDialog<pb.Peer>(
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
                                FluentIcons.arrow_upload_24_regular,
                                size: 36,
                                color: s.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(height: Gap.l),
                            Text(
                              online.isEmpty
                                  ? 'Conecta un dispositivo para enviar'
                                  : tr('Suelta para enviar a {}', [
                                      online.length == 1
                                          ? online.first.name
                                          : '…',
                                    ]),
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
