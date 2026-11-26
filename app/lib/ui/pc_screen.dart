import 'qollqe_motion.dart';

import 'dart:async';

import 'package:flutter/material.dart' hide Icon, Text;
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../hub.dart';
import '../pc_remote.dart';
import '../src/rust/api/engine.dart' as pb;
import 'remote_ui.dart';
import 'theme.dart';
import 'icon.dart';
import 'widgets.dart';
import '../l10n.dart';
import 'expressive.dart';
import 'controls.dart' show Presence;

Future<void> openPcScreen(
  BuildContext context,
  Hub hub,
  String peer,
  String name,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => PcScreenPage(hub, peer, name),
  ),
);

class PcScreenPage extends StatefulWidget {
  const PcScreenPage(this.hub, this.peer, this.name, {super.key});
  final Hub hub;
  final String peer, name;

  @override
  State<PcScreenPage> createState() => _PcScreenPageState();
}

class _PcScreenPageState extends State<PcScreenPage>
    with WidgetsBindingObserver {
  late final ScreenFeed _feed;
  bool _landscape = false, _waitingTooLong = false;
  double _lastScale = 1;
  double _gain = 2.2;
  Timer? _wait;

  /// 1 = the whole screen. Closer, the view follows the computer's pointer.
  double _zoom = 1;
  static const _maxZoom = 4.0;

  /// Centre of the zoomed view, as fractions of the screen; it moves only when the pointer nears the edge of the
  /// view, so the picture does not shake with every small movement.
  Offset _cam = const Offset(.5, .5);

  void _zoomBy(double f) =>
      setState(() => _zoom = (_zoom * f).clamp(1.0, _maxZoom));

  /// Follows [at] (the pointer) with a margin of a quarter of the view, and keeps the view inside the screen.
  Offset _follow(Offset? at) {
    final half = .5 / _zoom, slack = .25 / _zoom;
    double axis(double cam, double? p) {
      if (p != null) {
        if (p < cam - slack) cam = p + slack;
        if (p > cam + slack) cam = p - slack;
      }
      return cam.clamp(half, 1 - half);
    }

    return _cam = Offset(axis(_cam.dx, at?.dx), axis(_cam.dy, at?.dy));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _feed = ScreenFeed(widget.hub, widget.peer)..addListener(_frameArrived);
    widget.hub.screen = _feed;
    _start();
  }

  void _start() {
    _waitingTooLong = false;
    _wait?.cancel();
    _feed.start();
    _wait = Timer(const Duration(seconds: 12), () {
      if (mounted && _feed.frame == null) {
        setState(() => _waitingTooLong = true);
      }
    });
  }

  void _frameArrived() {
    if (_feed.frame != null) {
      _wait?.cancel();
      if (_waitingTooLong && mounted) setState(() => _waitingTooLong = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_feed.running) _start();
    } else {
      _wait?.cancel();
      _feed.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wait?.cancel();
    if (identical(widget.hub.screen, _feed)) widget.hub.screen = null;
    SystemChrome.setPreferredOrientations(const []);
    _feed.removeListener(_frameArrived);
    _feed.dispose();
    super.dispose();
  }

  /// The computer's picture in a frame of exactly its own shape (no bands around it), as big as the room allows.
  Widget _viewer(bool canInput) => Center(
    child: AspectRatio(
      aspectRatio: _feed.w > 0 && _feed.h > 0 ? _feed.w / _feed.h : 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.chip),
        child: ColoredBox(
          color: const Color(0xFF0B0D0F),
          child: LayoutBuilder(
            builder: (context, box) {
              final image = Image.memory(
                _feed.frame!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                semanticLabel: tr('Pantalla del ordenador {}', [widget.name]),
                filterQuality: FilterQuality.medium,
                cacheWidth: _feed.w > 0
                    ? (box.maxWidth *
                              _zoom *
                              MediaQuery.devicePixelRatioOf(context))
                          .round()
                          .clamp(1, _feed.w)
                    : null,
              );
              // As big as Windows draws it on that screen (about a 60th of its width), never unreadable.
              final pointer = (box.maxWidth / 50).clamp(12.0, 28.0);
              // The pointer is drawn here, not in the picture: it moves the moment the computer reports it.
              // Zoomed, the picture is scaled around the view's centre; the pointer keeps its size.
              final view = ValueListenableBuilder<Offset?>(
                valueListenable: _feed.cursor,
                builder: (_, at, _) {
                  final (w, h) = (box.maxWidth, box.maxHeight);
                  final cam = _zoom > 1 ? _follow(at) : const Offset(.5, .5);
                  final shift = Offset(
                    w / 2 - cam.dx * w * _zoom,
                    h / 2 - cam.dy * h * _zoom,
                  );
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Transform(
                        transform: Matrix4.translationValues(
                          shift.dx,
                          shift.dy,
                          0,
                        )..scaleByDouble(_zoom, _zoom, 1, 1),
                        child: image,
                      ),
                      if (at != null)
                        IgnorePointer(
                          child: Align(
                            alignment: Alignment.topLeft,
                            // The glyph's tip sits a fifth in and a sixth down inside its box.
                            child: Transform.translate(
                              offset: Offset(
                                shift.dx + at.dx * w * _zoom - pointer / 5,
                                shift.dy + at.dy * h * _zoom - pointer / 6,
                              ),
                              child: _Pointer(pointer),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              );
              return canInput
                  ? Touchpad(
                      widget.hub,
                      widget.peer,
                      height: box.maxHeight,
                      gain: _gain,
                      onZoom: _zoomBy,
                      child: view,
                    )
                  : GestureDetector(
                      // Watching only: pinch still zooms.
                      onScaleUpdate: (d) {
                        if (d.pointerCount == 2) _zoomBy(d.scale / _lastScale);
                        _lastScale = d.scale;
                      },
                      onScaleStart: (_) => _lastScale = 1,
                      child: view,
                    );
            },
          ),
        ),
      ),
    ),
  );

  Widget _pad() => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (_, area) => Touchpad(
            widget.hub,
            widget.peer,
            height: area.maxHeight,
            gain: _gain,
          ),
        ),
      ),
    ],
  );

  /// What replaces the picture when the computer cannot send one: why, and the touchpad if the controls work.
  Widget _unavailable(String note, bool canInput) => Padding(
    padding: const EdgeInsets.all(Gap.m),
    child: Column(
      children: [
        EmptyState(
          icon: FluentIcons.desktop_off_24_regular,
          title: 'La pantalla del PC no está disponible',
          body: [
            note.isNotEmpty ? note : 'El ordenador no está enviando imágenes.',
            if (canInput) 'El panel táctil sigue funcionando.',
          ].join(' '),
          action: 'Reintentar',
          onAction: () => setState(_start),
        ),
        if (canInput) ...[
          const SizedBox(height: Gap.m),
          Expanded(child: _pad()),
          const SizedBox(height: Gap.m),
          MouseActionBar(widget.hub, widget.peer),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_feed, widget.hub]),
    builder: (context, _) {
      final info = widget.hub.info[widget.peer];
      final online = widget.hub.peers.any(
        (p) => p.id == widget.peer && p.state == pb.PeerState.connected,
      );
      final blocker = remoteBlocker(info, online);
      final canInput = blocker == null && (info?.canInput ?? false);
      // No picture will come: the computer cannot capture, said so, or has been silent too long. The touchpad still works.
      final unavailable =
          blocker == null &&
          _feed.frame == null &&
          (info?.canScreen == false || _feed.failed || _waitingTooLong);
      final s = Theme.of(context).colorScheme;
      final t = Theme.of(context).textTheme;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.titleMedium,
          ),
          actions: [
            IconButton(
              tooltip: _zoom > 1
                  ? tx('Ver toda la pantalla')
                  : tx('Acercar (o pellizca la imagen)'),
              isSelected: _zoom > 1,
              icon: MotionFade(
                child: Icon(
                  _zoom > 1
                      ? FluentIcons.zoom_out_24_regular
                      : FluentIcons.zoom_in_24_regular,
                  key: ValueKey(_zoom > 1),
                ),
              ),
              onPressed: blocker != null || _feed.frame == null
                  ? null
                  : () => setState(() => _zoom = _zoom > 1 ? 1 : 2),
            ),
            Presence(
              alignment: Alignment.centerRight,
              child: canInput
                  ? PointerSensitivity(
                      value: _gain,
                      onChanged: (gain) => setState(() => _gain = gain),
                    )
                  : null,
            ),
            PopupMenuButton<(int, int)>(
              popUpAnimationStyle: popUpMotion(context),
              tooltip: tx('Calidad de la pantalla'),
              enabled: blocker == null,
              icon: const Icon(FluentIcons.desktop_edit_24_regular),
              onSelected: (q) => _feed.setQuality(width: q.$1, fps: q.$2),
              itemBuilder: (_) => [
                for (final q in const [
                  (640, 30, 'Fluida'),
                  (960, 15, 'Equilibrada'),
                  (1280, 8, 'Nítida'),
                ])
                  CheckedPopupMenuItem(
                    value: (q.$1, q.$2),
                    checked: _feed.width == q.$1,
                    child: Text('${q.$3} · ${q.$1} px'),
                  ),
              ],
            ),
            IconButton(
              tooltip: tx('Girar la pantalla'),
              icon: const Icon(FluentIcons.arrow_rotate_clockwise_24_regular),
              onPressed: () {
                _landscape = !_landscape;
                SystemChrome.setPreferredOrientations(
                  _landscape
                      ? const [
                          DeviceOrientation.landscapeLeft,
                          DeviceOrientation.landscapeRight,
                        ]
                      : const [],
                );
              },
            ),
          ],
        ),
        body: SafeArea(
          // Only the waiting states animate; the live picture is never wrapped in a switcher, so no frame is delayed.
          child: blocker != null || _feed.frame == null
              ? MotionSwitch(
                  axis: Axis.vertical,
                  child: KeyedSubtree(
                    key: ValueKey(
                      unavailable
                          ? 'unavailable'
                          : blocker != null
                          ? 'blocked'
                          : _waitingTooLong
                          ? 'late'
                          : 'wait',
                    ),
                    child: unavailable
                        ? _unavailable(info?.screenNote ?? '', canInput)
                        : Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(Gap.xl),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (blocker != null)
                                    Icon(
                                      FluentIcons.link_dismiss_24_regular,
                                      size: 32,
                                      color: s.onSurfaceVariant,
                                    )
                                  else if (_waitingTooLong)
                                    Icon(
                                      FluentIcons.desktop_off_24_regular,
                                      size: 32,
                                      color: s.onSurfaceVariant,
                                    )
                                  else
                                    const CircularProgressIndicator(),
                                  const SizedBox(height: Gap.l),
                                  Text(
                                    blocker ??
                                        (_waitingTooLong
                                            ? 'El ordenador todavía no ha enviado una imagen.'
                                            : 'Conectando con la pantalla…'),
                                    textAlign: TextAlign.center,
                                    style: t.bodyLarge,
                                  ),
                                  if (blocker == null && _waitingTooLong) ...[
                                    const SizedBox(height: Gap.m),
                                    FilledButton.tonalIcon(
                                      onPressed: () => setState(_start),
                                      icon: const Icon(FluentIcons.arrow_clockwise_24_regular),
                                      label: const Text('Reintentar'),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(Gap.m),
                  child: LayoutBuilder(
                    builder: (context, box) {
                      if (!canInput) return _viewer(false);
                      // In landscape the image and controls share the width; portrait keeps the controls within thumb reach.
                      if (box.maxWidth >= 600 && box.maxWidth > box.maxHeight) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: _viewer(true)),
                            const SizedBox(width: Gap.m),
                            SizedBox(
                              width: 248,
                              child: Column(
                                children: [
                                  Expanded(child: _pad()),
                                  const SizedBox(height: Gap.m),
                                  MouseActionBar(widget.hub, widget.peer),
                                ],
                              ),
                            ),
                          ],
                        );
                      }
                      // Portrait: the picture takes only its own height; the touchpad gets the rest.
                      final ratio = _feed.w > 0 && _feed.h > 0
                          ? _feed.w / _feed.h
                          : 16 / 9;
                      return Column(
                        children: [
                          SizedBox(
                            height: (box.maxWidth / ratio).clamp(
                              0.0,
                              box.maxHeight * .6,
                            ),
                            child: _viewer(true),
                          ),
                          const SizedBox(height: Gap.m),
                          Expanded(child: _pad()),
                          const SizedBox(height: Gap.m),
                          MouseActionBar(widget.hub, widget.peer),
                        ],
                      );
                    },
                  ),
                ),
        ),
      );
    },
  );
}

/// The computer's pointer over the shared picture: a white arrow with a dark edge, readable on any background.
class _Pointer extends StatelessWidget {
  const _Pointer(this.size);
  final double size;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Icon(
        FluentIcons.cursor_24_regular,
        size: size,
        fill: 1,
        color: Colors.black,
      ),
      Padding(
        padding: EdgeInsets.all(size * .06),
        child: Icon(
          FluentIcons.cursor_24_regular,
          size: size * .88,
          fill: 1,
          color: Colors.white,
        ),
      ),
    ],
  );
}

Future<void> showShot(BuildContext context, Hub hub) {
  final shot = hub.shot;
  if (shot == null) return Future.value();
  hub.shot = null;
  return showAleroDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('Captura de {}', [shot.peerName]),
              style: Theme.of(ctx).textTheme.titleLarge,
            ),
            const SizedBox(height: Gap.m),
            Flexible(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.tile),
                child: InteractiveViewer(
                  maxScale: 6,
                  child: Image.memory(
                    shot.bytes,
                    fit: BoxFit.contain,
                    semanticLabel: tr('Captura de pantalla de {}', [
                      shot.peerName,
                    ]),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Gap.m),
            Text(
              tr('Guardada en {} como {}.', [hub.downloads, shot.name]),
              style: Theme.of(ctx).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Gap.s),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: Gap.s,
                children: [
                  TextButton(
                    onPressed: hub.openDownloads,
                    child: const Text('Abrir carpeta'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cerrar'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
