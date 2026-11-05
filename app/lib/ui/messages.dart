import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../remote.dart';
import '../sms_client.dart';
import '../src/rust/api/engine.dart' as pb;
import 'call_bar.dart';
import 'notifications.dart' show ago;
import 'theme.dart';
import 'widgets.dart';

/// One row of the unified inbox: an SMS/MMS conversation from the phone's store, or a messaging app's
/// conversation as its notification shows it (only while that notification is on the phone).
class Convo {
  Convo.sms(SmsThread t)
    : key = 'sms:${t.id}',
      title = t.name.isNotEmpty ? t.name : t.addresses.join(', '),
      snippet = t.snippet,
      time = t.date,
      unread = !t.read,
      source = 'SMS',
      thread = t,
      notif = null;
  Convo.app(PhoneNotif n)
    : key = 'app:${n.key}',
      title = n.conversation.isNotEmpty ? n.conversation : n.title,
      snippet = n.messages.isNotEmpty ? n.messages.last.body : n.text,
      time = n.time,
      unread = true,
      source = n.app,
      thread = null,
      notif = n;
  final String key, title, snippet, source;
  final DateTime time;
  final bool unread;
  final SmsThread? thread;
  final PhoneNotif? notif;

  /// SMS threads and app chats together, newest first; [query] filters by name or text.
  static List<Convo> inbox(
    List<SmsThread> threads,
    List<PhoneNotif> notifs, [
    String query = '',
  ]) {
    final q = query.trim().toLowerCase();
    return [
          for (final t in threads) Convo.sms(t),
          for (final n in notifs.where((n) => n.chat)) Convo.app(n),
        ]
        .where(
          (c) =>
              q.isEmpty ||
              c.title.toLowerCase().contains(q) ||
              c.snippet.toLowerCase().contains(q),
        )
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
  }
}

class MessagesScreen extends StatefulWidget {
  const MessagesScreen(this.hub, {super.key});
  final Hub hub;

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  Hub get hub => widget.hub;
  SmsClient get sms => hub.sms;
  String? _open;
  final _search = TextEditingController();
  // Session-only snapshot of recent app conversations. Android is free to
  // withdraw a notification on reply; that must not erase a visible chat.
  // Never persist notification content or claim it is a full chat history.
  final _recentChats = <String, Convo>{};

  String? _lastPhone;

  /// The connected phone; during a brief drop, the same phone while it stays paired, so the open chat and the
  /// text being typed survive a reconnection.
  pb.Peer? get _phone {
    final live = hub.peers
        .where(
          (p) =>
              p.trusted &&
              p.state == pb.PeerState.connected &&
              hub.info[p.id]?.phone == true,
        )
        .firstOrNull;
    if (live != null) _lastPhone = live.id;
    return live ??
        hub.peers.where((p) => p.trusted && p.id == _lastPhone).firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    // After this frame: starting notifies listeners (the shell's badge), which cannot happen mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensure();
    });
    hub.addListener(_ensure);
  }

  @override
  void dispose() {
    hub.removeListener(_ensure);
    sms.close();
    _search.dispose();
    super.dispose();
  }

  void _ensure() {
    final p = _phone;
    if (p != null && hub.info[p.id]?.sms == true) sms.start(p.id);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([hub, sms]),
    builder: (context, _) {
      final t = Theme.of(context).textTheme;
      final phone = _phone;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xxl, Gap.xl, Gap.xxl, Gap.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text('Mensajes', style: t.headlineMedium),
                    ),
                  ),
                  if (phone != null && hub.info[phone.id]?.calls == true)
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.s),
                      child: FilledButton.tonalIcon(
                        onPressed: () => dialDialog(context, hub, phone.id),
                        icon: const Icon(Symbols.dialpad_rounded, size: 18),
                        label: const Text('Llamar'),
                      ),
                    ),
                  if (phone != null && hub.info[phone.id]?.sms == true)
                    IconButton(
                      tooltip: 'Actualizar',
                      onPressed: sms.refresh,
                      icon: const Icon(Symbols.refresh_rounded),
                    ),
                ],
              ),
              const SizedBox(height: Gap.l),
              Expanded(
                child: phone == null
                    ? const Align(
                        alignment: Alignment.topCenter,
                        child: EmptyState(
                          icon: Symbols.smartphone_rounded,
                          title: 'Conecta un teléfono',
                          body: 'Aquí verás sus SMS, MMS y los chats de sus apps de mensajería.',
                        ),
                      )
                    : _body(context, phone),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _body(BuildContext context, pb.Peer phone) {
    final s = Theme.of(context).colorScheme;
    final smsOn = hub.info[phone.id]?.sms == true;
    final live = Convo.inbox(
      smsOn ? sms.threads : const [],
      hub.notifs[phone.id] ?? const [],
    );
    for (final conversation in live.where((c) => c.notif != null)) {
      _recentChats.remove(conversation.key);
      _recentChats[conversation.key] = conversation;
    }
    while (_recentChats.length > 50) {
      _recentChats.remove(_recentChats.keys.first);
    }
    final all = <String, Convo>{
      for (final c in _recentChats.values) c.key: c,
      for (final c in live) c.key: c,
    };
    final q = _search.text.trim().toLowerCase();
    final list =
        all.values
            .where(
              (c) =>
                  q.isEmpty ||
                  c.title.toLowerCase().contains(q) ||
                  c.snippet.toLowerCase().contains(q),
            )
            .toList()
          ..sort((a, b) => b.time.compareTo(a.time));
    final open = all[_open];
    final notice = phone.state != pb.PeerState.connected
        ? 'El teléfono está sin conexión. Alero se reconecta solo.'
        : !smsOn
        ? 'Para ver los SMS, en el teléfono: Alero › Ajustes › Mensajes en el ordenador.'
        : switch (sms.error) {
            'no_permission' =>
              'Falta el permiso de SMS en el teléfono (Alero › Ajustes).',
            'offline' => 'El teléfono no responde.',
            null => null,
            _ => 'El teléfono no comparte sus SMS ahora mismo.',
          };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          SizedBox(
            width: 340,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(Gap.m),
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Buscar conversaciones',
                      prefixIcon: Icon(Symbols.search_rounded),
                    ),
                  ),
                ),
                if (notice != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
                    child: Text(
                      notice,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: s.onSurfaceVariant),
                    ),
                  ),
                if (sms.loading && sms.threads.isEmpty)
                  const LinearProgressIndicator(),
                Expanded(
                  child: list.isEmpty
                      ? Center(
                          child: Text(
                            _search.text.isEmpty
                                ? 'No hay conversaciones.'
                                : 'Nada coincide con la búsqueda.',
                            style: TextStyle(color: s.onSurfaceVariant),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Gap.s,
                          ),
                          itemCount: list.length,
                          itemBuilder: (_, i) => _ConvoRow(
                            hub,
                            list[i],
                            selected: list[i].key == _open,
                            onTap: () {
                              setState(() => _open = list[i].key);
                              final th = list[i].thread;
                              if (th != null) sms.select(th.id);
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
          VerticalDivider(width: 1, color: s.outlineVariant),
          Expanded(
            child: open == null
                ? const Center(
                    child: EmptyState(
                      card: false,
                      icon: Symbols.forum_rounded,
                      title: 'Elige una conversación',
                      body: 'Los SMS y MMS vienen del teléfono; los chats de apps, de sus notificaciones.',
                    ),
                  )
                : _Conversation(hub, phone.id, open, key: ValueKey(open.key)),
          ),
        ],
      ),
    );
  }
}

class _ConvoRow extends StatelessWidget {
  const _ConvoRow(
    this.hub,
    this.c, {
    required this.selected,
    required this.onTap,
  });
  final Hub hub;
  final Convo c;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final icon = c.notif == null ? null : hub.appIcons[c.notif!.pkg];
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? s.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.tile),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.tile),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: s.tertiaryContainer,
                  foregroundColor: s.onTertiaryContainer,
                  backgroundImage: icon == null ? null : MemoryImage(icon),
                  child: icon != null
                      ? null
                      : c.thread?.group == true
                      ? const Icon(Symbols.group_rounded, size: 20)
                      : Text(
                          c.title.isEmpty ? '#' : c.title.characters.first,
                          style: t.titleMedium?.copyWith(
                            color: s.onTertiaryContainer,
                          ),
                        ),
                ),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              c.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: c.unread
                                  ? t.titleSmall
                                  : weight(t.titleSmall, 500),
                            ),
                          ),
                          Text(
                            ago(c.time),
                            style: t.labelSmall?.copyWith(
                              color: s.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '${c.source} · ${c.snippet}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                      ),
                    ],
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

/// The open conversation: its messages as bubbles and a field to answer.
class _Conversation extends StatefulWidget {
  const _Conversation(this.hub, this.peerId, this.c, {super.key});
  final Hub hub;
  final String peerId;
  final Convo c;

  @override
  State<_Conversation> createState() => _ConversationState();
}

class _ConversationState extends State<_Conversation> {
  final _text = TextEditingController();
  bool _sending = false;
  String? _status;
  // Only responses acknowledged by Android; not a delivery receipt from
  // WhatsApp or another destination. Retained in this open conversation.
  final _localReplies = <ChatMsg>[];
  Convo get c => widget.c;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Why this conversation cannot be answered from here, or null.
  String? get _blocked {
    if (c.thread?.group == true) {
      return 'Los grupos se responden en el teléfono: Android solo deja enviar MMS a la app de mensajes predeterminada.';
    }
    if (c.notif != null) {
      final active =
          widget.hub.notifs[widget.peerId]?.any(
            (n) => n.key == c.notif!.key && n.replyable,
          ) ??
          false;
      if (!active) {
        return 'La notificación ya no permite responder. Puedes seguir leyendo lo disponible.';
      }
    }
    return null;
  }

  Future<void> _send() async {
    final text = _text.text;
    if (_sending || text.trim().isEmpty || _blocked != null) return;
    setState(() {
      _sending = true;
      _status = 'Enviando…';
    });
    try {
      if (c.thread != null) {
        await widget.hub.sms.send(c.thread!.id, text);
        _status = null;
      } else {
        await widget.hub.replyNotif(widget.peerId, c.notif!.key, text);
        _localReplies.add(ChatMsg(body: text, time: DateTime.now(), out: true));
        _status = 'Android entregó la respuesta a ${c.source}.';
      }
      _text.clear();
    } on TimeoutException {
      _status = 'Sin confirmación del teléfono. Comprueba la conversación antes de repetir.';
    } on StateError catch (e) {
      _status = e.message;
    } catch (_) {
      _status = 'No se pudo enviar.';
    }
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final List<ChatMsg>? msgs = c.thread != null
        ? widget.hub.sms.messages[c.thread!.id]
        : c.notif!.messages.isNotEmpty
        ? c.notif!.messages
        : [
            ChatMsg(
              body: c.notif!.text,
              time: c.notif!.time,
              out: false,
              sender: c.notif!.title,
            ),
          ];
    // MessagingStyle may already contain the outgoing response. Avoid
    // displaying the same message twice after an updated notification.
    final visibleMsgs = <ChatMsg>[
      ...?msgs,
      for (final reply in _localReplies)
        if (!(msgs?.any(
              (m) =>
                  m.out &&
                  m.body == reply.body &&
                  m.time.difference(reply.time).inSeconds.abs() < 20,
            ) ??
            false))
          reply,
    ];
    // A chat app names group conversations apart from the sender (title).
    final n = c.notif;
    final group =
        c.thread?.group == true ||
        (n != null && n.conversation.isNotEmpty && n.conversation != n.title);
    final blocked = _blocked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, Gap.s),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.title, style: t.titleLarge),
                    Text(
                      c.thread != null
                          ? c.thread!.addresses.join(', ')
                          : '${c.source} · solo los últimos mensajes de la notificación',
                      style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (c.thread != null &&
                  !c.thread!.group &&
                  widget.hub.info[widget.peerId]?.calls == true)
                IconButton.filledTonal(
                  tooltip: 'Llamar a ${c.title}',
                  onPressed: () => dialDialog(
                    context,
                    widget.hub,
                    widget.peerId,
                    c.thread!.addresses.first,
                  ),
                  icon: const Icon(Symbols.call_rounded),
                ),
            ],
          ),
        ),
        Divider(color: s.outlineVariant),
        Expanded(
          child: msgs == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(Gap.l),
                  itemCount: visibleMsgs.length,
                  itemBuilder: (_, i) => _Bubble(
                    visibleMsgs[visibleMsgs.length - 1 - i],
                    showSender: group,
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.l),
          child: blocked != null
              ? Text(
                  blocked,
                  style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          // Enter sends; Shift+Enter is a line break.
                          child: CallbackShortcuts(
                            bindings: {
                              const SingleActivator(LogicalKeyboardKey.enter):
                                  _send,
                              const SingleActivator(
                                LogicalKeyboardKey.numpadEnter,
                              ): _send,
                            },
                            child: TextField(
                              controller: _text,
                              readOnly: _sending,
                              minLines: 1,
                              maxLines: 5,
                              keyboardType: TextInputType.multiline,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                hintText: c.thread != null
                                    ? 'SMS'
                                    : 'Responder en ${c.source}',
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: Gap.s),
                        IconButton.filled(
                          style: IconButton.styleFrom(
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .onPrimary,
                          ),
                          tooltip: 'Enviar',
                          onPressed: _sending || _text.text.trim().isEmpty
                              ? null
                              : _send,
                          icon: const Icon(Symbols.send_rounded),
                        ),
                      ],
                    ),
                    if (_status != null)
                      Padding(
                        padding: const EdgeInsets.only(top: Gap.xs),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(_status!, style: t.bodySmall),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.m, {required this.showSender});
  final ChatMsg m;
  final bool showSender;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final fg = m.out ? s.onPrimary : s.onSurface;
    // Expressive: the corner toward the sender stays tight, the others round.
    const r = Radius.circular(20), tight = Radius.circular(6);
    return Align(
      alignment: m.out ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.l,
            vertical: Gap.s + 2,
          ),
          decoration: BoxDecoration(
            color: m.failed
                ? s.errorContainer
                : m.out
                ? s.primary
                : s.surfaceContainerHighest,
            borderRadius: BorderRadius.only(
              topLeft: r,
              topRight: r,
              bottomLeft: m.out ? r : tight,
              bottomRight: m.out ? tight : r,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showSender && !m.out && m.sender.isNotEmpty)
                Text(
                  m.sender,
                  style: t.labelMedium?.copyWith(color: s.tertiary),
                ),
              if (m.body.isNotEmpty)
                SelectableText(
                  m.body,
                  style: t.bodyMedium?.copyWith(color: fg),
                ),
              if (m.media > 0)
                Text(
                  '${m.media == 1 ? 'Un adjunto' : '${m.media} adjuntos'} (en el teléfono)',
                  style: t.bodySmall?.copyWith(
                    color: fg,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              Text(
                '${m.failed ? 'No enviado · ' : ''}${ago(m.time)}',
                style: t.labelSmall?.copyWith(color: fg.withValues(alpha: 0.7)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
