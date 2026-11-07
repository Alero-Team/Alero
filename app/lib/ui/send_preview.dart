import 'dart:io';

import 'package:flutter/material.dart';

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
