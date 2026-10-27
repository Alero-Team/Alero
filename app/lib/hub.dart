import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'native.dart';
import 'src/rust/api/engine.dart' as pb;

class Xfer {
  Xfer(this.id, this.peerName, this.name, this.size, this.incoming);
  final String id, peerName, name;
  final int size;
  final bool incoming;
  int done = 0, rate = 0;
  String note = '';
}

/// Single owner of what the UI shows. Mirrors engine events into plain state; no protocol or trust logic here.
class Hub extends ChangeNotifier {
  List<pb.Peer> peers = [];
  List<Xfer> active = [];
  List<pb.HistoryItem> history = [];
  List<String> diagnostics = [];
  pb.Event_PairRequest? pairPrompt;
  pb.Event_TransferOffer? offer;
  String myId = '', name = '', downloads = '', startError = '';
  bool autoAccept = true;
  final messages = StreamController<String>.broadcast();

  late File _settings;
  final _fds = <String, int>{}; // transfer id -> Android descriptor to close when it ends

  Future<void> start() async {
    final data = Directory('${(await getApplicationSupportDirectory()).path}/pb');
    final dl = Platform.isAndroid
        ? '${(await getApplicationSupportDirectory()).path}/incoming' // moved to Downloads by Native.publish
        : '${(await getDownloadsDirectory())!.path}${Platform.pathSeparator}Phonebridge';
    downloads = Platform.isAndroid ? 'Descargas/Phonebridge' : dl;
    _settings = File('${data.path}/settings.json');
    final s = _readSettings();
    name = s['name'] as String? ?? await Native.deviceName();
    autoAccept = s['autoAccept'] as bool? ?? true;
    pb.events().listen(_on);
    try {
      myId = await pb.start(
        config: pb.Config(
          dataDir: data.path,
          downloadDir: dl,
          name: name,
          port: pb.defaultPort(),
          discoveryPort: pb.defaultPort(),
          autoAccept: autoAccept,
        ),
      );
    } catch (e) {
      startError = 'No se pudo iniciar: $e';
    }
    await refresh();
  }

  Map<String, dynamic> _readSettings() {
    try {
      return jsonDecode(_settings.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  void _saveSettings() {
    _settings.parent.createSync(recursive: true);
    _settings.writeAsStringSync(jsonEncode({'name': name, 'autoAccept': autoAccept}));
  }

  Future<void> refresh() async {
    if (myId.isEmpty) return notifyListeners();
    peers = _sorted(await pb.peers());
    history = await pb.history();
    diagnostics = await pb.diagnostics();
    _status();
    notifyListeners();
  }

  List<pb.Peer> _sorted(List<pb.Peer> l) =>
      l..sort((a, b) => a.trusted != b.trusted ? (a.trusted ? -1 : 1) : a.name.compareTo(b.name));

  void _status() {
    final n = peers.where((p) => p.trusted && p.state == pb.PeerState.connected).length;
    Native.status(n == 0 ? 'Esperando dispositivos emparejados' : 'Conectado a $n dispositivo(s)');
  }

  void _on(pb.Event e) {
    switch (e) {
      case pb.Event_PeerChanged(:final peer):
        peers = _sorted([...peers.where((p) => p.id != peer.id), peer]);
        _status();
      case pb.Event_PeerGone(:final id):
        peers = peers.where((p) => p.id != id).toList();
        _status();
      case pb.Event_PairRequest():
        pairPrompt = e;
        Native.alert('Solicitud de emparejamiento', '${e.name} quiere emparejarse. Código ${e.code}');
      case pb.Event_PairFinished():
        pairPrompt = null;
        messages.add(e.ok
            ? 'Emparejado con ${e.name}'
            : switch (e.code) {
                'DECLINED' => 'Emparejamiento cancelado',
                'DECLINED_BY_PEER' => 'El otro dispositivo no aceptó el emparejamiento',
                _ => 'No se pudo emparejar: ${e.message}. Comprueba que ambos estén en la misma red.',
              });
        refresh();
      case pb.Event_TransferOffer():
        offer = e;
        Native.alert('Archivo entrante', '${e.peerName} quiere enviarte ${e.name}');
      case pb.Event_TransferStarted():
        if (offer?.id == e.id) offer = null;
        active = [...active, Xfer(e.id, e.peerName, e.name, e.size.toInt(), e.incoming)];
      case pb.Event_TransferProgress():
        for (final x in active.where((x) => x.id == e.id)) {
          x.done = e.done.toInt();
          x.rate = e.bytesPerSec.toInt();
          x.note = '';
        }
      case pb.Event_TransferNote():
        for (final x in active.where((x) => x.id == e.id)) {
          x.note = e.message;
        }
      case pb.Event_TransferFinished():
        _finished(e);
      case pb.Event_Log():
        return;
      case pb.Event_Show():
        Native.showWindow();
        return;
      case pb.Event_Quit():
        exit(0);
    }
    notifyListeners();
  }

  Future<void> _finished(pb.Event_TransferFinished e) async {
    final x = active.where((x) => x.id == e.id).firstOrNull;
    active = active.where((x) => x.id != e.id).toList();
    final fd = _fds.remove(e.id);
    if (fd != null) Native.closeFd(fd);
    var where = '';
    if (e.ok && x?.incoming == true && e.path.isNotEmpty) where = await Native.publish(e.path);
    final n = x?.name ?? 'archivo';
    messages.add(switch (e) {
      _ when e.ok && x?.incoming == true => 'Recibido: $n (${where.isEmpty ? downloads : where})',
      _ when e.ok => 'Enviado: $n',
      _ when e.code == 'CANCELLED' => 'Cancelado: $n',
      _ => 'Falló $n: ${explain(e.code, e.message)}',
    });
    if (e.ok && x?.incoming == true) Native.alert('Archivo recibido', n);
    await refresh();
  }

  /// Runs an engine call and turns its error into a message.
  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      messages.add('$e');
    }
  }

  Future<void> pair(String peerId) => _run(() => pb.pairWithPeer(peerId: peerId));
  Future<void> pairAddr(String addr) => _run(() => pb.pairWithAddr(addr: addr));

  Future<void> answerPair(bool accept) async {
    final p = pairPrompt;
    if (p == null) return;
    await _run(() => pb.respondPair(peerId: p.peerId, accept: accept));
    if (!accept) pairPrompt = null;
    notifyListeners();
  }

  Future<void> answerOffer(bool accept) async {
    final o = offer;
    if (o == null) return;
    offer = null;
    notifyListeners();
    await _run(() => pb.respondTransfer(id: o.id, accept: accept));
  }

  Future<void> forget(String peerId) => _run(() async {
        await pb.revoke(peerId: peerId);
        await refresh();
      });
  Future<void> cancel(String id) => _run(() => pb.cancelTransfer(id: id));
  Future<void> retry(String historyId) => _run(() => pb.retry(historyId: historyId));
  Future<void> clearHistory() => _run(() async {
        await pb.clearHistory();
        await refresh();
      });

  /// Desktop: real paths. Android: picks content URIs and sends their descriptors (no copy).
  Future<void> send(String peerId) async {
    for (final f in await Native.pickFiles()) {
      try {
        final id = await pb.sendFile(peerId: peerId, path: f.path, displayName: f.name);
        if (f.fd != null) _fds[id] = f.fd!;
      } catch (e) {
        if (f.fd != null) Native.closeFd(f.fd!);
        messages.add('No se pudo enviar: $e');
      }
    }
  }

  Future<void> setName(String n) async {
    final clean = n.trim();
    if (clean.isEmpty) return;
    name = clean.length > 64 ? clean.substring(0, 64) : clean;
    await _run(() => pb.setName(name: name));
    _saveSettings();
    notifyListeners();
  }

  Future<void> setAutoAccept(bool on) async {
    autoAccept = on;
    await _run(() => pb.setAutoAccept(on_: on));
    _saveSettings();
    notifyListeners();
  }

  /// F10: every error code has a message and a next step.
  static String explain(String code, String message) => switch (code) {
        'NETWORK' => 'se perdió la conexión. Se reintenta sola; comprueba que ambos estén en la misma red Wi-Fi',
        'INTEGRITY' => 'el archivo llegó dañado. Vuelve a enviarlo',
        'REJECTED' => 'el otro dispositivo no lo aceptó',
        'PROTOCOL' => 'versiones incompatibles. Actualiza la app en ambos dispositivos',
        'INVALID_NAME' => 'el nombre del archivo no es válido',
        'CANCELLED' => 'cancelado',
        _ => message.isEmpty ? code : message,
      };
}
