import 'dart:async';

import 'package:flutter/foundation.dart';

import 'fs_client.dart';
import 'hub.dart';

/// Android-side browser for explicitly shared Windows folders.
/// All requests use the authenticated Alero peer channel, not ADB.
class PcFilesClient extends ChangeNotifier {
  PcFilesClient(this.hub);
  final Hub hub;
  String? peerId;
  List<FsRoot> roots = const [];
  String? root;
  String path = '';
  final crumbs = <(String, String)>[];
  List<FsEntry> entries = const [];
  bool loading = false;
  bool writable = false;
  String? error;
  int total = 0;
  Timer? _timeout;

  void _arm() {
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 8), () {
      if (loading) {
        loading = false;
        error ??= 'El ordenador no respondió. Comprueba que Alero esté conectado.';
        notifyListeners();
      }
    });
  }

  void open(String peer) {
    peerId = peer;
    root = null;
    roots = const [];
    path = '';
    crumbs.clear();
    entries = const [];
    writable = false;
    error = null;
    loading = true;
    hub.sendMessage(peer, 'pb.x.pcfs.roots.request', {});
    _arm();
    notifyListeners();
  }

  void selectRoot(String id) {
    if (peerId == null) return;
    root = id;
    path = '';
    crumbs.clear();
    list();
  }

  void enter(FsEntry item) {
    if (!item.dir) return;
    path = item.path;
    crumbs.add((item.name, item.path));
    list();
  }

  void up() {
    if (crumbs.isEmpty) {
      root = null;
      path = '';
      entries = const [];
      notifyListeners();
      return;
    }
    crumbs.removeLast();
    path = crumbs.isEmpty ? '' : crumbs.last.$2;
    list();
  }

  void list([int offset = 0]) {
    if (peerId == null || root == null) return;
    if (offset == 0) entries = const [];
    error = null;
    loading = true;
    hub.sendMessage(peerId!, 'pb.x.pcfs.list', {
      'root': root,
      'path': path,
      'offset': offset,
    });
    _arm();
    notifyListeners();
  }

  void download(FsEntry item) {
    if (peerId == null || root == null || item.dir) return;
    hub.expectFromPhone(item.name);
    hub.sendMessage(peerId!, 'pb.x.pcfs.get', {
      'root': root,
      'id': item.id,
    });
  }

  void rename(FsEntry item, String name) {
    if (!writable || peerId == null || root == null) return;
    hub.sendMessage(peerId!, 'pb.x.pcfs.rename', {
      'root': root,
      'id': item.id,
      'to': name,
    });
  }

  void delete(FsEntry item) {
    if (!writable || peerId == null || root == null || item.dir) return;
    hub.sendMessage(peerId!, 'pb.x.pcfs.delete', {
      'root': root,
      'id': item.id,
    });
  }

  void onMessage(String peer, String kind, Map<String, dynamic> body) {
    if (peer != peerId) return;
    switch (kind) {
      case 'pb.x.pcfs.roots':
        _timeout?.cancel();
        roots = [
          for (final obj in (body['roots'] as List? ?? []))
            if (obj is Map) FsRoot(obj),
        ];
        writable = body['writable'] == true;
        loading = false;
        error = null;
      case 'pb.x.pcfs.entries':
        if (body['root'] != root || body['path'] != path) return;
        _timeout?.cancel();
        final offset = (body['offset'] as num?)?.toInt() ?? 0;
        final next = [
          for (final obj in (body['entries'] as List? ?? []))
            if (obj is Map) FsEntry(obj),
        ];
        entries = offset == 0 ? next : [...entries, ...next];
        total = (body['total'] as num?)?.toInt() ?? entries.length;
        loading = false;
        error = null;
        if (next.isNotEmpty && entries.length < total) {
          list(entries.length);
          return;
        }
      case 'pb.x.pcfs.done':
        hub.messages.add(body['ok'] == true
            ? 'Archivo actualizado en Windows.'
            : 'Windows no pudo realizar el cambio solicitado.');
        list();
        return;
      case 'pb.x.pcfs.denied':
        _timeout?.cancel();
        loading = false;
        error = switch (body['reason']) {
          'not_allowed' => 'Windows no ha autorizado ninguna carpeta. Añade una carpeta en Alero para Windows › Ajustes.',
          'read_only' => 'La carpeta es de solo lectura. Windows debe autorizar cambios en sus ajustes.',
          'invalid_path' => 'Ruta rechazada por motivos de seguridad.',
          _ => 'El ordenador rechazó el acceso a este archivo.',
        };
      default:
        return;
    }
    notifyListeners();
  }

  void close() {
    _timeout?.cancel();
    peerId = null;
    roots = const [];
    entries = const [];
    crumbs.clear();
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }
}
