import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../hub.dart';
import '../native.dart';
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

/// After «Enviar»: a small dialog with each outgoing file's percentage and progress wave. It closes by
/// itself once every file of this send has finished; «Ocultar» leaves them running in Actividad reciente.
void showSendProgress(BuildContext context, Hub hub, int count) {
  showDialog<void>(context: context, builder: (_) => _SendProgress(hub, count));
}

class _SendProgress extends StatefulWidget {
  const _SendProgress(this.hub, this.count);
  final Hub hub;
  final int count;

  @override
  State<_SendProgress> createState() => _SendProgressState();
}

class _SendProgressState extends State<_SendProgress> {
  // Outgoing transfers already running before this send are not ours. Taken in initState: a lazy field
  // would first be read once this send's own file is in the list.
  late final Set<String> _before;
  final _seen = <String>{};
  Timer? _idle;
  bool _closed = false;

  List<Xfer> get _mine => widget.hub.active
      .where((x) => !x.incoming && !_before.contains(x.id))
      .toList();

  @override
  void initState() {
    super.initState();
    _before = {
      for (final x in widget.hub.active)
        if (!x.incoming) x.id,
    };
    widget.hub.addListener(_check);
    // A send that never starts (refused, failed) must not leave the dialog open.
    _idle = Timer(const Duration(seconds: 15), _close);
  }

  void _check() {
    final mine = _mine;
    _seen.addAll(mine.map((x) => x.id));
    _idle?.cancel();
    if (mine.isEmpty && _seen.isNotEmpty) {
      // Several files start one after another: wait briefly for the next before closing.
      _idle = Timer(
        Duration(milliseconds: _seen.length >= widget.count ? 700 : 4000),
        _close,
      );
    }
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    // Another dialog may sit on top by now: remove this one, not whatever is current.
    final r = ModalRoute.of(context);
    if (r == null || !r.isActive) return;
    r.isCurrent
        ? Navigator.of(context).pop()
        : Navigator.of(context).removeRoute(r);
  }

  @override
  void dispose() {
    _closed = true;
    _idle?.cancel();
    widget.hub.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.count == 1
          ? 'Enviando archivo'
          : 'Enviando ${widget.count} archivos',
    ),
    content: SizedBox(
      width: 420,
      child: ListenableBuilder(
        listenable: widget.hub,
        builder: (context, _) {
          final mine = _mine;
          if (mine.isEmpty) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: Gap.s),
                Text(_seen.isEmpty ? 'Preparando…' : 'Terminado'),
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final x in mine.take(3))
                TransferRow(x, widget.hub, key: ValueKey(x.id)),
              if (mine.length > 3)
                Text(
                  'y ${mine.length - 3} más en curso',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Ocultar'),
      ),
    ],
  );
}
