import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Icon;
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../remote.dart';
import 'expressive.dart';
import 'theme.dart';
import 'widgets.dart';
import 'icon.dart';

String ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'ahora';
  if (d.inHours < 1) return 'hace ${d.inMinutes} min';
  if (d.inDays < 1) return 'hace ${d.inHours} h';
  return 'hace ${d.inDays} d';
}

/// Full notifications destination for the desktop sidebar.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen(this.hub, {super.key});
  final Hub hub;

  @override
  Widget build(BuildContext context) {
    final peer = hub.peers.where((p) => p.trusted).firstOrNull;
    final list = peer == null
        ? const <PhoneNotif>[]
        : hub.notifs[peer.id] ?? const <PhoneNotif>[];
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Notificaciones',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          if (peer == null)
            const Text('Conecta tu teléfono para ver las notificaciones.')
          else ...[
            Row(
              children: [
                Expanded(child: Text('Notificaciones de ${peer.name}')),
                TextButton.icon(
                  onPressed: () => hub.clearNotifs(peer.id),
                  icon: const Icon(Symbols.clear_all_rounded),
                  label: const Text('Borrar todas'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (list.isEmpty)
              const Text('No hay notificaciones recientes.')
            else
              for (final n in list)
                _NotifRow(hub, peer.id, n, key: ValueKey((peer.id, n.key))),
          ],
        ],
      ),
    );
  }
}

/// The phone's notifications, newest first: a panel on Home with the latest few and "Ver todas".
class NotificationsPanel extends StatelessWidget {
  const NotificationsPanel(this.hub, this.peerId, {super.key});
  final Hub hub;
  final String peerId;

  static const _shown = 3;

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
      body = Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Todo al día: no hay notificaciones en el teléfono.',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    } else {
      body = Column(
        children: [
          for (final n in list.take(_shown))
            _NotifRow(hub, peerId, n, key: ValueKey((peerId, n.key))),
        ],
      );
    }
    return Panel(
      title: 'Notificaciones',
      icon: Symbols.notifications_rounded,
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (list.isNotEmpty)
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _AllDialog(hub, peerId),
              ),
              child: Text('Ver todas (${list.length})'),
            ),
          if (list.any((n) => n.clearable))
            IconButton(
              tooltip: 'Borrar todas',
              icon: const Icon(Symbols.clear_all_rounded),
              onPressed: () => hub.clearNotifs(peerId),
            ),
        ],
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

/// Unsent replies by (phone, notification): the row is rebuilt when the window switches layout, the list
/// refreshes or the "Ver todas" dialog opens, and a long reply must not be lost on the way.
final _drafts = <(String, String), String>{};

/// Tests start from no drafts.
@visibleForTesting
void clearReplyDrafts() => _drafts.clear();

class _NotifRowState extends State<_NotifRow> {
  late final _text = TextEditingController(text: _drafts[_draftKey] ?? '');
  bool _sending = false;
  bool _open = false;
  late bool _replying = _text.text.isNotEmpty;
  String? _status;
  Hub get hub => widget.hub;
  String get peerId => widget.peerId;
  PhoneNotif get n => widget.n;
  (String, String) get _draftKey => (widget.peerId, widget.n.key);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _reply() async {
    if (_sending || _text.text.trim().isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _sending = true;
      _status = 'Enviando…';
    });
    try {
      await hub.replyNotif(peerId, n.key, _text.text);
      _drafts.remove(_draftKey);
      // Answered: the notification has done its job, so it leaves the phone and this list.
      unawaited(hub.dismissNotif(peerId, n.key));
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Respuesta enviada${n.title.isEmpty ? '' : ' a ${n.title}'}',
          ),
        ),
      );
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _status =
              'Sin confirmación del teléfono. Revisa el chat antes de repetir.',
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

  // Compact card: picture with the app badge, sender and «app · when» on one line, the latest messages
  // underneath, and the actions as small icons. Sizes follow the window's short side, so the card keeps
  // its proportion on a laptop and on a large monitor.
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final k = (MediaQuery.sizeOf(context).shortestSide / 900).clamp(0.8, 1.0);
    final avatar = 36 * k;
    final appIcon = hub.appIcons[n.pkg];
    final muted = t.labelSmall?.copyWith(
      color: s.onSurfaceVariant,
      fontWeight: FontWeight.w400,
    );
    Widget round(Uint8List? bytes, double side) => ClipOval(
      child: bytes != null
          ? Image.memory(
              bytes,
              width: side,
              height: side,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            )
          : Container(
              width: side,
              height: side,
              color: s.secondaryContainer,
              child: Icon(
                Symbols.notifications_rounded,
                size: side / 2,
                color: s.onSecondaryContainer,
              ),
            ),
    );
    Widget tool(IconData icon, String tip, VoidCallback onTap) => IconButton(
      tooltip: tip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints.tight(Size.square(32 * k)),
      padding: EdgeInsets.zero,
      iconSize: 18 * k,
      color: s.onSurfaceVariant,
      icon: Icon(icon),
    );
    // What others wrote, oldest first; a notification that is not a chat has only its text.
    final lines = [
      for (final m in n.messages)
        if (!m.out && m.body.isNotEmpty)
          m.sender.isEmpty || m.sender == n.title
              ? m.body
              : '${m.sender}: ${m.body}',
    ];
    if (lines.isEmpty && n.text.isNotEmpty) lines.add(n.text);
    final keep = _open ? 6 : 2;
    final shown = lines.skip((lines.length - keep).clamp(0, lines.length));
    final canReply = Platform.isWindows && n.replyable;
    final title = n.title.isNotEmpty ? n.title : n.app;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: s.surfaceContainer,
        borderRadius: BorderRadius.circular(Radii.card),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: lines.length > keep || _open
              ? () => setState(() => _open = !_open)
              : null,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              Gap.m * k,
              Gap.s * k,
              Gap.xs,
              Gap.s * k,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: SizedBox.square(
                          dimension: avatar,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              round(n.avatar ?? appIcon, avatar),
                              if (n.avatar != null && appIcon != null)
                                Positioned(
                                  right: -2,
                                  bottom: -2,
                                  child: Container(
                                    padding: const EdgeInsets.all(1.5),
                                    decoration: BoxDecoration(
                                      color: s.surfaceContainer,
                                      shape: BoxShape.circle,
                                    ),
                                    child: round(appIcon, avatar * 0.38),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: Gap.m * k),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  style: t.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: Gap.s),
                              Flexible(
                                child: Text(
                                  [
                                    if (n.title.isNotEmpty && n.app.isNotEmpty)
                                      n.app,
                                    ago(n.time),
                                    if (lines.length > 1)
                                      '${lines.length} mensajes',
                                  ].join(' · '),
                                  style: muted,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          for (final line in shown)
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Text(
                                line,
                                style: t.bodyMedium?.copyWith(
                                  color: s.onSurfaceVariant,
                                ),
                                maxLines: _open ? 4 : 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (canReply)
                      tool(
                        _replying
                            ? Symbols.close_rounded
                            : Symbols.reply_rounded,
                        _replying ? 'Cerrar respuesta' : 'Responder',
                        () => setState(() => _replying = !_replying),
                      ),
                    if (n.markable || n.clearable)
                      tool(
                        Symbols.done_rounded,
                        'Marcar como leído',
                        () => hub.notifAction(peerId, n, 'read'),
                      ),
                    PopupMenuButton<String>(
                      tooltip: 'Más opciones',
                      iconSize: 18 * k,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 200),
                      style: IconButton.styleFrom(
                        minimumSize: Size.square(32 * k),
                        fixedSize: Size.square(32 * k),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: Icon(
                        Symbols.more_vert_rounded,
                        color: s.onSurfaceVariant,
                      ),
                      onSelected: (a) => a == 'dismiss'
                          ? hub.dismissNotif(peerId, n.key)
                          : hub.notifAction(peerId, n, a),
                      itemBuilder: (_) => [
                        if (n.clearable)
                          const PopupMenuItem(
                            value: 'dismiss',
                            child: Text('Descartar en el teléfono'),
                          ),
                        if (n.mutable)
                          const PopupMenuItem(
                            value: 'mute',
                            child: Text('Silenciar conversación'),
                          ),
                        PopupMenuItem(
                          value: 'muteApp',
                          child: Text(
                            'Silenciar ${n.app.isEmpty ? 'esta app' : n.app} en el ordenador',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (canReply && _replying)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      avatar + Gap.m * k,
                      Gap.s,
                      Gap.s,
                      0,
                    ),
                    // Enter sends; Shift+Enter is a line break (the field's own behaviour).
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.enter): _reply,
                        const SingleActivator(LogicalKeyboardKey.numpadEnter):
                            _reply,
                      },
                      // No maxLength: the phone and the messaging app set the real limits.
                      child: TextField(
                        controller: _text,
                        autofocus: true,
                        readOnly: _sending,
                        minLines: 1,
                        maxLines: 5,
                        style: t.bodyMedium,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: s.surfaceContainerHighest,
                          hintText:
                              'Responder${n.title.isEmpty ? '' : ' a ${n.title}'}',
                          contentPadding: const EdgeInsets.fromLTRB(
                            14,
                            10,
                            4,
                            10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(Radii.card),
                            borderSide: BorderSide.none,
                          ),
                          suffixIcon: IconButton(
                            tooltip: 'Enviar respuesta',
                            iconSize: 18,
                            color: s.primary,
                            onPressed: _sending || _text.text.trim().isEmpty
                                ? null
                                : _reply,
                            icon: _sending
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Symbols.send_rounded),
                          ),
                        ),
                        onChanged: (v) {
                          _drafts[_draftKey] = v;
                          setState(() {});
                        },
                      ),
                    ),
                  ),
                if (_status != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      avatar + Gap.m * k,
                      Gap.xs,
                      Gap.s,
                      0,
                    ),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(_status!, style: muted),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
