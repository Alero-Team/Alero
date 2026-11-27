import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Icon, Text;

import '../hub.dart';
import '../native.dart';
import 'expressive.dart' show motion, showAleroDialog;
import 'qollqe_motion.dart';
import 'theme.dart';
import 'widgets.dart';
import '../l10n.dart';

/// Before a send: which files are going and to whom, with a thumbnail for pictures. True means send.
Future<bool> showSendPreview(
  BuildContext context,
  List<Picked> files,
  String to,
) async =>
    await showAleroDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Enviar a {}', [to])),
        content: SizedBox(
          width: 380,
          child: files.length == 1
              ? _One(files.first)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final f in files.take(4)) _Row(f),
                    if (files.length > 4)
                      Padding(
                        padding: const EdgeInsets.only(top: Gap.s),
                        child: Text(
                          tr('y {} más ({} archivos)', [
                            files.length - 4,
                            files.length,
                          ]),
                          style: Theme.of(c).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Enviar'),
          ),
        ],
      ),
    ) ??
    false;

/// A picture that fades in once decoded instead of popping.
Widget _fadeIn(BuildContext context, Widget child, int? frame, bool sync) =>
    sync
    ? child
    : AnimatedOpacity(
        opacity: frame == null ? 0 : 1,
        duration: QollqeMotion.micro(context, Fluent.d250),
        curve: Fluent.enter,
        child: child,
      );

String _name(Picked f) =>
    f.name ?? f.path.replaceAll(r'\', '/').split('/').last;

/// Android hands over a descriptor (`fd:N`); /proc reopens the same file without moving its offset.
File _file(Picked f) => File(f.fd != null ? '/proc/self/fd/${f.fd}' : f.path);

String _size(Picked f) {
  try {
    return size(_file(f).lengthSync());
  } catch (_) {
    return '';
  }
}

class _One extends StatelessWidget {
  const _One(this.f);
  final Picked f;

  @override
  Widget build(BuildContext context) {
    final name = _name(f);
    final t = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (fileKind(name) == FileKind.image)
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.chip),
            child: Image.file(
              _file(f),
              height: 200,
              fit: BoxFit.contain,
              cacheHeight:
                  400, // decode small: a 50 MP photo must not stall the dialog
              frameBuilder: (c, child, frame, sync) =>
                  _fadeIn(c, child, frame, sync),
              errorBuilder: (_, _, _) => FileTile(name, size: 72),
            ),
          )
        else
          FileTile(name, size: 72),
        const SizedBox(height: Gap.m),
        Text(
          name,
          style: t.titleSmall,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Text(_size(f), style: t.bodySmall),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.f);
  final Picked f;

  @override
  Widget build(BuildContext context) {
    final name = _name(f);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: FileTile(name),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_size(f)),
    );
  }
}

/// After «Enviar»: the dialog of this send (see [showTransfer]).
void showSendProgress(BuildContext context, Hub hub, int count) =>
    showTransfer(context, hub, count: count);

/// A send or a reception, from start to end: each file's percentage while it moves, then «Finalizado» with a
/// preview of the file and what can be done with it. It stays until closed; «Ocultar» while files are still
/// moving leaves them in Actividad reciente.
Future<void> showTransfer(
  BuildContext context,
  Hub hub, {
  bool incoming = false,
  int count = 1,
  Set<String>? before,
}) {
  // Taken now, not in initState: a small file can start and end before the dialog's first frame.
  final old =
      before ??
      {for (final x in hub.active) x.id, for (final d in hub.ended) d.x.id};
  return showAleroDialog<void>(
    context: context,
    builder: (_) => _Transfer(hub, count, incoming, old),
  );
}

class _Transfer extends StatefulWidget {
  const _Transfer(this.hub, this.count, this.incoming, this.before);
  final Hub hub;
  final int count;
  final bool incoming;

  /// Transfers that were not started by this dialog's send.
  final Set<String> before;

  @override
  State<_Transfer> createState() => _TransferState();
}

class _TransferState extends State<_Transfer> {
  Timer? _idle, _gap;
  bool _settled = false;
  Hub get hub => widget.hub;

  bool _ours(Xfer x) =>
      x.incoming == widget.incoming &&
      !x.quiet &&
      !widget.before.contains(x.id);
  List<Xfer> get _mine => hub.active.where(_ours).toList();
  List<Ended> get _done => hub.ended.where((d) => _ours(d.x)).toList();

  @override
  void initState() {
    super.initState();
    hub.addListener(_check);
    // A send that never starts (refused, failed) must not leave the dialog open.
    _idle = Timer(const Duration(seconds: 15), () {
      if (_mine.isEmpty && _done.isEmpty) _close();
    });
  }

  /// Several files go one after another: «Finalizado» waits until no next one starts.
  void _check() {
    _gap?.cancel();
    if (_mine.isNotEmpty || _done.isEmpty) {
      _settled = false;
    } else if (!_settled) {
      _gap = Timer(Duration(milliseconds: widget.incoming ? 1200 : 4000), () {
        if (mounted) setState(() => _settled = true);
      });
    }
  }

  void _close() {
    if (!mounted) return;
    // Another dialog may sit on top by now: remove this one, not whatever is current.
    final r = ModalRoute.of(context);
    if (r == null || !r.isActive) return;
    r.isCurrent
        ? Navigator.of(context).pop()
        : Navigator.of(context).removeRoute(r);
  }

  @override
  void dispose() {
    _idle?.cancel();
    _gap?.cancel();
    hub.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hub,
    builder: (context, _) {
      final mine = _mine, done = _done;
      final finished =
          mine.isEmpty &&
          done.isNotEmpty &&
          (_settled || (!widget.incoming && done.length >= widget.count));
      final ok = done.where((d) => d.ok).toList();
      final last = ok.lastOrNull;
      // The store lists it a moment after the end; until then the buttons wait.
      final h = last == null
          ? null
          : hub.history.where((h) => h.id == last.x.id).firstOrNull;
      final onDisk =
          !isPhone &&
          h != null &&
          h.path.isNotEmpty &&
          File(h.path).existsSync();
      final total = mine.fold<int>(0, (n, x) => n + x.size);
      final flight = SendFlight(
        incoming: widget.incoming,
        progress: mine.isEmpty
            ? (done.isEmpty ? 0 : 1)
            : total == 0
            ? 0
            : mine.fold<int>(0, (n, x) => n + x.done) / total,
        done: finished,
        ok: ok.isNotEmpty,
      );
      final t = Theme.of(context).textTheme;
      final peer = (done.lastOrNull?.x ?? mine.firstOrNull)?.peerName ?? '';
      final many = widget.count > 1 || done.length + mine.length > 1;
      return AlertDialog(
        title: MotionFade(
          child: Text(
            finished && ok.isNotEmpty
                ? (widget.incoming
                      ? tr('Recibido de {}', [peer])
                      : tr('Enviado a {}', [peer]))
                : widget.incoming
                ? tr('Recibiendo de {}', [peer])
                : many
                ? tr('Enviando {} archivos', [widget.count])
                : 'Enviando archivo',
            key: ValueKey('$finished|$peer|${widget.incoming}|$many'),
          ),
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              flight,
              // The height follows the swap between moving, waiting and finished.
              AnimatedSize(
                alignment: Alignment.topCenter,
                duration: QollqeMotion.micro(context, Fluent.d250),
                curve: Fluent.enter,
                child: MotionSwitch(
                  axis: Axis.vertical,
                  child: KeyedSubtree(
                    key: ValueKey(
                      finished
                          ? 'done'
                          : mine.isEmpty
                          ? 'wait'
                          : 'moving',
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (finished) ...[
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              ok.length == done.length
                                  ? 'Finalizado'
                                  : ok.isEmpty
                                  ? done.last.error
                                  : tr('{} de {} finalizados', [
                                      ok.length,
                                      done.length,
                                    ]),
                              style: t.titleMedium,
                            ),
                          ),
                          if (last != null) ...[
                            const SizedBox(height: Gap.m),
                            _Arrived(last, onDisk ? h.path : null),
                            if (ok.length > 1)
                              Text(
                                tr('y {} más', [ok.length - 1]),
                                style: t.bodySmall,
                              ),
                          ],
                        ] else if (mine.isEmpty) ...[
                          const SizedBox(height: Gap.s),
                          Text(
                            done.isEmpty ? 'Preparando…' : 'Siguiente archivo…',
                          ),
                        ] else ...[
                          MotionList(
                            children: [
                              for (final x in mine.take(3))
                                TransferRow(x, hub, key: ValueKey(x.id)),
                            ],
                          ),
                          if (mine.length > 3)
                            Text(
                              tr('y {} más en curso', [mine.length - 3]),
                              style: t.bodySmall,
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: MotionFade(
              child: Text(
                finished ? 'Cerrar' : 'Ocultar',
                key: ValueKey(finished),
              ),
            ),
          ),
          if (finished && last != null) ...[
            if (onDisk && Platform.isWindows)
              TextButton(
                onPressed: () => hub.copyFile(h.path),
                child: const Text('Copiar'),
              ),
            if (onDisk)
              TextButton(
                onPressed: () => Native.showInFolder(h.path),
                child: const Text('Ver en carpeta'),
              )
            else if (isPhone && widget.incoming)
              TextButton(
                onPressed: hub.openDownloads,
                child: const Text('Ver en Descargas'),
              ),
            FilledButton(
              onPressed: h == null ? null : () => hub.openHistory(h),
              child: const Text('Abrir'),
            ),
          ],
        ],
      );
    },
  );
}

/// The file that just arrived or left: its picture when it is one, its type's tile otherwise.
class _Arrived extends StatelessWidget {
  const _Arrived(this.d, this.path);
  final Ended d;

  /// Where it is on this computer; null on the phone or when it is gone.
  final String? path;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final name = d.x.name;
    final tile = FileTile(name, size: 72);
    final image = d.picture != null
        ? Image.memory(
            d.picture!,
            height: 200,
            fit: BoxFit.contain,
            cacheHeight: 400,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => tile,
          )
        : path != null && fileKind(name) == FileKind.image
        ? Image.file(
            File(path!),
            height: 200,
            fit: BoxFit.contain,
            cacheHeight: 400,
            frameBuilder: (c, child, frame, sync) =>
                _fadeIn(c, child, frame, sync),
            errorBuilder: (_, _, _) => tile,
          )
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (image != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.chip),
            child: image,
          )
        else
          tile,
        const SizedBox(height: Gap.s),
        Text(
          name,
          style: t.titleSmall,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Text(size(d.x.size), style: t.bodySmall),
      ],
    );
  }
}

/// The send, drawn as Alero Island draws it: the device that receives (the phone, or the computer) fills like
/// a glass as the bytes arrive, its surface rippling; on arrival a tick (or a cross) pops on the full screen.
/// Before the first byte an arrow bobs on the empty screen. Still (no ripple, bob or hop) when the system asks
/// for reduced motion. The island's card (daemon/src/island/airdrop.rs) is the same drawing: keep them in step.
class SendFlight extends StatefulWidget {
  const SendFlight({
    super.key,
    required this.progress,
    required this.done,
    this.incoming = false,
    this.ok = true,
  });

  /// The files come to this device (it is the one drawn); otherwise the other device is.
  final bool incoming;

  /// With [done]: it arrived (a tick) or it did not (a cross).
  final bool ok;

  /// 0..1 of everything being sent.
  final double progress;
  final bool done;

  @override
  State<SendFlight> createState() => _SendFlightState();
}

class _SendFlightState extends State<SendFlight> with TickerProviderStateMixin {
  late final _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  late final _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  bool get _still => MediaQuery.of(context).disableAnimations;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SendFlight old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.done) {
      _wave.stop();
      if (_still) {
        _pop.value = 1;
      } else if (_pop.value == 0 && !_pop.isAnimating) {
        _pop.forward();
      }
      return;
    }
    _pop.value = 0;
    if (_still) {
      _wave.stop();
    } else if (!_wave.isAnimating) {
      _wave.repeat();
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    // Sending from the computer or receiving on the phone: the phone fills; otherwise the computer does.
    final phone = widget.incoming == isPhone;
    return Semantics(
      label: widget.done
          ? 'Transferencia terminada'
          : widget.incoming
          ? 'Recibiendo'
          : 'Enviando',
      child: SizedBox(
        height: 112,
        width: double.infinity,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: widget.progress.clamp(0, 1).toDouble()),
          duration: motion(context, const Duration(milliseconds: 450)),
          curve: Curves.easeOutCubic,
          builder: (_, v, _) => RepaintBoundary(
            child: CustomPaint(
              painter: _Glass(
                _wave,
                _pop,
                v,
                phone: phone,
                done: widget.done,
                ok: widget.ok,
                still: _still,
                ink: s.onSurface,
                accent: widget.ok ? s.primary : s.error,
                on: widget.ok ? s.onPrimary : s.onError,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Glass extends CustomPainter {
  _Glass(
    this.wave,
    this.pop,
    this.progress, {
    required this.phone,
    required this.done,
    required this.ok,
    required this.still,
    required this.ink,
    required this.accent,
    required this.on,
  }) : super(repaint: Listenable.merge([wave, pop]));
  final Animation<double> wave, pop;
  final double progress;
  final bool phone, done, ok, still;
  final Color ink, accent, on;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2);
    final p = pop.value;
    // The arrival makes it hop once.
    if (done && !still) canvas.scale(1 + .08 * math.sin(p * math.pi));
    final (body, screen) = phone
        ? (
            RRect.fromLTRBR(-24, -42, 24, 42, const Radius.circular(11)),
            RRect.fromLTRBR(-20, -38, 20, 38, const Radius.circular(8)),
          )
        : (
            RRect.fromLTRBR(-46, -38, 46, 22, const Radius.circular(8)),
            RRect.fromLTRBR(-42, -34, 42, 18, const Radius.circular(5)),
          );
    canvas.drawRRect(screen, Paint()..color = accent.withValues(alpha: .12));
    final level = done ? 1.0 : progress;
    if (level > 0) {
      final r = screen.outerRect;
      final y = r.bottom - r.height * level;
      final amp = done || still ? 0.0 : 2.4;
      final t = wave.value * 2 * math.pi;
      final glass = Path()..moveTo(r.left - 2, r.bottom + 2);
      for (var x = r.left - 2; x <= r.right + 2; x += 2) {
        glass.lineTo(x, y + math.sin(x / 5 + t) * amp);
      }
      glass
        ..lineTo(r.right + 2, r.bottom + 2)
        ..close();
      canvas
        ..save()
        ..clipRRect(screen)
        ..drawPath(glass, Paint()..color = accent)
        ..restore();
    }
    final pen = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(body, pen);
    if (phone) {
      canvas.drawRRect(
        RRect.fromLTRBR(-6, -38, 6, -34.6, const Radius.circular(1.7)),
        Paint()..color = ink,
      );
    } else {
      canvas
        ..drawLine(const Offset(0, 22), const Offset(0, 34), pen)
        ..drawLine(const Offset(-16, 34), const Offset(16, 34), pen);
    }
    final c = screen.center;
    // Before the first byte: "it goes in here".
    if (!done && progress <= 0) {
      final b = still ? 0.0 : math.sin(wave.value * 2 * math.pi * 1.1) * 3;
      final arrow = Path()
        ..moveTo(c.dx, c.dy - 12 + b)
        ..lineTo(c.dx, c.dy + 10 + b)
        ..moveTo(c.dx - 8, c.dy + 3 + b)
        ..lineTo(c.dx, c.dy + 11 + b)
        ..lineTo(c.dx + 8, c.dy + 3 + b);
      canvas.drawPath(
        arrow,
        Paint.from(pen)
          ..color = accent
          ..strokeWidth = 2.6,
      );
    }
    if (done && p > 0) {
      final k = 30 * Curves.easeOutBack.transform(p);
      final mark = ok
          ? (Path()
              ..moveTo(c.dx - .32 * k, c.dy + .02 * k)
              ..lineTo(c.dx - .08 * k, c.dy + .26 * k)
              ..lineTo(c.dx + .34 * k, c.dy - .24 * k))
          : (Path()
              ..moveTo(c.dx - .24 * k, c.dy - .24 * k)
              ..lineTo(c.dx + .24 * k, c.dy + .24 * k)
              ..moveTo(c.dx + .24 * k, c.dy - .24 * k)
              ..lineTo(c.dx - .24 * k, c.dy + .24 * k));
      canvas.drawPath(
        mark,
        Paint.from(pen)
          ..color = on.withValues(alpha: p.clamp(0, 1).toDouble())
          ..strokeWidth = .14 * k,
      );
    }
  }

  @override
  bool shouldRepaint(_Glass old) =>
      old.progress != progress ||
      old.done != done ||
      old.ok != ok ||
      old.phone != phone ||
      old.still != still ||
      old.ink != ink ||
      old.accent != accent ||
      old.on != on;
}
