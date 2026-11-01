import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../remote.dart';
import '../src/rust/api/engine.dart' as pb;
import 'expressive.dart';
import 'theme.dart';
import 'widgets.dart';

String _clock(int ms) {
  final s = ms ~/ 1000;
  final h = s ~/ 3600,
      m = (s % 3600) ~/ 60,
      ss = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// "Reproduciendo": what the phone is playing, with transport controls. A panel on Home, not a destination.
class MediaPanel extends StatefulWidget {
  const MediaPanel(
    this.hub,
    this.peerId, {
    super.key,
    this.computer = false,
    this.hideInactive = true,
  });
  final bool computer, hideInactive;
  final Hub hub;
  final String peerId;

  @override
  State<MediaPanel> createState() => _MediaPanelState();
}

class _MediaPanelState extends State<MediaPanel> with WidgetsBindingObserver {
  bool _foreground = true;
  Timer? _tick;
  double? _seek, _vol;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _watch();
  }

  void _watchRefresh() {
    if (widget.computer) {
      widget.hub.sendMessage(widget.peerId, 'pb.x.pcmedia.watch', {});
    } else {
      widget.hub.sendMessage(widget.peerId, 'pb.x.media.request', {});
    }
  }

  void _watch() {
    if (widget.computer) {
      widget.hub.remote.watchMedia(widget.peerId);
    } else {
      widget.hub.sendMessage(widget.peerId, 'pb.x.media.request', {});
    }
  }

  @override
  void didUpdateWidget(MediaPanel old) {
    super.didUpdateWidget(old);
    if (old.peerId != widget.peerId ||
        old.hub != widget.hub ||
        old.computer != widget.computer) {
      if (old.computer) old.hub.remote.unwatchMedia(old.peerId);
      _watch();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    if (widget.computer) widget.hub.remote.unwatchMedia(widget.peerId);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _foreground = state == AppLifecycleState.resumed);
  }

  void _command(String action, {int? position, int? value}) {
    if (widget.computer) {
      widget.hub.remote.media(widget.peerId, action);
    } else {
      widget.hub.mediaCmd(
        widget.peerId,
        action,
        position: position,
        value: value,
      );
    }
  }

  Widget _pcVolume() => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        tooltip: 'Bajar volumen',
        onPressed: () => _command('volume_down'),
        icon: const Icon(Symbols.volume_down_rounded),
      ),
      IconButton(
        tooltip: 'Silenciar',
        onPressed: () => _command('mute'),
        icon: const Icon(Symbols.volume_off_rounded),
      ),
      IconButton(
        tooltip: 'Subir volumen',
        onPressed: () => _command('volume_up'),
        icon: const Icon(Symbols.volume_up_rounded),
      ),
    ],
  );

  /// Rebuild once a second while playing, so the extrapolated position moves.
  void _ticking(bool playing) {
    if (playing && _tick == null) {
      _tick = Timer.periodic(
        const Duration(seconds: 1),
        (_) => mounted ? setState(() {}) : null,
      );
    } else if (!playing) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = widget.hub, id = widget.peerId;
    final m = hub.media[id];
    final access = widget.computer || (hub.info[id]?.notifAccess ?? false);
    final online = hub.peers.any(
      (p) => p.id == id && p.state == pb.PeerState.connected,
    );
    _ticking(
      _foreground && (m?.playing ?? false) && (!widget.computer || online),
    );
    if (widget.computer &&
        (!online ||
            hub.info[id]?.remoteAllowed != true ||
            (widget.hideInactive && m?.active != true))) {
      return const SizedBox.shrink();
    }
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;

    Widget body;
    if (!access) {
      body = const EmptyState(
        card: false,
        icon: Symbols.music_off_rounded,
        title: 'Falta un permiso en el teléfono',
        body: 'Abre la app en el teléfono y pulsa «Activar» en el aviso de acceso a notificaciones.',
      );
    } else if (m == null || !m.active) {
      body = Column(
        children: [
          EmptyState(
            card: false,
            icon: Symbols.music_note_rounded,
            title: 'No suena nada',
            body: widget.computer
                ? 'Reproduce música o un vídeo en el ordenador.'
                : 'Reproduce música o un vídeo en el teléfono y aparecerá aquí.',
          ),
          if (widget.computer) _pcVolume(),
        ],
      );
    } else {
      final pos = _seek?.round() ?? m.positionNow;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Art(m, size: 64),
              const SizedBox(width: Gap.l),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.title.isEmpty ? 'Sin título' : m.title,
                      style: t.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      [m.artist, m.app].where((x) => x.isNotEmpty).join(' · '),
                      style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Anterior',
                onPressed: m.supports(16) ? () => _command('prev') : null,
                icon: const Icon(Symbols.skip_previous_rounded, fill: 1),
              ),
              const SizedBox(width: Gap.xs),
              MorphButton(
                icon: m.playing
                    ? Symbols.pause_rounded
                    : Symbols.play_arrow_rounded,
                label: m.playing ? 'Pausar' : 'Reproducir',
                on: m.playing,
                size: 48,
                onPressed: m.supports(512 | (m.playing ? 2 : 4))
                    ? () => _command('toggle')
                    : null,
              ),
              const SizedBox(width: Gap.xs),
              IconButton(
                tooltip: 'Siguiente',
                onPressed: m.supports(32) ? () => _command('next') : null,
                icon: const Icon(Symbols.skip_next_rounded, fill: 1),
              ),
            ],
          ),
          if (m.duration > 0) ...[
            const SizedBox(height: Gap.m),
            Row(
              children: [
                Text(
                  _clock(pos),
                  style: t.labelSmall?.copyWith(fontFeatures: tabular),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                    ),
                    child: Slider(
                      value: pos.clamp(0, m.duration).toDouble(),
                      max: m.duration.toDouble(),
                      semanticFormatterCallback: (v) => _clock(v.round()),
                      onChanged: !widget.computer && m.supports(256)
                          ? (v) => setState(() => _seek = v)
                          : null,
                      onChangeEnd: (v) {
                        _command('seek', position: v.round());
                        setState(() => _seek = null);
                      },
                    ),
                  ),
                ),
                Text(
                  _clock(m.duration),
                  style: t.labelSmall?.copyWith(fontFeatures: tabular),
                ),
              ],
            ),
          ],
          if (widget.computer) _pcVolume(),
          if (!widget.computer && m.volumeMax > 0)
            Row(
              children: [
                Icon(
                  Symbols.volume_down_rounded,
                  size: 18,
                  color: s.onSurfaceVariant,
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                    ),
                    child: Slider(
                      value: (_vol ?? m.volume.toDouble()).clamp(
                        0,
                        m.volumeMax.toDouble(),
                      ),
                      max: m.volumeMax.toDouble(),
                      divisions: m.volumeMax,
                      semanticFormatterCallback: (v) =>
                          'Volumen ${v.round()} de ${m.volumeMax}',
                      onChanged: (v) => setState(() => _vol = v),
                      onChangeEnd: (v) {
                        _command('volume', value: v.round());
                        setState(() => _vol = null);
                      },
                    ),
                  ),
                ),
                Icon(
                  Symbols.volume_up_rounded,
                  size: 18,
                  color: s.onSurfaceVariant,
                ),
              ],
            ),
        ],
      );
    }
    return Panel(
      title: 'Reproduciendo',
      icon: Symbols.music_note_rounded,
      action: IconButton(
        tooltip: 'Sincronizar reproducción',
        onPressed: _watchRefresh,
        icon: const Icon(Symbols.refresh_rounded),
      ),
      child: AnimatedSize(
        duration: motion(context, Spring.spatial.settle),
        curve: Spring.spatial,
        alignment: Alignment.topCenter,
        child: body,
      ),
    );
  }
}

class _Art extends StatelessWidget {
  const _Art(this.m, {required this.size});
  final MediaState m;
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: SizedBox(
        width: size,
        height: size,
        child: m.art != null
            ? Image.memory(
                m.art!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                semanticLabel: 'Portada',
              )
            : ColoredBox(
                color: s.tertiaryContainer,
                child: Icon(
                  Symbols.music_note_rounded,
                  size: size * 0.4,
                  color: s.onTertiaryContainer,
                ),
              ),
      ),
    );
  }
}
