import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../remote.dart';
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
  const MediaPanel(this.hub, this.peerId, {super.key});
  final Hub hub;
  final String peerId;

  @override
  State<MediaPanel> createState() => _MediaPanelState();
}

class _MediaPanelState extends State<MediaPanel> {
  Timer? _tick;
  double? _seek, _vol;
  @override
  void initState() {
    super.initState();
    widget.hub.sendMessage(widget.peerId, 'pb.x.media.request', {});
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

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
    final access = hub.info[id]?.notifAccess ?? false;
    _ticking(m?.playing ?? false);
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
      body = const EmptyState(
        card: false,
        icon: Symbols.music_note_rounded,
        title: 'No suena nada',
        body: 'Reproduce música o un vídeo en el teléfono y aparecerá aquí.',
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
                onPressed: m.supports(16)
                    ? () => hub.mediaCmd(id, 'prev')
                    : null,
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
                    ? () => hub.mediaCmd(id, 'toggle')
                    : null,
              ),
              const SizedBox(width: Gap.xs),
              IconButton(
                tooltip: 'Siguiente',
                onPressed: m.supports(32)
                    ? () => hub.mediaCmd(id, 'next')
                    : null,
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
                      onChanged: m.supports(256)
                          ? (v) => setState(() => _seek = v)
                          : null,
                      onChangeEnd: (v) {
                        hub.mediaCmd(id, 'seek', position: v.round());
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
          if (m.volumeMax > 0)
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
                        hub.mediaCmd(id, 'volume', value: v.round());
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
        onPressed: () => hub.sendMessage(id, 'pb.x.media.request', {}),
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
