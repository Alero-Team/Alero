import 'dart:async';

import 'package:flutter/foundation.dart';

import 'hub.dart';
import 'remote.dart';

class SmsThread {
  SmsThread(Map j)
    : id = (j['thread'] as num?)?.toInt() ?? -1,
      name = j['name'] as String? ?? '',
      addresses = [for (final a in (j['addresses'] as List? ?? [])) '$a'],
      snippet = j['snippet'] as String? ?? '',
      date = DateTime.fromMillisecondsSinceEpoch(
        (j['date'] as num?)?.toInt() ?? 0,
      ),
      read = j['read'] != false;
  final int id;
  final String name, snippet;
  final List<String> addresses;
  final DateTime date;
  final bool read;
  bool get group => addresses.length > 1;
}

/// The computer's side of the phone's SMS and MMS (`pb.x.sms.*`). It only asks; the phone decides and sends.
class SmsClient extends ChangeNotifier {
  SmsClient(this.hub);
  final Hub hub;

  String? peerId;
  List<SmsThread> threads = [];
  final messages = <int, List<ChatMsg>>{};
  bool loading = false;

  /// null, or why the phone does not answer: not_allowed, no_permission, offline.
  String? error;
  int? open;
  Timer? _timeout, _debounce;
  final _sends = <String, Completer<void>>{};
  int _next = 0;

  /// Called on every hub change: for the same phone it must never wipe what is on screen (an open chat vanished
  /// mid-typing), only retry once the phone stopped answering.
  void start(String peer) {
    if (peerId == peer) {
      if (error == 'offline' && !loading) refresh();
      return;
    }
    peerId = peer;
    threads = [];
    messages.clear();
    error = null;
    refresh();
  }

  void close() {
    _timeout?.cancel();
    _debounce?.cancel();
    peerId = null;
    open = null;
    threads = [];
    messages.clear();
    error = null;
    loading = false;
  }

  void refresh() {
    if (peerId == null) return;
    loading = true;
    hub.sendMessage(peerId!, 'pb.x.sms.threads.request', {});
    if (open != null) {
      hub.sendMessage(peerId!, 'pb.x.sms.thread', {'thread': open});
    }
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 8), () {
      if (!loading) return;
      loading = false;
      error ??= 'offline';
      notifyListeners();
    });
    notifyListeners();
  }

  void select(int thread) {
    open = thread;
    hub.sendMessage(peerId!, 'pb.x.sms.thread', {'thread': thread});
    notifyListeners();
  }

  /// Completes when the phone handed the text to Android; throws a StateError with the reason otherwise.
  Future<void> send(int thread, String text) {
    final request = '${_next++}';
    final done = _sends[request] = Completer<void>();
    hub.sendMessage(peerId!, 'pb.x.sms.send', {
      'thread': thread,
      'text': text,
      'request': request,
    });
    return done.future
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('sin respuesta'),
        )
        .whenComplete(() => _sends.remove(request));
  }

  static String sendError(String? e) => switch (e) {
    'group' => 'Los grupos necesitan MMS: solo la app de mensajes del teléfono puede enviarlos.',
    'no_permission' => 'Falta el permiso para enviar SMS en el teléfono.',
    'no_thread' => 'La conversación ya no existe en el teléfono.',
    'empty' => 'El mensaje está vacío.',
    _ => 'El teléfono no pudo enviar el SMS.',
  };

  void onMessage(String peer, String kind, Map<String, dynamic> b) {
    if (peer != peerId) return;
    switch (kind) {
      case 'pb.x.sms.threads':
        _timeout?.cancel();
        loading = false;
        error = null;
        threads = [
          for (final t in (b['items'] as List? ?? []))
            if (t is Map) SmsThread(t),
        ];
      case 'pb.x.sms.messages':
        final id = (b['thread'] as num?)?.toInt();
        if (id == null) return;
        messages[id] = [
          for (final m in (b['items'] as List? ?? []))
            if (m is Map) ChatMsg.fromSms(m),
        ];
      case 'pb.x.sms.sent':
        final done = _sends[b['request'] as String? ?? ''];
        if (done == null || done.isCompleted) return;
        b['ok'] == true
            ? done.complete()
            : done.completeError(StateError(sendError(b['error'] as String?)));
        return;
      case 'pb.x.sms.denied':
        _timeout?.cancel();
        loading = false;
        error = b['reason'] as String? ?? 'not_allowed';
      case 'pb.x.sms.changed':
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 500), refresh);
        return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
