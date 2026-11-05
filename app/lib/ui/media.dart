import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

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
    this.compact = false,
  });
  final bool computer, hideInactive, compact;
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

    // Dashboard reference: an intentionally compact horizontal media card.
    // Uses the same real media state/commands as the expanded player.
    if (widget.compact) {
      final cm = m ?? MediaState(const {});
      final active = access && cm.active;
      return Panel(
        title: 'Reproductor',
        icon: Symbols.music_note_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (active)
              Row(
                children: [
                  _Art(cm, size: 64, appIcon: hub.appIcons[cm.pkg],
                       computer: widget.computer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(cm.title.isEmpty ? 'Sin título' : cm.title,
                            maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: t.titleSmall),
                        const SizedBox(height: 4),
                        Text([cm.artist, cm.app]
                            .where((x) => x.isNotEmpty).join(' · '),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: t.bodySmall?.copyWith(
                              color: s.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              )
            else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('No se está reproduciendo música.'),
              ),
            const SizedBox(height: 12),
            if (active) ...[
              Slider(
                padding: EdgeInsets.zero,
                value: (_seek ?? cm.positionNow.toDouble())
                    .clamp(0, cm.duration > 0 ? cm.duration.toDouble() : 1.0),
                max: cm.duration > 0 ? cm.duration.toDouble() : 1.0,
                onChanged: cm.duration > 0 && cm.supports(256)
                    ? (value) => setState(() => _seek = value) : null,
                onChangeEnd: (value) {
                  _command('seek', position: value.toInt());
                  setState(() => _seek = null);
                },
              ),
              Row(
                children: [
                  Text(_clock(cm.positionNow), style: t.labelSmall),
                  const Spacer(),
                  Text(_clock(cm.duration), style: t.labelSmall),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Anterior',
                  onPressed: active && cm.supports(16)
                      ? () => _command('prev') : null,
                  icon: const Icon(Symbols.skip_previous_rounded),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  iconSize: 27,
                  tooltip: active && cm.playing ? 'Pausar' : 'Reproducir',
                  onPressed: active ? () => _command('toggle') : null,
                  icon: Icon(active && cm.playing
                      ? Symbols.pause_rounded : Symbols.play_arrow_rounded),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Siguiente',
                  onPressed: active && cm.supports(32)
                      ? () => _command('next') : null,
                  icon: const Icon(Symbols.skip_next_rounded),
                ),
              ],
            ),
          ],
        ),
      );
    }

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
      final name =
          hub.peers.where((p) => p.id == id).firstOrNull?.name ?? '';
      final where = widget.computer
          ? 'En $name'
          : m.cast
          ? 'Transmitiendo desde $name'
          : 'En $name';
      final swap = motion(context, const Duration(milliseconds: 350));
      final thin = SliderTheme.of(context).copyWith(
        trackHeight: 6,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
        inactiveTrackColor: s.onSurface.withValues(alpha: 0.12),
      );
      Widget info({required bool center}) => Column(
        crossAxisAlignment: center
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Bars(playing: m.playing, color: s.primary),
              const SizedBox(width: Gap.s),
              Icon(
                widget.computer
                    ? Symbols.computer_rounded
                    : m.cast
                    ? Symbols.cast_rounded
                    : Symbols.smartphone_rounded,
                size: 16,
                color: s.primary,
              ),
              const SizedBox(width: Gap.xs),
              Flexible(
                child: Text(
                  where,
                  style: t.labelMedium?.copyWith(color: s.primary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.xs),
          // A new song slides in; the same song only updates in place.
          AnimatedSwitcher(
            duration: swap,
            transitionBuilder: (c, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.3),
                  end: Offset.zero,
                ).animate(a),
                child: c,
              ),
            ),
            layoutBuilder: (cur, prev) => Stack(
              alignment: center ? Alignment.center : Alignment.centerLeft,
              children: [...prev, ?cur],
            ),
            child: Column(
              key: ValueKey('${m.title}|${m.artist}'),
              crossAxisAlignment: center
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                Text(
                  m.title.isEmpty ? 'Sin título' : m.title,
                  style: weight(t.titleLarge, 600),
                  textAlign: center ? TextAlign.center : TextAlign.start,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  [
                    m.artist,
                    m.app,
                  ].where((x) => x.isNotEmpty).join(' · '),
                  style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
                  textAlign: center ? TextAlign.center : TextAlign.start,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      );
      final transport = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton.filledTonal(
            tooltip: 'Anterior',
            iconSize: 28,
            style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
            onPressed: m.supports(16) ? () => _command('prev') : null,
            icon: const Icon(Symbols.skip_previous_rounded, fill: 1),
          ),
          const SizedBox(width: Gap.m),
          MorphButton(
            icon: m.playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
            label: m.playing ? 'Pausar' : 'Reproducir',
            on: m.playing,
            size: 64,
            onPressed: m.supports(512 | (m.playing ? 2 : 4))
                ? () => _command('toggle')
                : null,
          ),
          const SizedBox(width: Gap.m),
          IconButton.filledTonal(
            tooltip: 'Siguiente',
            iconSize: 28,
            style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
            onPressed: m.supports(32) ? () => _command('next') : null,
            icon: const Icon(Symbols.skip_next_rounded, fill: 1),
          ),
        ],
      );
      final progress = m.duration <= 0
          ? null
          : Column(
              children: [
                SliderTheme(
                  data: thin,
                  child: Slider(
                    padding: EdgeInsets.zero,
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
                const SizedBox(height: Gap.xs),
                Row(
                  children: [
                    Text(
                      _clock(pos),
                      style: t.labelSmall?.copyWith(fontFeatures: tabular),
                    ),
                    const Spacer(),
                    Text(
                      _clock(m.duration),
                      style: t.labelSmall?.copyWith(fontFeatures: tabular),
                    ),
                  ],
                ),
              ],
            );
      final volume = widget.computer
          ? _pcVolume()
          : m.volumeMax <= 0
          ? null
          : Row(
              children: [
                Icon(
                  Symbols.volume_down_rounded,
                  size: 18,
                  color: s.onSurfaceVariant,
                ),
                Expanded(
                  child: SliderTheme(
                    data: thin,
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
            );
      // Narrow panels (phones, a side column) stack a big cover over the text; wide ones put it beside.
      body = LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final art = _Art(
            m,
            size: w < 480 ? (w * 0.6).clamp(140.0, 260.0) : (w * 0.24).clamp(96.0, 168.0),
            appIcon: hub.appIcons[m.pkg],
            computer: widget.computer,
          );
          if (w < 480) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Gap.s),
                Center(child: art),
                const SizedBox(height: Gap.l),
                info(center: true),
                const SizedBox(height: Gap.l),
                ?progress,
                const SizedBox(height: Gap.s),
                transport,
                if (volume != null) ...[const SizedBox(height: Gap.s), volume],
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  art,
                  const SizedBox(width: Gap.xl),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        info(center: false),
                        const SizedBox(height: Gap.m),
                        ?progress,
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.m),
              transport,
              if (volume != null) ...[const SizedBox(height: Gap.s), volume],
            ],
          );
        },
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
        child: m?.art == null || !m!.active
            ? body
            : Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(Radii.tile),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // The actual cover fills the complete player, like
                          // Android's expanded media controls. Never stretch it.
                          AnimatedSwitcher(
                            duration: motion(
                              context,
                              const Duration(milliseconds: 600),
                            ),
                            child: Image.memory(
                              m.art!,
                              key: ValueKey('${m.title}|${m.artist}'),
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              gaplessPlayback: true,
                              excludeFromSemantics: true,
                            ),
                          ),
                          // Keep controls and metadata readable in light/dark
                          // themes; do not blur away the entire artwork.
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  s.surface.withValues(alpha: 0.78),
                                  s.surface.withValues(alpha: 0.62),
                                  s.surface.withValues(alpha: 0.82),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  body,
                ],
              ),
      ),
    );
  }
}

/// Equalizer bars that dance while something plays and rest when it pauses.
class _Bars extends StatefulWidget {
  const _Bars({required this.playing, required this.color});
  final bool playing;
  final Color color;

  @override
  State<_Bars> createState() => _BarsState();
}

class _BarsState extends State<_Bars> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Bars old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final move = widget.playing && !MediaQuery.disableAnimationsOf(context);
    if (move && !_c.isAnimating) _c.repeat();
    if (!move) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: 18,
      height: 14,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < 4; i++)
              Container(
                width: 3,
                height: widget.playing
                    ? 4 +
                          10 *
                              (0.5 +
                                  0.5 *
                                      math.sin(
                                        _c.value * 2 * math.pi * (i.isEven ? 2 : 3) +
                                            i * 1.7,
                                      ))
                    : 4,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _Art extends StatelessWidget {
  const _Art(
    this.m, {
    required this.size,
    this.appIcon,
    this.computer = false,
  });
  final MediaState m;
  final double size;
  final Uint8List? appIcon;
  final bool computer;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final badge = size * 0.32;
    return SizedBox(
      width: size + badge * 0.25,
      height: size + badge * 0.25,
      child: Stack(
        children: [
          AnimatedScale(
            scale: m.playing ? 1 : 0.9,
            duration: motion(context, const Duration(milliseconds: 400)),
            curve: Curves.easeOutBack,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(size * 0.22),
              child: SizedBox(
                width: size,
                height: size,
                child: AnimatedSwitcher(
                  duration: motion(context, const Duration(milliseconds: 400)),
                  child: m.art != null
                      ? Image.memory(
                          m.art!,
                          key: ValueKey(m.title),
                          fit: BoxFit.cover,
                          width: size,
                          height: size,
                          gaplessPlayback: true,
                          semanticLabel: 'Portada',
                        )
                      : ColoredBox(
                          color: s.tertiaryContainer,
                          child: Center(
                            child: Icon(
                              Symbols.music_note_rounded,
                              size: size * 0.4,
                              color: s.onTertiaryContainer,
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
          // The app that plays it (the phone sends its icon; a computer shows a computer).
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: badge,
              height: badge,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: s.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: appIcon != null
                  ? ClipOval(
                      child: Image.memory(
                        appIcon!,
                        semanticLabel: m.app,
                        filterQuality: FilterQuality.medium,
                      ),
                    )
                  : Icon(
                      computer
                          ? Symbols.computer_rounded
                          : Symbols.music_note_rounded,
                      size: badge * 0.6,
                      color: s.onSurfaceVariant,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
