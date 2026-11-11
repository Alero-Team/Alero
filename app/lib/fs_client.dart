import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'hub.dart';
import 'native.dart';

class FsRoot {
  FsRoot(Map j)
    : id = j['id'] as String? ?? '',
      name = j['name'] as String? ?? '',
      kind = j['kind'] as String? ?? '',
      ok = j['ok'] != false;
  final String id, name, kind;

  /// false: the phone lacks the Android permission for this library.
  final bool ok;
}

class FsEntry {
  FsEntry(Map j)
    : name = j['name'] as String? ?? '',
      dir = j['dir'] == true,
      size = (j['size'] as num?)?.toInt() ?? 0,
      mtime = DateTime.fromMillisecondsSinceEpoch(
        ((j['mtime'] as num?)?.toInt() ?? 0) * 1000,
      ),
      mime = j['mime'] as String? ?? '',
      id = j['id'] as String? ?? '',
      path = j['path'] as String? ?? '';
  final String name, mime, id, path;
  final bool dir;

  /// Bytes for a file; number of items for a folder.
  final int size;
  final DateTime mtime;
  String get itemCount => size < 0
      ? '—'
      : size >= 1000
      ? '999+ elementos'
      : '$size elementos';
}

/// The computer's side of browsing a phone's files (ADR-0011). It only asks (`pb.x.fs.*`): the phone decides what
/// it shows, and files travel as ordinary transfers, so progress, errors and retries are the app's usual ones.
class FsClient extends ChangeNotifier {
  FsClient(this.hub);
  final Hub hub;

  String? peerId;
  List<FsRoot> roots = [];
  String? root;
  String path = '';

  /// Names to show for each step below the root, and the path value that gets back to it.
  final crumbs = <(String, String)>[];
  List<FsEntry> entries = [];
  int total = 0;
  bool loading = false;

  /// null, or why the phone does not answer: not_allowed, no_permission, offline.
  String? error;
  bool grid = true;
  String sort = 'name'; // name | date | size
  final selected = <String>{};

  final _thumbs = <String, Uint8List>{};
  final _wanted = <String>{};
  final _thumbTimers = <String, Timer>{};
  Timer? _timeout, _debounce;

  Uint8List? thumb(String key) => _thumbs[key];

  void _clearPreviews() {
    for (final timer in _thumbTimers.values) {
      timer.cancel();
    }
    _thumbTimers.clear();
    _thumbs.clear();
    _wanted.clear();
  }

  /// Leaving the explorer releases its full listing and ignores late pages.
  void close() {
    _timeout?.cancel();
    _debounce?.cancel();
    _clearPreviews();
    peerId = null;
    root = null;
    path = '';
    roots = [];
    entries = [];
    crumbs.clear();
    selected.clear();
    total = 0;
    loading = false;
    error = null;
  }

  // --- session ----------------------------------------------------------------------------------------

  void open(String peer) {
    if (peerId == peer && roots.isNotEmpty && error == null) return;
    _clearPreviews();
    peerId = peer;
    error = null;
    roots = [];
    root = null;
    entries = [];
    _requestRoots();
  }

  void _requestRoots() {
    loading = true;
    hub.sendMessage(peerId!, 'pb.x.fs.roots.request', {});
    _arm();
    notifyListeners();
  }

  /// If the phone says nothing in a few seconds (asleep, out of range) the screen says so instead of spinning.
  void _arm() {
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 8), () {
      if (loading) {
        loading = false;
        error ??= 'offline';
        notifyListeners();
      }
    });
  }

  void _list([int offset = 0]) {
    final r = root;
    if (r == null || peerId == null) return;
    loading = true;
    hub.sendMessage(peerId!, 'pb.x.fs.list', {
      'root': r,
      'path': path,
      'offset': offset,
    });
    _arm();
    notifyListeners();
  }

  // --- navigation -------------------------------------------------------------------------------------

  void selectRoot(String id) {
    _clearPreviews();
    root = id;
    path = '';
    crumbs.clear();
    entries = [];
    selected.clear();
    error = null;
    _list();
  }

  void enter(FsEntry e) {
    if (!e.dir) return;
    _clearPreviews();
    crumbs.add((e.name, e.path));
    path = e.path;
    entries = [];
    selected.clear();
    _list();
  }

  void up() {
    if (crumbs.isEmpty) return;
    goTo(crumbs.length - 1);
  }

  /// `depth` 0 is the root, 1 the first folder…
  void goTo(int depth) {
    _clearPreviews();
    while (crumbs.length > depth) {
      crumbs.removeLast();
    }
    path = crumbs.isEmpty ? '' : crumbs.last.$2;
    entries = [];
    selected.clear();
    _list();
  }

  void refresh() {
    error = null;
    _requestRoots();
  }

  void setSort(String s) {
    sort = s;
    notifyListeners();
  }

  void toggleView() {
    grid = !grid;
    notifyListeners();
  }

  List<FsEntry> get sorted {
    final l = [...entries];
    int cmp(FsEntry a, FsEntry b) => switch (sort) {
      'date' => b.mtime.compareTo(a.mtime),
      'size' => b.size.compareTo(a.size),
      _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    };
    l.sort((a, b) => a.dir != b.dir ? (a.dir ? -1 : 1) : cmp(a, b));
    return l;
  }

  void clearSelection() {
    selected.clear();
    notifyListeners();
  }

  void toggle(FsEntry e) {
    if (e.dir) return;
    if (!selected.remove(e.id)) selected.add(e.id);
    notifyListeners();
  }

  // --- thumbnails -------------------------------------------------------------------------------------

  /// Asks for a picture's thumbnail once; at most four requests in flight so a big folder does not flood the phone.
  void wantThumb(FsEntry e) {
    final key = '$root|${e.id}';
    if (e.dir ||
        _thumbs.containsKey(key) ||
        _thumbTimers.containsKey(key) ||
        !_wanted.add(key)) {
      return;
    }
    _pump();
  }

  void _pump() {
    while (_thumbTimers.length < 4 && _wanted.isNotEmpty && peerId != null) {
      final key = _wanted.first;
      _wanted.remove(key);
      final i = key.indexOf('|');
      hub.sendMessage(peerId!, 'pb.x.fs.thumb', {
        'root': key.substring(0, i),
        'id': key.substring(i + 1),
      });
      // A phone that never answers must not hold a slot forever.
      _thumbTimers[key] = Timer(const Duration(seconds: 6), () {
        _thumbTimers.remove(key);
        _pump();
      });
    }
  }

  // --- files ------------------------------------------------------------------------------------------

  /// Asks the phone to send these files; the transfers show up in Files with progress and retry.
  void download(Iterable<FsEntry> files, {bool openWhenDone = false}) {
    for (final f in files.where((f) => !f.dir)) {
      hub.expectFromPhone(peerId!, f.name, open: openWhenDone);
      hub.sendMessage(peerId!, 'pb.x.fs.get', {
        'root': root,
        'id': f.id,
        'name': f.name,
      });
    }
  }

  /// Asks the phone to send a whole folder; it arrives in Downloads with its subfolders.
  void downloadDir(FsEntry e) => hub.sendMessage(peerId!, 'pb.x.fs.getdir', {
    'root': root,
    'path': e.path,
    'name': e.name,
  });

  /// Asks the phone to delete these files or folders (a folder goes with everything inside).
  void delete(Iterable<FsEntry> items) {
    for (final e in items) {
      hub.sendMessage(peerId!, 'pb.x.fs.delete', _ref(e));
    }
    selected.clear();
    notifyListeners();
  }

  void rename(FsEntry e, String to) =>
      hub.sendMessage(peerId!, 'pb.x.fs.rename', {..._ref(e), 'to': to.trim()});

  Map<String, Object?> _ref(FsEntry e) => {
    'root': root,
    'id': e.id,
    'path': e.path,
    'dir': e.dir,
    'name': e.name,
  };

  static String doneMessage(Map b) {
    final name = b['name'] as String? ?? '';
    final verb = b['op'] == 'rename' ? 'renombrar' : 'eliminar';
    if (b['ok'] == true) {
      return b['op'] == 'rename' ? 'Renombrado: $name' : 'Eliminado: $name';
    }
    return 'No se pudo $verb $name: ${switch (b['reason']) {
      'bad_name' => 'el nombre no es válido.',
      'exists' => 'ya existe otro con ese nombre.',
      'missing' => 'ya no existe en el teléfono.',
      'read_only' => 'la carpeta es de solo lectura. Quítala y vuelve a añadirla en el teléfono.',
      'needs_all_files' => 'Android solo lo permite con «Todas las carpetas» activado en el teléfono.',
      'no_permission' => 'falta un permiso en el teléfono.',
      'unsupported' => 'esta ubicación no lo permite.',
      _ => 'el teléfono lo rechazó.',
    }}';
  }

  // --- what the phone says ----------------------------------------------------------------------------

  void onMessage(String peer, String kind, Map<String, dynamic> b) {
    if (peer != peerId) return;
    switch (kind) {
      case 'pb.x.fs.roots':
        _timeout?.cancel();
        roots = [
          for (final r in (b['roots'] as List? ?? []))
            if (r is Map) FsRoot(r),
        ];
        error = null;
        loading = false;
        if (root == null || !roots.any((r) => r.id == root)) {
          // ALERO_FS_ROOT=alero (etc.) picks the first location: for screenshots and manual checks.
          final want = Platform.environment['ALERO_FS_ROOT'];
          final first =
              roots
                  .where((r) => r.ok && (want == null || r.id == want))
                  .firstOrNull ??
              roots.where((r) => r.ok).firstOrNull;
          if (first != null) {
            selectRoot(first.id);
            return;
          }
        } else {
          _list();
          return;
        }
      case 'pb.x.fs.entries':
        if (b['root'] != root || (b['path'] as String? ?? '') != path) return;
        _timeout?.cancel();
        final offset = (b['offset'] as num?)?.toInt() ?? 0;
        final page = [
          for (final e in (b['entries'] as List? ?? []))
            if (e is Map) FsEntry(e),
        ];
        entries = offset == 0 ? page : [...entries, ...page];
        total = (b['total'] as num?)?.toInt() ?? entries.length;
        loading = false;
        if (entries.length < total && page.isNotEmpty) _list(entries.length);
      case 'pb.x.fs.thumb.data':
        final key = '${b['root']}|${b['id']}';
        try {
          _thumbs[key] = base64Decode(b['jpeg'] as String);
          if (_thumbs.length > 500) _thumbs.remove(_thumbs.keys.first);
        } catch (_) {
          // damaged: the placeholder stays
        }
        _thumbTimers.remove(key)?.cancel();
        _pump();
      case 'pb.x.fs.denied':
        _timeout?.cancel();
        loading = false;
        error = b['reason'] as String? ?? 'not_allowed';
      case 'pb.x.fs.dir':
        final n = (b['files'] as num?)?.toInt() ?? 0;
        hub.messages.add(
          n == 0
              ? 'La carpeta ${b['name']} está vacía.'
              : 'Recibiendo ${b['name']}: $n ${n == 1 ? 'archivo' : 'archivos'}…',
        );
        return;
      case 'pb.x.fs.done':
        hub.messages.add(doneMessage(b));
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 400), () => _list());
        return;
      case 'pb.x.fs.changed':
        // Something changed on the phone: list again, once, a moment after the last change.
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 600), refresh);
        return;
    }
    notifyListeners();
  }

  /// Opens a downloaded file with the system's default app (a picture viewer, a player…).
  static Future<void> openFile(String path) => Native.openFile(path);

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
