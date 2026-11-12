import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Icon;
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../native.dart';
import 'expressive.dart' show Spring, motion;
import 'icon.dart';
import 'theme.dart';
import 'widgets.dart';

/// Before a send: which files are going and to whom, with a thumbnail for pictures. True means send.
Future<bool> showSendPreview(
  BuildContext context,
  List<Picked> files,
  String to,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Enviar a $to'),
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
                          'y ${files.length - 4} más (${files.length} archivos)',
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
      {
        for (final x in hub.active) x.id,
        for (final d in hub.ended) d.x.id,
      };
  return showDialog<void>(
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
          !Platform.isAndroid &&
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
        title: Text(
          finished && ok.isNotEmpty
              ? (widget.incoming ? 'Recibido de $peer' : 'Enviado a $peer')
              : widget.incoming
              ? 'Recibiendo de $peer'
              : many
              ? 'Enviando ${widget.count} archivos'
              : 'Enviando archivo',
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              flight,
              if (finished) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    ok.length == done.length
                        ? 'Finalizado'
                        : ok.isEmpty
                        ? done.last.error
                        : '${ok.length} de ${done.length} finalizados',
                    style: t.titleMedium,
                  ),
                ),
                if (last != null) ...[
                  const SizedBox(height: Gap.m),
                  _Arrived(last, onDisk ? h.path : null),
                  if (ok.length > 1)
                    Text('y ${ok.length - 1} más', style: t.bodySmall),
                ],
              ] else if (mine.isEmpty) ...[
                const SizedBox(height: Gap.s),
                Text(done.isEmpty ? 'Preparando…' : 'Siguiente archivo…'),
              ] else ...[
                for (final x in mine.take(3))
                  TransferRow(x, hub, key: ValueKey(x.id)),
                if (mine.length > 3)
                  Text('y ${mine.length - 3} más en curso', style: t.bodySmall),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(finished ? 'Cerrar' : 'Ocultar'),
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
            else if (Platform.isAndroid && widget.incoming)
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

/// The send, drawn: this device on the left, the other on the right, and small dots travelling the line
/// between them while bytes move. The line fills with the progress; on arrival the other device becomes a
/// tick that lands with a spring. Still (line and tick only) when the system asks for reduced motion.
class SendFlight extends StatefulWidget {
  const SendFlight({
    super.key,
    required this.progress,
    required this.done,
    this.incoming = false,
    this.ok = true,
  });

  /// The files come to this device: the other one is drawn on the left.
  final bool incoming;

  /// With [done]: it arrived (a tick) or it did not (a cross).
  final bool ok;

  /// 0..1 of everything being sent.
  final double progress;
  final bool done;

  @override
  State<SendFlight> createState() => _SendFlightState();
}

class _SendFlightState extends State<SendFlight>
    with SingleTickerProviderStateMixin {
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
  void didUpdateWidget(SendFlight old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.done || MediaQuery.of(context).disableAnimations) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final here = Platform.isAndroid
        ? Symbols.smartphone_rounded
        : Symbols.computer_rounded;
    final there = Platform.isAndroid
        ? Symbols.computer_rounded
        : Symbols.smartphone_rounded;
    final (from, to) = widget.incoming ? (there, here) : (here, there);
    Widget device(IconData icon, {bool lit = false}) => AnimatedContainer(
      duration: motion(context, const Duration(milliseconds: 300)),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: !lit
            ? s.secondaryContainer
            : widget.ok
            ? s.primary
            : s.error,
        shape: BoxShape.circle,
      ),
      child: Icon(
        icon,
        size: 22,
        color: !lit
            ? s.onSecondaryContainer
            : widget.ok
            ? s.onPrimary
            : s.onError,
      ),
    );
    return Semantics(
      label: widget.done
          ? 'Transferencia terminada'
          : widget.incoming
          ? 'Recibiendo'
          : 'Enviando',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.s),
        child: Row(
          children: [
            device(from),
            Expanded(
              child: SizedBox(
                height: 44,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: widget.progress.clamp(0, 1).toDouble()),
                  duration: motion(context, const Duration(milliseconds: 450)),
                  curve: Curves.easeOutCubic,
                  builder: (_, v, _) => RepaintBoundary(
                    child: CustomPaint(
                      painter: _Flight(_c, v, s.primary, s.outlineVariant),
                    ),
                  ),
                ),
              ),
            ),
            // The arrival: the other device swaps for a tick that overshoots a little and settles.
            AnimatedSwitcher(
              duration: motion(context, const Duration(milliseconds: 420)),
              switchInCurve: Spring.fast,
              transitionBuilder: (child, a) =>
                  ScaleTransition(scale: a, child: child),
              child: widget.done
                  ? KeyedSubtree(
                      key: const ValueKey('done'),
                      child: device(
                        widget.ok
                            ? Symbols.check_rounded
                            : Symbols.close_rounded,
                        lit: true,
                      ),
                    )
                  : KeyedSubtree(
                      key: const ValueKey('going'),
                      child: device(to),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Flight extends CustomPainter {
  _Flight(this.phase, this.progress, this.color, this.track)
    : super(repaint: phase);
  final Animation<double> phase;
  final double progress;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 10.0;
    final y = size.height / 2, w = size.width - pad * 2;
    if (w <= 0) return;
    final line = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(pad, y), Offset(pad + w, y), line..color = track);
    if (progress > 0) {
      canvas.drawLine(
        Offset(pad, y),
        Offset(pad + w * progress, y),
        line..color = color,
      );
    }
    if (!phase.isAnimating) return;
    // Three dots, a third of the way apart; each grows out of the left end and melts into the right one.
    for (var i = 0; i < 3; i++) {
      final t = (phase.value + i / 3) % 1;
      final edge = math.sin(t * math.pi);
      canvas.drawCircle(
        Offset(pad + w * Curves.easeInOut.transform(t), y),
        2 + 3 * edge,
        Paint()..color = color.withValues(alpha: edge.clamp(0, 1).toDouble()),
      );
    }
  }

  @override
  bool shouldRepaint(_Flight old) =>
      old.progress != progress || old.color != color || old.track != track;
}
