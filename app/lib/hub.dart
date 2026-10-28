import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'fs_client.dart';
import 'native.dart';
import 'pc_remote.dart';
import 'remote.dart';
import 'scrcpy.dart';
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

  /// What paired devices report about themselves (`pb.x.*`), by peer id.
  final info = <String, PeerInfo>{};
  final notifs = <String, List<PhoneNotif>>{};
  final media = <String, MediaState>{};
  final wallpaper = <String, Uint8List>{};

  /// Phone side: drives a paired computer (mouse, keys, volume, media, screenshots, its screen).
  late final remote = PcRemote(this);

  /// Computer side: browsing a phone's files. Files it asks for are accepted without a prompt (we asked).
  late final fs = FsClient(this);
  final _expected = <String, (bool, DateTime)>{};

  void expectFromPhone(String name, {bool open = false}) {
    _expected.removeWhere((_, v) => DateTime.now().difference(v.$2) > const Duration(minutes: 10));
    _expected[name] = (open, DateTime.now());
  }
  ScreenFeed? screen;

  /// The computer we asked for a screenshot, and the one that arrived (the UI shows it, then clears it).
  String? shotWanted;
  Shot? shot;

  /// Computer side: the owner's switch for remote control. The daemon reads the same file (remote.json).
  bool remoteAllow = false;
  final clips = <ClipItem>[];

  /// Android: special access for notifications/media, and the normal notification permission.
  bool notifAccess = false, notifPermission = true;

  /// Android: keep the connection waiting in the background (a silent notification), and whether the user
  /// chose a wallpaper image to show on the computer.
  bool background = false, customWallpaper = false;

  /// Android: may a paired computer browse this phone's files (photos, videos, music, chosen folders)?
  bool filesAllowed = false, filesPermission = false;
  List<String> filesFolders = const [];

  /// Files/text another Android app shared with us, waiting for the user to pick a device.
  Shared? share;

  /// 'system' | 'light' | 'dark'. A notifier of its own so only the theme (not the whole app) rebuilds.
  final themeMode = ValueNotifier('system');

  /// Pure-black variant of the dark theme; independent of the mode above (it only shows while dark is in use).
  final amoled = ValueNotifier(false);
  String get theme => themeMode.value;

  late File _settings;
  final _fds = <String, int>{}; // transfer id -> Android descriptor to close when it ends

  Future<void> start() async {
    final data = Directory('${(await getApplicationSupportDirectory()).path}/pb');
    final dl = Platform.isAndroid
        ? '${(await getApplicationSupportDirectory()).path}/incoming' // moved to Downloads by Native.publish
        : '${(await getDownloadsDirectory())!.path}${Platform.pathSeparator}Alero';
    downloads = Platform.isAndroid ? 'Descargas/Alero' : dl;
    _settings = File('${data.path}/settings.json');
    final s = _readSettings();
    name = s['name'] as String? ?? await Native.deviceName();
    autoAccept = s['autoAccept'] as bool? ?? true;
    themeMode.value = s['theme'] as String? ?? 'system';
    amoled.value = s['amoled'] as bool? ?? false;
    remoteAllow = _readRemote();
    pb.events().listen(_on);
    Native.onShared(takeShare);
    try {
      myId = await pb.start(
        config: pb.Config(
          dataDir: data.path,
          downloadDir: dl,
          name: name,
          // The phone listens one port above the computer, so a USB cable can map both ports on one machine.
          port: Platform.isAndroid ? pb.defaultPort() + 1 : pb.defaultPort(),
          discoveryPort: pb.defaultPort(),
          autoAccept: autoAccept,
        ),
      );
    } catch (e) {
      startError = 'No se pudo iniciar: $e';
    }
    await refresh();
    await takeShare();
    await checkPermissions();
    // A window opened later missed what phones sent on connect: ask again.
    for (final p in peers.where(_online)) {
      _hello(p.id);
    }
  }

  File get _remoteFile => File('${_settings.parent.path}/remote.json');

  bool _readRemote() {
    try {
      return (jsonDecode(_remoteFile.readAsStringSync()) as Map)['allow'] == true;
    } catch (_) {
      return false; // missing or unreadable: control stays off
    }
  }

  /// Computer: let paired phones control this computer (the daemon enforces it) and tell them right away.
  void setRemoteAllow(bool on) {
    _remoteFile.parent.createSync(recursive: true);
    _remoteFile.writeAsStringSync(jsonEncode({'allow': on}));
    remoteAllow = on;
    for (final p in peers.where(_online)) {
      sendMessage(p.id, 'pb.x.remote.state', {'allowed': on});
    }
    notifyListeners();
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
    _settings.writeAsStringSync(jsonEncode({'name': name, 'autoAccept': autoAccept, 'theme': theme, 'amoled': amoled.value}));
  }

  Future<void> refresh() async {
    if (myId.isEmpty) return notifyListeners();
    peers = _sorted(await pb.peers());
    history = (await pb.history())..sort((a, b) => b.time.compareTo(a.time)); // newest first
    diagnostics = await pb.diagnostics();
    notifyListeners();
  }

  static bool _online(pb.Peer p) => p.trusted && p.state == pb.PeerState.connected;

  String _peerName(String id) => peers.where((p) => p.id == id).firstOrNull?.name ?? 'otro dispositivo';

  List<pb.Peer> _sorted(List<pb.Peer> l) =>
      l..sort((a, b) => a.trusted != b.trusted ? (a.trusted ? -1 : 1) : a.name.compareTo(b.name));

  void _on(pb.Event e) {
    switch (e) {
      case pb.Event_PeerChanged(:final peer):
        final was = peers.where((p) => p.id == peer.id).firstOrNull;
        peers = _sorted([...peers.where((p) => p.id != peer.id), peer]);
        if (_online(peer) && (was == null || !_online(was))) _hello(peer.id);
        if (!_online(peer)) media.remove(peer.id);
      case pb.Event_PeerGone(:final id):
        peers = peers.where((p) => p.id != id).toList();
      case pb.Event_PairRequest() when _qrId != null && e.peerId == _qrId:
        // Scanned QR: the TLS identity matches the one shown on the other screen, so the code check is done.
        _qrId = null;
        pb.respondPair(peerId: e.peerId, accept: true);
      case pb.Event_PairRequest() when _qrId != null && !e.incoming:
        _qrId = null;
        pb.respondPair(peerId: e.peerId, accept: false);
        messages.add('El equipo no coincide con el QR. Vuelve a escanearlo.');
      case pb.Event_PairRequest():
        pairPrompt = e;
        Native.alert('Solicitud de emparejamiento', '${e.name} quiere emparejarse. Código ${e.code}');
      case pb.Event_PairFinished():
        pairPrompt = null;
        messages.add(
          e.ok
              ? 'Emparejado con ${e.name}'
              : switch (e.code) {
                  'DECLINED' => 'Emparejamiento cancelado',
                  'DECLINED_BY_PEER' => 'El otro dispositivo no aceptó el emparejamiento',
                  _ => 'No se pudo emparejar: ${e.message}. Comprueba que ambos estén en la misma red.',
                },
        );
        refresh();
      case pb.Event_TransferOffer() when _expected.containsKey(e.name) && peers.any((p) => p.id == e.peerId && p.trusted):
        // A file we asked a phone for (explorer): no question.
        pb.respondTransfer(id: e.id, accept: true);
        return;
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
          x.note = es(e.message);
        }
      case pb.Event_TransferFinished():
        _finished(e);
      case pb.Event_Log():
        return;
      case pb.Event_Message():
        _message(e.peerId, e.kind, e.body);
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
    // A screenshot we asked for: read it before the platform moves it to Downloads, so it can be shown at once.
    Shot? arrived;
    if (e.ok && x?.incoming == true && e.path.isNotEmpty && (x?.name ?? '').startsWith('Captura-PC-')) {
      try {
        arrived = Shot(File(e.path).readAsBytesSync(), x!.name, x.peerName);
      } catch (_) {
        // unreadable: it is still saved, only the preview is missing
      }
    }
    if (e.ok && x?.incoming == true && e.path.isNotEmpty) where = await Native.publish(e.path);
    final n = x?.name ?? 'archivo';
    messages.add(switch (e) {
      _ when e.ok && x?.incoming == true => 'Recibido: $n (${where.isEmpty ? downloads : where})',
      _ when e.ok => 'Enviado: $n',
      _ when e.code == 'CANCELLED' => 'Cancelado: $n',
      _ => 'Falló $n: ${explain(e.code, e.message)}',
    });
    final want = x != null && e.ok && x.incoming ? _expected.remove(x.name) : null;
    if (want != null) {
      messages.add('Descargado: ${x!.name}');
      if (want.$1 && e.path.isNotEmpty) FsClient.openFile(e.path);
    } else if (!e.ok && x != null) {
      _expected.remove(x.name);
    }
    if (arrived != null) {
      shot = arrived;
      shotWanted = null;
    } else if (e.ok && x?.incoming == true) {
      Native.alert('Archivo recibido', n);
    }
    await refresh();
  }

  /// Runs an engine call and turns its error into a message.
  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      messages.add(es('$e'));
    }
  }

  // --- app messages (pb.x.*) ---------------------------------------------------------------------------

  Future<void> _send(String peerId, String kind, Map<String, Object?> body) =>
      _run(() => pb.sendMessage(peerId: peerId, kind: kind, body: jsonEncode(body)));

  Future<void> sendMessage(String peerId, String kind, Map<String, Object?> body) => _send(peerId, kind, body);

  /// On connect: ask for the other side's info (a computer's own info comes from its daemon, a phone's from its
  /// service; each answers by itself when it sees us connect, this covers a window opened later).
  void _hello(String peerId) => _send(peerId, 'pb.x.info.request', {});

  /// How we reach a paired device, in words: a USB cable shows up as a loopback address.
  String routeOf(pb.Peer p) => p.addr.startsWith('127.0.0.1') || p.addr.startsWith('[::1]') ? 'Cable USB' : 'Red local';

  void _message(String peerId, String kind, String raw) {
    final Map<String, dynamic> b;
    try {
      b = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (kind.startsWith('pb.x.fs.')) return fs.onMessage(peerId, kind, b);
    switch (kind) {
      case 'pb.x.info':
        info[peerId] = PeerInfo(b);
      case 'pb.x.info.request':
        return; // the daemon (computer) or the service (phone) answers, window or not
      case 'pb.x.remote.state':
        final cur = info[peerId];
        if (cur != null) info[peerId] = cur.withAllowed(b['allowed'] == true);
      case 'pb.x.remote.denied':
        final why = b['reason'] as String? ?? '';
        if (why == 'not_allowed') {
          final cur = info[peerId];
          if (cur != null) info[peerId] = cur.withAllowed(false);
          messages.add('Ese ordenador no permite el control remoto. Actívalo en Alero › Ajustes del ordenador.');
        } else {
          messages.add(why == 'unsupported' ? 'Este ordenador no admite esa función todavía.' : 'No se pudo completar la acción en el ordenador.');
        }
      case 'pb.x.remote.power.result':
        messages.add(b['ok'] == true ? 'Hecho' : 'El ordenador no pudo hacerlo');
        return;
      case 'pb.x.screen.frame':
        screen?.onFrame(b); // notifies by itself: the whole app does not repaint five times a second
        return;
      case 'pb.x.pcmedia.state':
        media[peerId] = MediaState(b);
      case 'pb.x.notif.snapshot':
        notifs[peerId] = [
          for (final n in (b['items'] as List? ?? []))
            if (n is Map) PhoneNotif(n),
        ];
      case 'pb.x.notif.posted':
        final n = PhoneNotif(b);
        notifs[peerId] = [n, ...?notifs[peerId]?.where((o) => o.key != n.key)].take(100).toList();
      case 'pb.x.notif.removed':
        notifs[peerId] = [...?notifs[peerId]?.where((o) => o.key != b['key'])];
      case 'pb.x.wallpaper':
        final jpeg = b['jpeg'] as String? ?? '';
        try {
          if (jpeg.isEmpty) {
            wallpaper.remove(peerId);
          } else {
            wallpaper[peerId] = base64Decode(jpeg);
          }
        } catch (_) {
          return; // not valid base64: ignore it
        }
      case 'pb.x.media.state':
        media[peerId] = MediaState(b);
      case 'pb.x.clip':
        final text = b['text'] as String? ?? '';
        if (text.isEmpty) return;
        // Android: the service already wrote it to the clipboard (that also works without the UI).
        if (!Platform.isAndroid) Clipboard.setData(ClipboardData(text: text));
        _clip(ClipItem(text, _peerName(peerId), true));
        messages.add('Portapapeles de ${_peerName(peerId)} copiado');
      default:
        return;
    }
    notifyListeners();
  }

  void _clip(ClipItem c) {
    clips.insert(0, c);
    if (clips.length > 30) clips.removeLast();
  }

  Future<void> requestInfo(String peerId) => _send(peerId, 'pb.x.info.request', {});

  /// Sends this device's clipboard text. Android allows reading it only while the app is in front.
  Future<void> sendClipboard(String peerId) async {
    final text = (await Clipboard.getData('text/plain'))?.text ?? '';
    if (text.isEmpty) return messages.add('El portapapeles está vacío');
    await sendText(peerId, text);
  }

  Future<void> sendText(String peerId, String text) async {
    await _send(peerId, 'pb.x.clip', {'text': text.length > 60000 ? text.substring(0, 60000) : text});
    _clip(ClipItem(text, _peerName(peerId), false));
    messages.add('Portapapeles enviado a ${_peerName(peerId)}');
    notifyListeners();
  }

  /// Copies a history item back to this device's clipboard.
  Future<void> copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    messages.add('Copiado');
  }

  /// `action`: toggle, play, pause, next, prev, seek (with [position] ms), volume (with [value]).
  Future<void> mediaCmd(String peerId, String action, {int? position, int? value}) =>
      _send(peerId, 'pb.x.media.cmd', {'action': action, 'position': ?position, 'value': ?value});

  Future<void> dismissNotif(String peerId, String key) async {
    notifs[peerId] = [...?notifs[peerId]?.where((n) => n.key != key)];
    notifyListeners();
    await _send(peerId, 'pb.x.notif.dismiss', {'key': key});
  }

  Future<void> clearNotifs(String peerId) async {
    for (final n in [...?notifs[peerId]].where((n) => n.clearable)) {
      await dismissNotif(peerId, n.key);
    }
  }

  // --- Android share menu, permissions, folders, theme -------------------------------------------------

  Future<void> takeShare() async {
    final s = await Native.takeShared();
    if (s == null || (s.files.isEmpty && s.text.isEmpty)) return;
    share = s;
    notifyListeners();
  }

  Future<void> sendShare(String peerId) async {
    final s = share;
    share = null;
    notifyListeners();
    if (s == null) return;
    await _sendPicked(peerId, s.files);
    if (s.text.isNotEmpty && s.files.isEmpty) await sendText(peerId, s.text);
  }

  void dropShare() {
    for (final f in share?.files ?? const <Picked>[]) {
      if (f.fd != null) Native.closeFd(f.fd!);
    }
    share = null;
    notifyListeners();
  }

  Future<void> checkPermissions() async {
    if (!Platform.isAndroid) return;
    notifAccess = await Native.notifAccess();
    notifPermission = await Native.notifPermission();
    background = await Native.background();
    customWallpaper = await Native.hasWallpaper();
    final f = await Native.files();
    filesAllowed = f.allowed;
    filesPermission = f.permission;
    filesFolders = f.folders;
    notifyListeners();
  }

  Future<void> setFilesAllowed(bool on) async {
    await Native.setFiles(on);
    filesAllowed = on;
    notifyListeners();
  }

  Future<void> addFilesFolder() async {
    if (await Native.addFolder()) await checkPermissions();
  }

  Future<void> removeFilesFolder(int i) async {
    await Native.removeFolder(i);
    await checkPermissions();
  }

  Future<void> setBackground(bool on) async {
    await Native.setBackground(on);
    background = on;
    notifyListeners();
  }

  /// Opens the image picker; the phone draws it on the computer's view of this phone.
  Future<void> pickWallpaper() async {
    if (await Native.pickWallpaper()) {
      customWallpaper = true;
      messages.add('Fondo enviado al ordenador');
    }
    notifyListeners();
  }

  Future<void> clearWallpaper() async {
    await Native.clearWallpaper();
    customWallpaper = false;
    notifyListeners();
  }

  Future<void> openDownloads() => Native.openFolder(downloads);

  Future<void> openNotifAccess() => Native.openNotifAccess();

  void setAmoled(bool on) {
    amoled.value = on;
    _saveSettings();
    notifyListeners();
  }

  void setTheme(String t) {
    themeMode.value = t;
    _saveSettings();
    notifyListeners();
  }

  Future<void> pair(String peerId) => _run(() => pb.pairWithPeer(peerId: peerId));

  String? _qrId;

  String _diag(String prefix) =>
      diagnostics.firstWhere((l) => l.startsWith(prefix), orElse: () => prefix).substring(prefix.length).trim();

  /// What this computer shows as a QR: where to reach it and the identity the phone must find there.
  String get qrPayload => 'pb:pair?h=${_diag('local address:')}&p=${_diag('listening on TCP')}&id=$myId';

  /// Phone: pair with the computer in a scanned QR.
  Future<void> pairQr(String text) async {
    final u = Uri.tryParse(text);
    final (h, p, id) = (u?.queryParameters['h'], u?.queryParameters['p'], u?.queryParameters['id']);
    if (u == null || u.scheme != 'pb' || h == null || p == null || id == null || id.length < 32) {
      return messages.add('Ese QR no es de esta app.');
    }
    _qrId = id;
    await pairAddr('$h:$p');
  }

  /// Desktop: connect to the phone through the USB cable (no Wi-Fi). Pairs first if they have never met.
  Future<void> connectCable() async {
    messages.add('Buscando el teléfono por el cable…');
    final err = await Scrcpy.cable(phonePort: pb.defaultPort() + 1, pcPort: pb.defaultPort());
    if (err != null) return messages.add(err);
    await pairAddr('127.0.0.1:${pb.defaultPort() + 1}');
  }

  Future<void> pairAddr(String addr) => _run(() => pb.pairWithAddr(addr: addr));

  Future<void> answerPair(bool accept) async {
    final p = pairPrompt;
    if (p == null) return;
    // The question is answered either way; the engine reports the outcome with PairFinished.
    pairPrompt = null;
    notifyListeners();
    await _run(() => pb.respondPair(peerId: p.peerId, accept: accept));
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
  Future<void> send(String peerId) async => _sendPicked(peerId, await Native.pickFiles());

  /// Desktop drag and drop: plain paths.
  Future<void> sendPaths(String peerId, List<String> paths) =>
      _sendPicked(peerId, [for (final p in paths) Picked(p, null)]);

  Future<void> _sendPicked(String peerId, List<Picked> files) async {
    for (final f in files) {
      try {
        final id = await pb.sendFile(peerId: peerId, path: f.path, displayName: f.name);
        if (f.fd != null) _fds[id] = f.fd!;
      } catch (e) {
        if (f.fd != null) Native.closeFd(f.fd!);
        messages.add('No se pudo enviar: ${es('$e')}');
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
    _ => message.isEmpty ? code : es(message),
  };
}
