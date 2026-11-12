import 'dart:async';

import 'package:flutter/material.dart' hide Icon;
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../pc_remote.dart';
import '../src/rust/api/engine.dart' as pb;
import 'remote_ui.dart';
import 'theme.dart';
import 'icon.dart';
import 'widgets.dart';

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
  double _gain = 2.2;
  Timer? _wait;

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
                semanticLabel: 'Pantalla del ordenador ${widget.name}',
                filterQuality: FilterQuality.medium,
                cacheWidth: _feed.w > 0
                    ? (box.maxWidth * MediaQuery.devicePixelRatioOf(context))
                          .round()
                          .clamp(1, _feed.w)
                    : null,
              );
              // As big as Windows draws it on that screen (about a 60th of its width), never unreadable.
              final pointer = (box.maxWidth / 50).clamp(12.0, 28.0);
              // The pointer is drawn here, not in the picture: it moves the moment the computer reports it.
              final view = Stack(
                fit: StackFit.expand,
                children: [
                  image,
                  IgnorePointer(
                    child: ValueListenableBuilder<Offset?>(
                      valueListenable: _feed.cursor,
                      builder: (_, at, _) => at == null
                          ? const SizedBox.shrink()
                          : Align(
                              alignment: Alignment.topLeft,
                              // The glyph's tip sits a fifth in and a sixth down inside its box.
                              child: Transform.translate(
                                offset: Offset(
                                  at.dx * box.maxWidth - pointer / 5,
                                  at.dy * box.maxHeight - pointer / 6,
                                ),
                                child: _Pointer(pointer),
                              ),
                            ),
                    ),
                  ),
                ],
              );
              return canInput
                  ? Touchpad(
                      widget.hub,
                      widget.peer,
                      height: box.maxHeight,
                      gain: _gain,
                      child: view,
                    )
                  : view;
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
          icon: Symbols.desktop_access_disabled_rounded,
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
            if (canInput)
              PointerSensitivity(
                value: _gain,
                onChanged: (gain) => setState(() => _gain = gain),
              ),
            PopupMenuButton<(int, int)>(
              tooltip: 'Calidad de la pantalla',
              enabled: blocker == null,
              icon: const Icon(Symbols.display_settings_rounded),
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
              tooltip: 'Girar la pantalla',
              icon: const Icon(Symbols.screen_rotation_rounded),
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
          child: unavailable
              ? _unavailable(info?.screenNote ?? '', canInput)
              : blocker != null || _feed.frame == null
              ? Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (blocker != null)
                          Icon(
                            Symbols.link_off_rounded,
                            size: 32,
                            color: s.onSurfaceVariant,
                          )
                        else if (_waitingTooLong)
                          Icon(
                            Symbols.desktop_access_disabled_rounded,
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
                            icon: const Icon(Symbols.refresh_rounded),
                            label: const Text('Reintentar'),
                          ),
                        ],
                      ],
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
        Symbols.arrow_selector_tool_rounded,
        size: size,
        fill: 1,
        color: Colors.black,
      ),
      Padding(
        padding: EdgeInsets.all(size * .06),
        child: Icon(
          Symbols.arrow_selector_tool_rounded,
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
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Captura de ${shot.peerName}',
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
                    semanticLabel: 'Captura de pantalla de ${shot.peerName}',
                  ),
                ),
              ),
            ),
            const SizedBox(height: Gap.m),
            Text(
              'Guardada en ${hub.downloads} como ${shot.name}.',
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
