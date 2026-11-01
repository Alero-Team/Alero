import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../remote.dart';
import 'expressive.dart';
import 'theme.dart';
import 'widgets.dart';

String ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'ahora';
  if (d.inHours < 1) return 'hace ${d.inMinutes} min';
  if (d.inDays < 1) return 'hace ${d.inHours} h';
  return 'hace ${d.inDays} d';
}

/// The phone's notifications, newest first: a panel on Home with the latest few and "Ver todas".
class NotificationsPanel extends StatelessWidget {
  const NotificationsPanel(this.hub, this.peerId, {super.key});
  final Hub hub;
  final String peerId;

  static const _shown = 4;

  @override
  Widget build(BuildContext context) {
    final list = hub.notifs[peerId] ?? const <PhoneNotif>[];
    final access = hub.info[peerId]?.notifAccess ?? false;
    final Widget body;
    if (!access) {
      body = const EmptyState(
        card: false,
        icon: Symbols.notifications_off_rounded,
        title: 'Falta un permiso en el teléfono',
        body: 'Se concede en los ajustes de Android y puedes retirarlo cuando quieras.',
      );
    } else if (list.isEmpty) {
      body = const EmptyState(
        card: false,
        icon: Symbols.notifications_rounded,
        title: 'Todo al día',
        body: 'No hay notificaciones en el teléfono.',
      );
    } else {
      body = Column(
        children: [
          for (final n in list.take(_shown))
            _NotifRow(hub, peerId, n, key: ValueKey((peerId, n.key))),
          if (list.length > _shown)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => _AllDialog(hub, peerId),
                ),
                child: Text('Ver todas (${list.length})'),
              ),
            ),
        ],
      );
    }
    return Panel(
      title: 'Notificaciones',
      icon: Symbols.notifications_rounded,
      action: list.any((n) => n.clearable)
          ? TextButton(
              onPressed: () => hub.clearNotifs(peerId),
              child: const Text('Borrar todas'),
            )
          : null,
      child: AnimatedSize(
        duration: motion(context, Spring.spatial.settle),
        curve: Spring.spatial,
        alignment: Alignment.topCenter,
        child: body,
      ),
    );
  }
}

class _AllDialog extends StatelessWidget {
  const _AllDialog(this.hub, this.peerId);
  final Hub hub;
  final String peerId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hub,
    builder: (context, _) {
      final list = hub.notifs[peerId] ?? const <PhoneNotif>[];
      return AlertDialog(
        title: const Text('Notificaciones'),
        content: SizedBox(
          width: 520,
          child: list.isEmpty
              ? const Text('No hay notificaciones.')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final n in list)
                      _NotifRow(hub, peerId, n, key: ValueKey((peerId, n.key))),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
        ],
      );
    },
  );
}

class _NotifRow extends StatefulWidget {
  const _NotifRow(this.hub, this.peerId, this.n, {super.key});
  final Hub hub;
  final String peerId;
  final PhoneNotif n;
  @override
  State<_NotifRow> createState() => _NotifRowState();
}

class _NotifRowState extends State<_NotifRow> {
  final _text = TextEditingController();
  bool _sending = false;
  String? _status;
  Hub get hub => widget.hub;
  String get peerId => widget.peerId;
  PhoneNotif get n => widget.n;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _reply() async {
    if (_sending || _text.text.trim().isEmpty) return;
    setState(() {
      _sending = true;
      _status = 'Enviando…';
    });
    try {
      await hub.replyNotif(peerId, n.key, _text.text);
      if (mounted) {
        setState(() {
          _status = 'Enviado al teléfono';
          _text.clear();
        });
      }
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _status =
              'Sin confirmación. Comprueba el teléfono antes de repetir.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _status = e is StateError
              ? e.message.toString()
              : 'No se pudo enviar la respuesta.',
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          hub.appIcons[n.pkg] != null
              ? ExcludeSemantics(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      hub.appIcons[n.pkg]!,
                      width: 36,
                      height: 36,
                      gaplessPlayback: true,
                    ),
                  ),
                )
              : Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: s.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: ExcludeSemantics(
                    child: Icon(
                      Symbols.notifications_rounded,
                      size: 20,
                      color: s.onSecondaryContainer,
                    ),
                  ),
                ),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${n.app} · ${ago(n.time)}',
                  style: t.labelSmall?.copyWith(color: s.onSurfaceVariant),
                ),
                if (n.title.isNotEmpty)
                  Text(
                    n.title,
                    style: t.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (n.text.isNotEmpty)
                  Text(
                    n.text,
                    style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (Platform.isWindows && n.replyable) ...[
                  const SizedBox(height: Gap.s),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          enabled: !_sending,
                          maxLength: 4000,
                          decoration: const InputDecoration(
                            labelText: 'Responder',
                            counterText: '',
                          ),
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _reply(),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Enviar respuesta',
                        onPressed: _sending || _text.text.trim().isEmpty
                            ? null
                            : _reply,
                        icon: const Icon(Symbols.send_rounded),
                      ),
                    ],
                  ),
                  if (_status != null)
                    Semantics(
                      liveRegion: true,
                      child: Text(_status!, style: t.bodySmall),
                    ),
                ],
              ],
            ),
          ),
          if (n.clearable)
            IconButton(
              tooltip: 'Descartar en el teléfono',
              icon: const Icon(Symbols.close_rounded, size: 18),
              onPressed: () => hub.dismissNotif(peerId, n.key),
            ),
        ],
      ),
    );
  }
}
