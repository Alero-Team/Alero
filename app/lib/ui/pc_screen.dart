import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../pc_remote.dart';
import 'remote_ui.dart';
import 'theme.dart';

/// Watch (and drive) the computer's screen from the phone: frames arrive as JPEGs over the paired connection
/// (about 5 per second, ADR-0011), and the same touch gestures as the touchpad move its pointer. It is a viewer
/// with a remote pointer, not a video stream: no sound, and a short lag is normal.
Future<void> openPcScreen(BuildContext context, Hub hub, String peer, String name) =>
    Navigator.of(context).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => PcScreenPage(hub, peer, name)));

class PcScreenPage extends StatefulWidget {
  const PcScreenPage(this.hub, this.peer, this.name, {super.key});
  final Hub hub;
  final String peer, name;

  @override
  State<PcScreenPage> createState() => _PcScreenPageState();
}

class _PcScreenPageState extends State<PcScreenPage> {
  late final ScreenFeed _feed;
  bool _landscape = false;

  @override
  void initState() {
    super.initState();
    _feed = ScreenFeed(widget.hub, widget.peer);
    widget.hub.screen = _feed;
    _feed.start();
  }

  @override
  void dispose() {
    widget.hub.screen = null;
    // Give the rotation back to the system.
    SystemChrome.setPreferredOrientations(const []);
    _feed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final info = widget.hub.info[widget.peer];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.name, style: t.titleMedium?.copyWith(color: Colors.white)),
        actions: [
          PopupMenuButton<(int, int)>(
            tooltip: 'Calidad',
            icon: const Icon(Symbols.tune_rounded),
            onSelected: (q) => _feed.setQuality(width: q.$1, fps: q.$2),
            itemBuilder: (_) => const [
              PopupMenuItem(value: (640, 8), child: Text('Fluida (640 px)')),
              PopupMenuItem(value: (960, 5), child: Text('Equilibrada (960 px)')),
              PopupMenuItem(value: (1280, 3), child: Text('Nítida (1280 px)')),
            ],
          ),
          IconButton(
            tooltip: 'Girar la pantalla',
            icon: const Icon(Symbols.screen_rotation_rounded),
            onPressed: () {
              _landscape = !_landscape;
              SystemChrome.setPreferredOrientations(_landscape ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : const []);
            },
          ),
          IconButton(
            tooltip: 'Teclado',
            icon: const Icon(Symbols.keyboard_rounded),
            onPressed: () => openKeyboard(context, widget.hub, widget.peer),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([_feed, widget.hub]),
          builder: (context, _) {
            final blocked = remoteBlocker(info, true);
            if (_feed.frame == null) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xxl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (info != null && (!info.remoteAllowed || !info.canScreen))
                        Icon(Symbols.lock_rounded, color: s.onSurfaceVariant, size: 36)
                      else
                        const CircularProgressIndicator(),
                      const SizedBox(height: Gap.l),
                      Text(
                        blocked ?? 'Conectando con la pantalla de ${widget.name}…',
                        textAlign: TextAlign.center,
                        style: t.bodyMedium?.copyWith(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              );
            }
            return Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _feed.w > 0 && _feed.h > 0 ? _feed.w / _feed.h : 16 / 9,
                      child: LayoutBuilder(
                        builder: (context, box) => Touchpad(
                          widget.hub,
                          widget.peer,
                          height: box.maxHeight,
                          gain: 2.2,
                          child: Image.memory(_feed.frame!, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.medium),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(Gap.m),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => widget.hub.remote.click(widget.peer),
                        icon: const Icon(Symbols.mouse_rounded, size: 18),
                        label: const Text('Clic'),
                      ),
                      const SizedBox(width: Gap.s),
                      FilledButton.tonalIcon(
                        onPressed: () => widget.hub.remote.click(widget.peer, button: 'right'),
                        icon: const Icon(Symbols.right_click_rounded, size: 18),
                        label: const Text('Clic derecho'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The screenshot that just arrived: shown large, and already saved with the other received files.
Future<void> showShot(BuildContext context, Hub hub) {
  final shot = hub.shot;
  if (shot == null) return Future.value();
  hub.shot = null;
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final t = Theme.of(ctx).textTheme;
      return Dialog(
        child: Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Captura de ${shot.peerName}', style: t.titleLarge),
              const SizedBox(height: Gap.m),
              Flexible(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.tile),
                  child: InteractiveViewer(maxScale: 6, child: Image.memory(shot.bytes, fit: BoxFit.contain)),
                ),
              ),
              const SizedBox(height: Gap.m),
              Text(
                'Guardada en ${hub.downloads} como ${shot.name}.',
                style: t.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: Gap.s),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: Gap.s,
                  children: [
                    TextButton(onPressed: hub.openDownloads, child: const Text('Abrir carpeta')),
                    FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
