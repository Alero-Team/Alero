import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse, AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:path_provider/path_provider.dart';

import 'device_image.dart';
import 'fs_client.dart';
import 'native.dart';
import 'pc_remote.dart';
import 'pc_files.dart';
import 'phone_control.dart';
import 'remote.dart';
import 'sms_client.dart';
import 'scrcpy.dart';
import 'src/rust/api/engine.dart' as pb;

class Xfer {
  Xfer(this.id, this.peerName, this.name, this.size, this.incoming);
  final String id, peerName, name;
  final int size;
  final bool incoming;
  int done = 0, rate = 0;
  String note = '';

  /// A file the app asked for itself (explorer download, screenshot): no transfer dialog for it.
  bool quiet = false;
}

/// A transfer that ended in this run: what the transfer dialog shows when it is over.
class Ended {
  Ended(this.x, this.ok, this.error, this.picture);
  final Xfer x;
  final bool ok;
  final String error;

  /// Android moves a received file into Descargas: a received picture is kept here to preview it.
  Uint8List? picture;
}

/// Single owner of what the UI shows. Mirrors engine events into plain state; no protocol or trust logic here.
class Hub extends ChangeNotifier {
  List<pb.Peer> peers = [];
  List<Xfer> active = [];
  final ended = <Ended>[];
  List<pb.HistoryItem> history = [];
  List<String> diagnostics = [];
  pb.Event_PairRequest? pairPrompt;
  pb.Event_TransferOffer? offer;
  String myId = '', name = '', downloads = '', startError = '';
  bool autoAccept = true;
  final messages = StreamController<String>.broadcast();
  // Network diagnostics are needed by the QR screen, not by Android's
  // background transfer/notification service.
  bool _uiVisible = true;
  AppLifecycleListener? _uiLifecycle;

  /// What paired devices report about themselves (`pb.x.*`), by peer id.
  final info = <String, PeerInfo>{};
  final notifs = <String, List<PhoneNotif>>{};
  final _replies = <String, (String, String, Completer<void>)>{};
  int _replyId = 0;
  bool setupDone = false;

  void finishSetup() {
    setupDone = true;
    _saveSettings();
    notifyListeners();
  }

  void reopenSetup() {
    setupDone = false;
    _saveSettings();
    notifyListeners();
  }

  /// App icon (PNG) by package: the phone sends it once per app, so later rows reuse it.
  final appIcons = <String, Uint8List>{};
  final _iconAsked = <String>{};

  PhoneNotif _notif(Map j) {
    final n = PhoneNotif(j);
    final icon = j['icon'] as String? ?? '';
    if (n.pkg.isNotEmpty && icon.isNotEmpty) {
      appIcons[n.pkg] = base64Decode(icon);
    }
    return n;
  }

  final media = <String, MediaState>{};

  /// The call on each phone, while there is one.
  final calls = <String, CallState>{};

  /// Quick controls, call log and the last contact search, by phone.
  final phoneState = <String, PhoneState>{};
  final callLog = <String, List<CallEntry>>{};
  final contacts = <String, List<CallEntry>>{};

  /// The paired phone connected now (the computer's phone features use it), or null.
  pb.Peer? get connectedPhone => peers
      .where(
        (p) =>
            p.trusted &&
            p.state == pb.PeerState.connected &&
            info[p.id]?.phone == true,
      )
      .firstOrNull;

  /// `what` is dnd, torch, ringer, volume, find, state.request, calllog.request or contacts.
  Future<void> phoneCmd(
    String peerId,
    String what, [
    Map<String, Object?> body = const {},
  ]) => _send(peerId, 'pb.x.phone.$what', body);
  final wallpaper = <String, Uint8List>{};

  /// Commercial name and back cover of each connected phone (computer side), by peer id.
  final look = <String, DeviceLook>{};
  final _lookKey = <String, String>{};
  DeviceImages images = DeviceImages(() async {
    final d = Directory(
      '${(await getApplicationSupportDirectory()).path}/device-covers',
    );
    return d.create(recursive: true);
  });

  /// Cache answers at once and the network fills in later; the connection never waits for it.
  void _resolveLook(String peerId, PeerInfo i) {
    if (Platform.isAndroid || !i.phone) return;
    final id = i.phoneId;
    if (_lookKey[peerId] == id.key) return;
    _lookKey[peerId] = id.key;
    look[peerId] = DeviceLook(
      id.localName,
    ); // stale picture of a previous phone must not linger
    images.look(id).then((l) {
      if (_lookKey[peerId] != id.key) {
        return; // another phone connected meanwhile
      }
      look[peerId] = l;
      notifyListeners();
    });
  }

  /// Phone side: drives a paired computer (mouse, keys, volume, media, screenshots, its screen).
  late final remote = PcRemote(this);

  /// Computer side: browsing a phone's files. Files it asks for are accepted without a prompt (we asked).
  late final fs = FsClient(this);
  late final pcFs = PcFilesClient(this);
  late final sms = SmsClient(this);
  final _expected = <String, (bool, DateTime)>{};

  void expectFromPhone(String name, {bool open = false}) {
    _expected.removeWhere(
      (_, v) => DateTime.now().difference(v.$2) > const Duration(minutes: 10),
    );
    _expected[name] = (open, DateTime.now());
  }

  ScreenFeed? screen;

  /// The computer we asked for a screenshot, and the one that arrived (the UI shows it, then clears it).
  String? shotWanted;
  Shot? shot;

  /// Computer side: the owner's switch for remote control. The daemon reads the same file (remote.json).
  bool remoteAllow = false;
  List<String> pcFolders = const [];
  bool pcFilesWrite = false;
  final clips = <ClipItem>[];

  /// Android: special access for notifications/media, and the normal notification permission.
  bool notifAccess = false, notifPermission = true;

  /// Android: keep the connection waiting in the background (a silent notification), and whether the user
  /// chose a wallpaper image to show on the computer.
  bool background = false, customWallpaper = false;

  /// Android: may a paired computer browse this phone's files (photos, videos, music, chosen folders)?
  bool filesAllowed = false, filesPermission = false;
  List<String> filesFolders = const [];

  /// Android: apps muted from a computer, as (package, name).
  List<(String, String)> mutedApps = const [];

  /// Android: SMS on the computer is switched on / Android granted reading SMS.
  bool smsAllowed = false, smsPermission = false;

  /// Android: received APKs may open the system installer.
  bool installAllowed = false;

  /// Libraries Android lets this app read in full ('images', 'video', 'audio'), and whether only some photos are shared.
  Set<String> filesMedia = const {};
  bool filesLimited = false, allFiles = false;

  /// Files/text another Android app shared with us, waiting for the user to pick a device.
  Shared? share;

  /// 'system' | 'light' | 'dark'. A notifier of its own so only the theme (not the whole app) rebuilds.
  final themeMode = ValueNotifier('dark');

  /// Pure-black variant of the dark theme; independent of the mode above (it only shows while dark is in use).
  final amoled = ValueNotifier(true);

  /// Size of Home's tiles (padding and spacing): compact, normal or large.
  final tileSize = ValueNotifier('normal');

  /// Home's tiles in the order the user chose, and the ones switched off (see `homeTiles`).
  List<String> homeOrder = [];
  Set<String> homeHidden = {};

  /// Width of each "Controles del teléfono" tile, in grid columns, by label (long press to change).
  final controlSpans = <String, int>{};

  /// The phone controls in the order the user chose, and the ones switched off.
  List<String> controlOrder = [];
  Set<String> controlHidden = {};
  String get theme => themeMode.value;

  late File _settings;
  final _fds =
      <
        String,
        int
      >{}; // transfer id -> Android descriptor to close when it ends

  Future<void> start() async {
    final data = Directory(
      '${(await getApplicationSupportDirectory()).path}/pb',
    );
    final dl = Platform.isAndroid
        ? '${(await getApplicationSupportDirectory()).path}/incoming' // moved to Downloads by Native.publish
        : '${(await getDownloadsDirectory())!.path}${Platform.pathSeparator}Alero';
    downloads = Platform.isAndroid ? 'Descargas/Alero' : dl;
    _settings = File('${data.path}/settings.json');
    final s = _readSettings();
    name = s['name'] as String? ?? await Native.deviceName();
    autoAccept = s['autoAccept'] as bool? ?? true;
    setupDone = s['setupDone'] == true;
    themeMode.value = s['theme'] as String? ?? 'dark';
    amoled.value = s['amoled'] as bool? ?? true;
    tileSize.value = s['tileSize'] as String? ?? 'normal';
    homeOrder = (s['homeOrder'] as List? ?? []).whereType<String>().toList();
    homeHidden = (s['homeHidden'] as List? ?? []).whereType<String>().toSet();
    controlOrder = (s['controlOrder'] as List? ?? [])
        .whereType<String>()
        .toList();
    controlHidden = (s['controlHidden'] as List? ?? [])
        .whereType<String>()
        .toSet();
    (s['controlSpans'] as Map?)?.forEach((k, v) {
      if (k is String && v is num) controlSpans[k] = v.toInt();
    });
    remoteAllow = _readRemote();
    pcFolders = _readPcFolders();
    pcFilesWrite = _readRemoteConfig()['allowPcFileEdits'] == true;
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
    if (Platform.isAndroid) {
      _uiLifecycle = AppLifecycleListener(
        onStateChange: (state) {
          final visible = state == AppLifecycleState.resumed;
          if (visible && !_uiVisible) refresh();
          _uiVisible = visible;
        },
      );
    }
    // Only the visible QR/diagnostics UI needs address polling. The native
    // background service keeps connections and transfers working as before.
    Timer.periodic(const Duration(seconds: 5), (_) async {
      if (myId.isEmpty || (Platform.isAndroid && !_uiVisible)) return;
      final d = await pb.diagnostics();
      if (!listEquals(d, diagnostics)) {
        diagnostics = d;
        notifyListeners();
      }
    });
    if (!Platform.isAndroid) {
      PhoneSessions.instance.addListener(_sessionsChanged);
      // Closing Alero ends every phone session: no scrcpy window is left driving a phone on its own.
      AppLifecycleListener(
        onExitRequested: () async {
          PhoneSessions.instance.stopAll();
          return AppExitResponse.exit;
        },
      );
    }
    await takeShare();
    await checkPermissions();
    // A window opened later missed what phones sent on connect: ask again.
    for (final p in peers.where(_online)) {
      _hello(p.id);
    }
  }

  File get _remoteFile => File('${_settings.parent.path}/remote.json');

  Map<String, dynamic> _readRemoteConfig() {
    try {
      return jsonDecode(_remoteFile.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  void _writeRemoteConfig(Map<String, dynamic> data) {
    _remoteFile.parent.createSync(recursive: true);
    _remoteFile.writeAsStringSync(jsonEncode(data), flush: true);
  }

  bool _readRemote() => _readRemoteConfig()['allow'] == true;

  List<String> _readPcFolders() => [
    for (final path in (_readRemoteConfig()['folders'] as List? ?? []))
      if (path is String && path.isNotEmpty) path,
  ];

  /// Windows folders stay private unless the owner chooses them explicitly.
  Future<void> addPcFolder() async {
    if (!Platform.isWindows) return;
    final selected = await Native.pickSharedPcFolder();
    if (selected == null) return;
    final folder = Directory(selected);
    if (!folder.existsSync()) return;
    final canonical = folder.resolveSymbolicLinksSync();
    final folders = {...pcFolders, canonical}.toList();
    _writeRemoteConfig({..._readRemoteConfig(), 'folders': folders});
    pcFolders = folders;
    notifyListeners();
  }

  void removePcFolder(String folder) {
    final folders = pcFolders.where((f) => f != folder).toList();
    _writeRemoteConfig({..._readRemoteConfig(), 'folders': folders});
    pcFolders = folders;
    notifyListeners();
  }

  /// Separate explicit consent for renaming/deleting shared files.
  void setPcFileEdits(bool value) {
    _writeRemoteConfig({..._readRemoteConfig(), 'allowPcFileEdits': value});
    pcFilesWrite = value;
    notifyListeners();
  }

  /// Computer: let paired phones control this computer (the daemon enforces it).
  void setRemoteAllow(bool on) {
    _writeRemoteConfig({..._readRemoteConfig(), 'allow': on});
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
    _settings.writeAsStringSync(
      jsonEncode({
        ..._readSettings(),
        'setupDone': setupDone,
        'name': name,
        'autoAccept': autoAccept,
        'theme': theme,
        'amoled': amoled.value,
        'tileSize': tileSize.value,
        'homeOrder': homeOrder,
        'homeHidden': homeHidden.toList(),
        'controlOrder': controlOrder,
        'controlHidden': controlHidden.toList(),
        'controlSpans': controlSpans,
      }),
    );
  }

  Future<void> refresh() async {
    if (myId.isEmpty) return notifyListeners();
    peers = _sorted(await pb.peers());
    history = (await pb.history())
      ..sort((a, b) => b.time.compareTo(a.time)); // newest first
    diagnostics = await pb.diagnostics();
    notifyListeners();
  }

  static bool _online(pb.Peer p) =>
      p.trusted && p.state == pb.PeerState.connected;

  String _peerName(String id) =>
      peers.where((p) => p.id == id).firstOrNull?.name ?? 'otro dispositivo';

  List<pb.Peer> _sorted(List<pb.Peer> l) => l
    ..sort(
      (a, b) => a.trusted != b.trusted
          ? (a.trusted ? -1 : 1)
          : a.name.compareTo(b.name),
    );

  @visibleForTesting
  void onEvent(pb.Event e) => _on(e);

  @visibleForTesting
  set expectedQr(String? id) => _qrId = id;

  void _on(pb.Event e) {
    switch (e) {
      case pb.Event_PeerChanged(:final peer):
        final was = peers.where((p) => p.id == peer.id).firstOrNull;
        peers = _sorted([...peers.where((p) => p.id != peer.id), peer]);
        if (_online(peer) && (was == null || !_online(was))) _hello(peer.id);
        if (!_online(peer)) {
          media.remove(peer.id);
          calls.remove(peer.id);
          phoneState.remove(peer.id);
          _failReplies(peer.id, 'El teléfono está sin conexión.');
        }
      case pb.Event_PeerGone(:final id):
        media.remove(id);
        calls.remove(id);
        _failReplies(id, 'El teléfono está sin conexión.');
        peers = peers.where((p) => p.id != id).toList();
      case pb.Event_PairRequest() when _qrId != null && e.peerId == _qrId:
        // Scanned QR: the TLS identity matches the one on the other screen. The code is still shown here, so it can
        // be compared with the one the computer asks to confirm instead of guessing.
        _qrId = null;
        pairPrompt = e;
        Native.alert(
          'Solicitud de emparejamiento',
          'Comprueba que ${e.name} muestra el código ${e.code}',
        );
      case pb.Event_PairRequest() when _qrId != null && !e.incoming:
        _qrId = null;
        pb.respondPair(peerId: e.peerId, accept: false);
        messages.add('El equipo no coincide con el QR. Vuelve a escanearlo.');
      case pb.Event_PairRequest():
        pairPrompt = e;
        Native.alert(
          'Solicitud de emparejamiento',
          '${e.name} quiere emparejarse. Código ${e.code}',
        );
      case pb.Event_PairFinished():
        pairPrompt = null;
        messages.add(
          e.ok
              ? 'Emparejado con ${e.name}'
              : switch (e.code) {
                  'DECLINED' => 'Emparejamiento cancelado',
                  _ when e.message == 'OUTDATED' =>
                    'El otro dispositivo no completó la comprobación del código. Actualiza Alero en los dos e inténtalo de nuevo.',
                  'DECLINED_BY_PEER' =>
                    'El otro dispositivo no aceptó el emparejamiento',
                  _ =>
                    'No se pudo emparejar: ${e.message}. Comprueba que ambos estén en la misma red.',
                },
        );
        refresh();
      case pb.Event_TransferOffer()
          when _expected.containsKey(e.name) &&
              peers.any((p) => p.id == e.peerId && p.trusted):
        // A file we asked a phone for (explorer): no question.
        pb.respondTransfer(id: e.id, accept: true);
        return;
      case pb.Event_TransferOffer():
        offer = e;
        Native.alert(
          'Archivo entrante',
          '${e.peerName} quiere enviarte ${e.name}',
        );
      case pb.Event_TransferStarted():
        if (offer?.id == e.id) offer = null;
        active = [
          ...active,
          Xfer(e.id, e.peerName, e.name, e.size.toInt(), e.incoming)
            ..quiet =
                _expected.containsKey(e.name) ||
                (shotWanted != null && e.name.startsWith('Captura-PC-')),
        ];
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
      case pb.Event_Log(:final message):
        // The bridge started the background service again after it died: read everything again.
        if (message == 'service-restarted') refresh();
        return;
      case pb.Event_Message():
        _message(e.peerId, e.kind, e.body);
      case pb.Event_Show():
        Native.showWindow();
        return;
      case pb.Event_Quit():
        PhoneSessions.instance.stopAll();
        exit(0);
    }
    notifyListeners();
  }

  Future<void> _finished(pb.Event_TransferFinished e) async {
    final x = active.where((x) => x.id == e.id).firstOrNull;
    active = active.where((x) => x.id != e.id).toList();
    final fd = _fds.remove(e.id);
    if (fd != null) Native.closeFd(fd);
    // Recorded before the first await: the dialog sees the end in the same notification that drops it from `active`.
    if (x != null && !x.quiet) {
      Uint8List? picture;
      if (e.ok &&
          x.incoming &&
          Platform.isAndroid &&
          e.path.isNotEmpty &&
          x.size <= 12 << 20 &&
          RegExp(
            r'\.(jpe?g|png|gif|webp|bmp)$',
            caseSensitive: false,
          ).hasMatch(x.name)) {
        try {
          picture = File(e.path).readAsBytesSync();
        } catch (_) {
          // no preview; the file is still saved
        }
      }
      for (final o in ended) {
        o.picture = null; // one preview in memory at a time
      }
      ended.add(
        Ended(
          x,
          e.ok,
          e.ok
              ? ''
              : e.code == 'CANCELLED'
              ? 'Cancelado'
              : explain(e.code, e.message),
          picture,
        ),
      );
      if (ended.length > 40) ended.removeAt(0);
    }
    var where = '';
    // A screenshot we asked for: read it before the platform moves it to Downloads, so it can be shown at once.
    Shot? arrived;
    if (e.ok &&
        x?.incoming == true &&
        e.path.isNotEmpty &&
        (x?.name ?? '').startsWith('Captura-PC-')) {
      try {
        arrived = Shot(File(e.path).readAsBytesSync(), x!.name, x.peerName);
      } catch (_) {
        // unreadable: it is still saved, only the preview is missing
      }
    }
    if (e.ok && x?.incoming == true && e.path.isNotEmpty) {
      where = await Native.publish(e.path);
    }
    final n = x?.name ?? 'archivo';
    messages.add(switch (e) {
      _ when e.ok && x?.incoming == true =>
        'Recibido: $n (${where.isEmpty ? downloads : where})',
      _ when e.ok => 'Enviado: $n',
      _ when e.code == 'CANCELLED' => 'Cancelado: $n',
      _ => 'Falló $n: ${explain(e.code, e.message)}',
    });
    final want = x != null && e.ok && x.incoming
        ? _expected.remove(x.name)
        : null;
    if (want != null) {
      messages.add('Descargado: ${x!.name}');
      if (want.$1 && e.path.isNotEmpty) {
        try {
          await Native.openFile(e.path);
        } on PlatformException catch (e) {
          messages.add(e.message ?? 'No se pudo abrir ${x.name}.');
        } catch (_) {
          messages.add('No se pudo abrir ${x.name}.');
        }
      }
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
      _run(
        () =>
            pb.sendMessage(peerId: peerId, kind: kind, body: jsonEncode(body)),
      );

  Future<void> sendMessage(
    String peerId,
    String kind,
    Map<String, Object?> body,
  ) => _send(peerId, kind, body);

  /// adb serial -> paired phone it belongs to, for the sessions that phone was told about.
  final _controlled = <String, String>{};

  /// Desktop: starts a scrcpy session. When it drives a paired phone, that phone shows a notice with "Detener".
  Future<void> startControl(
    String serial,
    String title,
    SessionOptions o, {
    String? peerId,
  }) async {
    await PhoneSessions.instance.start(serial, title, o);
    // ADB/scrcpy may be authorised even when Alero's own TLS session is
    // disconnected. The viewer must still launch; only notify the phone
    // about control when that separate Alero channel is actually online.
    if (peerId == null || !peers.any((p) => p.id == peerId && _online(p))) {
      return;
    }
    _controlled[serial] = peerId;
    await _send(peerId, 'pb.x.phonecontrol', {'active': true});
  }

  void _sessionsChanged() {
    for (final s in _controlled.keys.toList()) {
      if (!PhoneSessions.instance.running(s)) {
        _send(_controlled.remove(s)!, 'pb.x.phonecontrol', {'active': false});
      }
    }
  }

  /// On connect: ask for the other side's info (a computer's own info comes from its daemon, a phone's from its
  /// service; each answers by itself when it sees us connect, this covers a window opened later).
  void _hello(String peerId) => _send(peerId, 'pb.x.info.request', {});

  /// How we reach a paired device, in words: a USB cable shows up as a loopback address.
  String routeOf(pb.Peer p) =>
      p.addr.startsWith('127.0.0.1') || p.addr.startsWith('[::1]')
      ? 'Cable USB'
      : 'Red local';

  void _message(String peerId, String kind, String raw) {
    final Map<String, dynamic> b;
    try {
      b = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (kind.startsWith('pb.x.fs.')) return fs.onMessage(peerId, kind, b);
    if (kind.startsWith('pb.x.pcfs.')) return pcFs.onMessage(peerId, kind, b);
    if (kind.startsWith('pb.x.sms.')) return sms.onMessage(peerId, kind, b);
    switch (kind) {
      case 'pb.x.call':
        final c = CallState(b);
        c.active ? calls[peerId] = c : calls.remove(peerId);
      case 'pb.x.phone.state':
        phoneState[peerId] = PhoneState(b);
      case 'pb.x.phone.calllog':
        callLog[peerId] = [
          for (final c in (b['items'] as List? ?? []))
            if (c is Map) CallEntry(c),
        ];
      case 'pb.x.phone.icons.result':
        (b['icons'] as Map? ?? {}).forEach((k, v) {
          if (k is String && v is String && v.isNotEmpty) {
            appIcons[k] = base64Decode(v);
          }
        });
      case 'pb.x.phone.contacts.result':
        contacts[peerId] = [
          for (final c in (b['items'] as List? ?? []))
            if (c is Map) CallEntry(c),
        ];
      case 'pb.x.phone.error':
        messages.add(switch (b['error']) {
          'dnd_access' => 'En el teléfono, toca el aviso de Alero y permite el acceso a «No molestar».',
          'no_permission' => 'Falta un permiso en el teléfono.',
          _ => 'El teléfono no pudo hacerlo.',
        });
        return;
      case 'pb.x.call.result':
        if (b['ok'] != true) {
          messages.add(switch (b['error']) {
            'not_allowed' => 'Activa las llamadas en el teléfono: Alero › Ajustes › Llamadas en el ordenador.',
            'no_permission' => 'Falta el permiso de llamadas en el teléfono.',
            'bad_number' => 'Ese número no es válido.',
            _ => 'El teléfono no pudo hacerlo.',
          });
        }
        return;
      case 'pb.x.history.remove':
        // The engine already removed them; just show it.
        refresh();
        return;
      case 'pb.x.info':
        info[peerId] = PeerInfo(b);
        _resolveLook(peerId, info[peerId]!);
      case 'pb.x.power':
        final cur = info[peerId];
        if (cur != null) info[peerId] = cur.withPower(b);
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
          messages.add(
            'Ese ordenador no permite el control remoto. Actívalo en Alero › Ajustes del ordenador.',
          );
        } else if (why == 'secure_desktop') {
          messages.add(
            'Windows muestra una pantalla protegida (permiso de administrador o bloqueo). Respóndela en el ordenador; el control vuelve solo.',
          );
        } else {
          messages.add(
            why == 'unsupported'
                ? 'Este ordenador no admite esa función todavía.'
                : 'No se pudo completar la acción en el ordenador.',
          );
        }
      case 'pb.x.phonecontrol.stop':
        // "Detener" on the phone's notice.
        for (final s in [
          for (final e in _controlled.entries)
            if (e.value == peerId) e.key,
        ]) {
          PhoneSessions.instance.stop(s);
        }
        messages.add(
          '${_peerName(peerId)} detuvo el control desde el teléfono.',
        );
      case 'pb.x.remote.power.result':
        messages.add(
          b['ok'] == true ? 'Hecho' : 'El ordenador no pudo hacerlo',
        );
        return;
      case 'pb.x.screen.frame':
        screen?.onFrame(b); // notifies by itself: the whole app does not repaint five times a second
        return;
      case 'pb.x.screen.cursor':
        screen?.onCursor(b);
        return;
      case 'pb.x.pcmedia.state':
        media[peerId] = MediaState(b);
      case 'pb.x.notif.reply.result':
        onNotifReplyResult(peerId, b);
        return;
      case 'pb.x.notif.snapshot':
        notifs[peerId] = [
          for (final n in (b['items'] as List? ?? []))
            if (n is Map) _notif(n),
        ];
      case 'pb.x.notif.posted':
        final n = _notif(b);
        notifs[peerId] = [
          n,
          ...?notifs[peerId]?.where((o) => o.key != n.key),
        ].take(100).toList();
      case 'pb.x.notif.removed':
        _failReplies(
          peerId,
          'La notificación ya no está disponible.',
          key: b['key'] as String?,
        );
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
        final m = media[peerId] = MediaState(b);
        if (m.pkg.isNotEmpty &&
            !appIcons.containsKey(m.pkg) &&
            _iconAsked.add(m.pkg)) {
          phoneCmd(peerId, 'icons', {
            'pkgs': [m.pkg],
          });
        }
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

  Future<void> requestInfo(String peerId) =>
      _send(peerId, 'pb.x.info.request', {});

  /// Sends this device's clipboard text. Android allows reading it only while the app is in front.
  Future<void> sendClipboard(String peerId) async {
    final text = (await Clipboard.getData('text/plain'))?.text ?? '';
    if (text.isEmpty) return messages.add('El portapapeles está vacío');
    await sendText(peerId, text);
  }

  Future<void> sendText(String peerId, String text) async {
    await _send(peerId, 'pb.x.clip', {
      'text': text.length > 60000 ? text.substring(0, 60000) : text,
    });
    _clip(ClipItem(text, _peerName(peerId), false));
    messages.add('Portapapeles enviado a ${_peerName(peerId)}');
    notifyListeners();
  }

  /// Copies a history item back to this device's clipboard.
  Future<void> copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    messages.add('Copiado');
  }

  /// Windows: the file itself goes to the clipboard (paste it in a folder or a chat); elsewhere, its path.
  Future<void> copyFile(String path) async {
    if (!Platform.isWindows) return copy(path);
    // The path travels in the environment, never inside the command text.
    final r = await Process.run(
      '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}'
      r'\System32\WindowsPowerShell\v1.0\powershell.exe',
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'Set-Clipboard -LiteralPath $env:ALERO_COPY',
      ],
      environment: {'ALERO_COPY': path},
    );
    messages.add(
      r.exitCode == 0 ? 'Archivo copiado' : 'No se pudo copiar el archivo.',
    );
  }

  /// `action`: toggle, play, pause, next, prev, seek (with [position] ms), volume (with [value]).
  Future<void> mediaCmd(
    String peerId,
    String action, {
    int? position,
    int? value,
  }) => _send(peerId, 'pb.x.media.cmd', {
    'action': action,
    'position': ?position,
    'value': ?value,
  });

  /// The only limit on a reply is the protocol's: one app message carries 256 KiB of JSON (core frame.rs
  /// MAX_APP_BODY), less room for the key and request id. That is tens of thousands of characters even with
  /// emoji. A longer reply is refused with a clear message, never cut.
  static const maxReplyBytes = 240 * 1024;

  /// Size the reply takes inside the message, as the engine measures it (UTF-8 JSON).
  static int replyBytes(String text) => utf8.encode(jsonEncode(text)).length;

  Future<void> replyNotif(String peerId, String key, String text) async {
    if (!peers.any((p) => p.id == peerId && _online(p))) {
      throw StateError('El teléfono está sin conexión.');
    }
    if (!(notifs[peerId]?.any((n) => n.key == key && n.replyable) ?? false)) {
      throw StateError('La notificación ya no permite respuestas.');
    }
    if (text.trim().isEmpty) throw StateError('Escribe una respuesta.');
    final size = replyBytes(text);
    if (size > maxReplyBytes) {
      throw StateError(
        'La respuesta ocupa ${(size / 1024).ceil()} KB y el máximo que Alero puede llevar al teléfono '
        'en un mensaje es ${maxReplyBytes ~/ 1024} KB. No se ha enviado ni recortado.',
      );
    }
    final request = '${DateTime.now().microsecondsSinceEpoch}:${_replyId++}';
    final done = Completer<void>();
    _replies[request] = (peerId, key, done);
    // Attach the timeout before sending so an immediate disconnect cannot leave an unhandled future.
    final waiting = done.future.timeout(const Duration(seconds: 12));
    try {
      unawaited(
        sendMessage(peerId, 'pb.x.notif.reply', {
          'key': key,
          'text': text,
          'request': request,
        }),
      );
      await waiting;
    } finally {
      _replies.remove(request);
    }
  }

  void onNotifReplyResult(String peerId, Map<String, dynamic> b) {
    final pending = _replies[b['request']];
    if (pending == null ||
        pending.$1 != peerId ||
        pending.$2 != b['key'] ||
        pending.$3.isCompleted) {
      return;
    }
    if (b['ok'] == true) {
      pending.$3.complete();
    } else {
      pending.$3.completeError(
        StateError(switch (b['error']) {
          'expired' => 'La notificación caducó o fue descartada.',
          'no_access' => 'Falta acceso a las notificaciones en el teléfono.',
          'invalid_text' => 'La respuesta no es válida.',
          'too_large' => 'Android rechazó la respuesta por su tamaño. No se envió; acórtala e inténtalo de nuevo.',
          _ => 'La app del teléfono no aceptó la respuesta.',
        }),
      );
    }
  }

  void _failReplies(String peerId, String reason, {String? key}) {
    for (final pending in _replies.values) {
      if (pending.$1 == peerId &&
          (key == null || pending.$2 == key) &&
          !pending.$3.isCompleted) {
        pending.$3.completeError(StateError(reason));
      }
    }
  }

  Future<void> dismissNotif(String peerId, String key) async {
    notifs[peerId] = [...?notifs[peerId]?.where((n) => n.key != key)];
    notifyListeners();
    await _send(peerId, 'pb.x.notif.dismiss', {'key': key});
  }

  /// `read`, `mute` (the conversation, through the app) or `muteApp` (this app stops reaching computers).
  Future<void> notifAction(String peerId, PhoneNotif n, String action) async {
    if (action != 'mute') {
      notifs[peerId] = [
        ...?notifs[peerId]?.where(
          (x) => action == 'muteApp' ? x.pkg != n.pkg : x.key != n.key,
        ),
      ];
      notifyListeners();
    }
    await _send(peerId, 'pb.x.notif.action', {'key': n.key, 'action': action});
  }

  Future<void> clearNotifs(String peerId) async {
    for (final n in [...?notifs[peerId]].where((n) => n.clearable)) {
      await dismissNotif(peerId, n.key);
    }
  }

  // --- Android share menu, permissions, folders, theme -------------------------------------------------

  /// What a home-screen widget asked to open; the shell carries it out once a computer is connected.
  String? widgetAction;

  /// True when the computer did not connect soon after a widget asked for something that needs it.
  bool widgetWaited = false;

  Future<void> takeShare() async {
    final s = await Native.takeShared();
    if (s != null && s.widget.isNotEmpty) {
      final a = widgetAction = s.widget;
      widgetWaited = false;
      // A cold start: the computer usually reconnects in a few seconds.
      Timer(const Duration(seconds: 12), () {
        if (widgetAction == a) {
          widgetWaited = true;
          notifyListeners();
        }
      });
      return notifyListeners();
    }
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

  Future<void> openHistory(pb.HistoryItem h) async {
    try {
      await Native.openFile(h.path, id: h.id);
    } catch (e) {
      messages.add(
        e is PlatformException
            ? (e.message ?? 'No se pudo abrir el archivo.')
            : 'No se pudo abrir ${h.name}. Comprueba que sigue disponible.',
      );
    }
  }

  Future<void> checkPermissions() async {
    if (!Platform.isAndroid) return;
    allFiles = await Native.allFiles();
    notifAccess = await Native.notifAccess();
    notifPermission = await Native.notifPermission();
    background = await Native.background();
    customWallpaper = await Native.hasWallpaper();
    final f = await Native.files();
    filesAllowed = f.allowed;
    filesPermission = f.permission;
    filesFolders = f.folders;
    mutedApps = await Native.mutedApps();
    installAllowed = await Native.installPermission();
    final smsState = await Native.sms();
    smsAllowed = smsState.$1;
    smsPermission = smsState.$2;
    final callState = await Native.calls();
    callsAllowed = callState.$1;
    callsPermission = callState.$2;
    filesMedia = f.media;
    filesLimited = f.limited;
    notifyListeners();
  }

  Future<void> setFilesAllowed(bool on) async {
    await Native.setFiles(on);
    filesAllowed = on;
    notifyListeners();
    if (on) await requestMedia();
  }

  /// Ask for photos/videos/music; if Android will not show its dialog any more, open the app's permission page.
  Future<void> requestMedia() async {
    final blocked = await Native.requestMedia();
    await checkPermissions();
    if (blocked) {
      messages.add(
        'Android ya no puede preguntar: concede Fotos y vídeos o Música y audio en los permisos de la app.',
      );
      await Native.openPermissions();
    }
  }

  Future<void> addFilesFolder() async {
    if (await Native.addFolder()) await checkPermissions();
  }

  Future<void> removeFilesFolder(int i) async {
    await Native.removeFolder(i);
    await checkPermissions();
  }

  /// `answer`, `decline` or `hangup` on the phone's current call.
  Future<void> callCmd(String peerId, String action) =>
      _send(peerId, 'pb.x.call.cmd', {'action': action});

  Future<void> dial(String peerId, String number) =>
      _send(peerId, 'pb.x.call.dial', {'number': number});

  /// Android: calls on the computer switched on / Android granted the call permissions.
  bool callsAllowed = false, callsPermission = false;

  Future<void> setCallsAllowed(bool on) async {
    await Native.setCalls(on);
    callsAllowed = on;
    notifyListeners();
    if (on && await Native.requestCalls()) {
      messages.add(
        'Android ya no puede preguntar: concede Teléfono en los permisos de la app.',
      );
      await Native.openPermissions();
    }
    await checkPermissions();
  }

  Future<void> setSmsAllowed(bool on) async {
    await Native.setSms(on);
    smsAllowed = on;
    notifyListeners();
    if (on && await Native.requestSms()) {
      messages.add(
        'Android ya no puede preguntar: concede SMS y Contactos en los permisos de la app.',
      );
      await Native.openPermissions();
    }
    await checkPermissions();
  }

  Future<void> unmuteApp(String pkg) async {
    await Native.unmuteApp(pkg);
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

  void setControlSpan(String label, int span) {
    span <= 1 ? controlSpans.remove(label) : controlSpans[label] = span;
    _saveSettings();
    notifyListeners();
  }

  void setControls(List<String> order, Set<String> hidden) {
    controlOrder = order;
    controlHidden = hidden;
    _saveSettings();
    notifyListeners();
  }

  void setHome(List<String> order, Set<String> hidden) {
    homeOrder = order;
    homeHidden = hidden;
    _saveSettings();
    notifyListeners();
  }

  void setTileSize(String size) {
    tileSize.value = size;
    _saveSettings();
    notifyListeners();
  }

  void setTheme(String t) {
    themeMode.value = t;
    _saveSettings();
    notifyListeners();
  }

  Future<void> pair(String peerId) =>
      _run(() => pb.pairWithPeer(peerId: peerId));

  String? _qrId;

  String _diag(String prefix) => diagnostics
      .firstWhere((l) => l.startsWith(prefix), orElse: () => prefix)
      .substring(prefix.length)
      .trim();

  /// What this computer shows as a QR: where to reach it and the identity the phone must find there.
  String get qrPayload =>
      'pb:pair?h=${_diag('local address:')}&p=${_diag('listening on TCP')}&id=$myId';

  /// Phone: pair with the computer in a scanned QR.
  Future<void> pairQr(String text) async {
    final u = Uri.tryParse(text);
    final (h, p, id) = (
      u?.queryParameters['h'],
      u?.queryParameters['p'],
      u?.queryParameters['id'],
    );
    if (u == null ||
        u.scheme != 'pb' ||
        h == null ||
        p == null ||
        id == null ||
        id.length < 32) {
      return messages.add('Ese QR no es de esta app.');
    }
    _qrId = id;
    // An unpaired device is only listed while its announcements arrive, so that address is live; a QR may be old.
    final heard = peers
        .where((x) => x.id == id && !x.trusted && x.addr.isNotEmpty)
        .firstOrNull;
    await pairAddr(heard?.addr ?? '$h:$p');
  }

  /// Desktop: connect to the phone through the USB cable (no Wi-Fi). Pairs first if they have never met.
  Future<void> connectCable() async {
    messages.add('Buscando el teléfono por el cable…');
    final err = await Scrcpy.cable(
      phonePort: pb.defaultPort() + 1,
      pcPort: pb.defaultPort(),
    );
    if (err != null) return messages.add(err);
    await pairAddr('127.0.0.1:${pb.defaultPort() + 1}');
    _keepCable();
  }

  Timer? _cableKeeper;
  bool _cableBusy = false;

  /// Another adb on this PC (Android Studio, an old `adb.exe`) restarts the shared server and with it forgets the
  /// tunnels, which looked like the cable "disconnecting by itself". While the cable is in use, reopen them quietly.
  void _keepCable() {
    _cableKeeper ??= Timer.periodic(const Duration(seconds: 8), (_) async {
      if (_cableBusy) return;
      _cableBusy = true;
      try {
        final phone = pb.defaultPort() + 1, pc = pb.defaultPort();
        if (await Scrcpy.tunnelUp(phonePort: phone, pcPort: pc)) return;
        final err = await Scrcpy.cable(
          phonePort: phone,
          pcPort: pc,
          startServer: false,
        );
        if (err == null) {
          // Dials the paired phone at once.
          await pb.pairWithAddr(addr: '127.0.0.1:$phone');
        }
      } catch (_) {
        // no phone or no adb right now: try again at the next tick
      } finally {
        _cableBusy = false;
      }
    });
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

  /// "Desconectar": ends the connection and this device's control sessions with it, keeping the pairing.
  /// The engine does not reconnect (not even after a restart) until [reconnect].
  Future<void> disconnect(String peerId) => _run(() async {
    for (final s in [
      for (final e in _controlled.entries)
        if (e.value == peerId) e.key,
    ]) {
      PhoneSessions.instance.stop(s);
    }
    // A local engine command, never sent to the other device (see the bridge's send_message).
    await pb.sendMessage(
      peerId: peerId,
      kind: 'pb.local.disconnect',
      body: '{}',
    );
    await refresh();
  });

  /// "Conectar": dials a paired device again now.
  Future<void> reconnect(String peerId) => _run(() async {
    await pb.sendMessage(peerId: peerId, kind: 'pb.local.connect', body: '{}');
    await refresh();
  });
  Future<void> cancel(String id) => _run(() => pb.cancelTransfer(id: id));
  Future<void> retry(String historyId) =>
      _run(() => pb.retry(historyId: historyId));

  /// Drops one record from the list (the file on disk stays). The list updates before the store answers.
  Future<void> removeHistory(String id) => _run(() async {
    _forgetOnPeers(history.where((h) => h.id == id));
    history = history.where((h) => h.id != id).toList();
    notifyListeners();
    await pb.removeHistory(id: id);
    await refresh();
  });

  Future<void> clearHistory() => _run(() async {
    _forgetOnPeers(history);
    await pb.clearHistory();
    await refresh();
  });

  /// The other device drops the same transfers from its list (files stay on both).
  /// shortcut: a peer that is offline now keeps its records; queue them if that matters.
  void _forgetOnPeers(Iterable<pb.HistoryItem> items) {
    final byPeer = <String, List<String>>{};
    for (final h in items) {
      (byPeer[h.peerId] ??= []).add(h.id);
    }
    for (final MapEntry(key: peer, value: ids) in byPeer.entries) {
      if (peers.any((p) => p.id == peer && p.state == pb.PeerState.connected)) {
        sendMessage(peer, 'pb.x.history.remove', {'ids': ids});
      }
    }
  }

  /// Set by the shell: shows the files before they go (name, size, thumbnail). False cancels the send.
  Future<bool> Function(List<Picked> files, String to)? confirmSend;

  /// Desktop: real paths. Android: picks content URIs and sends their descriptors (no copy).
  Future<void> send(String peerId) async =>
      _sendPicked(peerId, await Native.pickFiles());

  /// Desktop drag and drop: plain paths.
  Future<void> sendPaths(String peerId, List<String> paths) =>
      _sendPicked(peerId, [for (final p in paths) Picked(p, null)]);

  /// Desktop: pick a folder and send everything in it, keeping its subfolders.
  Future<void> sendFolder(String peerId) async {
    final dir = await Native.pickFolder();
    if (dir != null) await sendPaths(peerId, [dir]);
  }

  /// A folder becomes its files, each named `Folder/sub/file` so the receiver rebuilds the tree.
  /// shortcut: empty folders are not recreated; send a placeholder file if that ever matters.
  static List<Picked> expandFolders(List<Picked> picked) {
    final out = <Picked>[];
    for (final p in picked) {
      if (p.fd != null || !FileSystemEntity.isDirectorySync(p.path)) {
        out.add(p);
        continue;
      }
      final root = p.path
          .replaceAll(r'\', '/')
          .replaceFirst(RegExp(r'/+$'), '');
      final top = root.split('/').last;
      for (final f in Directory(
        root,
      ).listSync(recursive: true, followLinks: false).whereType<File>()) {
        final rel = f.path.replaceAll(r'\', '/').substring(root.length + 1);
        out.add(Picked(f.path, '$top/$rel'));
      }
    }
    return out;
  }

  Future<void> _sendPicked(String peerId, List<Picked> picked) async {
    final files = expandFolders(picked);
    if (files.length > 5000) {
      messages.add(
        'La carpeta tiene ${files.length} archivos; el máximo por envío es 5000.',
      );
      return;
    }
    if (files.isEmpty) return;
    final to = peers.where((p) => p.id == peerId).firstOrNull?.name ?? '';
    if (confirmSend != null && !await confirmSend!(files, to)) {
      for (final f in files) {
        if (f.fd != null) Native.closeFd(f.fd!);
      }
      return;
    }
    for (final f in files) {
      try {
        final id = await pb.sendFile(
          peerId: peerId,
          path: f.path,
          displayName: f.name,
        );
        if (f.fd != null) {
          _fds[id] = f.fd!;
          await Native.rememberFile(id, f.fd!);
        }
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

  @override
  void dispose() {
    // Release the Android lifecycle observer when the Hub is disposed.
    // Keeping the reference is intentional; it handles UI-only polling.
    _uiLifecycle?.dispose();
    super.dispose();
  }

  /// F10: every error code has a message and a next step.
  static String explain(String code, String message) => switch (code) {
    'NETWORK' => 'se perdió la conexión. Se reintenta sola; comprueba que ambos estén en la misma red Wi-Fi',
    'INTEGRITY' => 'el archivo llegó dañado. Vuelve a enviarlo',
    'REJECTED' => 'el otro dispositivo no lo aceptó',
    'PROTOCOL' =>
      'versiones incompatibles. Actualiza la app en ambos dispositivos',
    'INVALID_NAME' => 'el nombre del archivo no es válido',
    'CANCELLED' => 'cancelado',
    _ => message.isEmpty ? code : es(message),
  };
}
