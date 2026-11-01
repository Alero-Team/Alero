import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../fs_client.dart';
import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'theme.dart';
import 'widgets.dart';

String _date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

String _ext(String name) =>
    name.contains('.') ? name.split('.').last.toUpperCase() : '';

/// The phone's files, on the computer (ADR-0011). It lists what the phone chooses to show (photos, videos, music,
/// Alero's received files and the folders its owner added) and asks it to send files; downloads and uploads are
/// the app's normal transfers, so they appear with progress, errors and retry in Archivos and under the list.
class ExplorerScreen extends StatefulWidget {
  const ExplorerScreen(this.hub, {super.key});
  final Hub hub;

  @override
  State<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends State<ExplorerScreen> {
  Hub get hub => widget.hub;
  FsClient get fs => hub.fs;

  pb.Peer? get _phone => hub.peers
      .where(
        (p) =>
            p.trusted &&
            p.state == pb.PeerState.connected &&
            hub.info[p.id]?.phone == true,
      )
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    _ensure();
    hub.addListener(_ensure);
  }

  @override
  void dispose() {
    hub.removeListener(_ensure);
    fs.close();
    super.dispose();
  }

  /// Starts (or restarts after a reconnection) the session with the phone that is connected now.
  void _ensure() {
    final p = _phone;
    if (p != null &&
        (fs.peerId != p.id ||
            (fs.roots.isEmpty && !fs.loading && fs.error == null))) {
      fs.open(p.id);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([hub, fs]),
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
                      child: Text(
                        phone == null
                            ? 'Explorador'
                            : 'Archivos de ${phone.name}',
                        style: t.headlineMedium,
                      ),
                    ),
                  ),
                  if (phone != null) ..._actions(context, phone),
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
                          body: 'Abre Alero en el teléfono emparejado (por Wi-Fi o con el cable) y aquí aparecerán sus archivos.',
                        ),
                      )
                    : _body(context, phone),
              ),
              if (hub.active.isNotEmpty) ...[
                const SizedBox(height: Gap.m),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 190),
                  child: Panel(
                    title: 'Transferencias en curso',
                    icon: Symbols.sync_rounded,
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          for (final x in hub.active) TransferRow(x, hub),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  List<Widget> _actions(BuildContext context, pb.Peer phone) {
    final chosen = fs.entries.where((e) => fs.selected.contains(e.id)).toList();
    return [
      if (chosen.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(right: Gap.s),
          child: FilledButton.icon(
            onPressed: () {
              fs.download(chosen);
              hub.messages.add(
                'Pidiendo ${chosen.length == 1 ? chosen.first.name : '${chosen.length} archivos'} al teléfono…',
              );
              fs.clearSelection();
            },
            icon: const Icon(Symbols.download_rounded, size: 18),
            label: Text('Descargar (${chosen.length})'),
          ),
        ),
      FilledButton.tonalIcon(
        onPressed: () => hub.send(phone.id),
        icon: const Icon(Symbols.upload_rounded, size: 18),
        label: const Text('Subir'),
      ),
      const SizedBox(width: Gap.xs),
      PopupMenuButton<String>(
        tooltip: 'Ordenar',
        icon: const Icon(Symbols.sort_rounded),
        initialValue: fs.sort,
        onSelected: fs.setSort,
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'name', child: Text('Por nombre')),
          PopupMenuItem(value: 'date', child: Text('Por fecha')),
          PopupMenuItem(value: 'size', child: Text('Por tamaño')),
        ],
      ),
      IconButton(
        tooltip: fs.grid ? 'Ver como lista' : 'Ver como cuadrícula',
        onPressed: fs.toggleView,
        icon: Icon(
          fs.grid ? Symbols.view_list_rounded : Symbols.grid_view_rounded,
        ),
      ),
      IconButton(
        tooltip: 'Actualizar',
        onPressed: fs.refresh,
        icon: const Icon(Symbols.refresh_rounded),
      ),
    ];
  }

  Widget _body(BuildContext context, pb.Peer phone) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    if (fs.error != null && fs.roots.isEmpty) {
      final (icon, title, body) = switch (fs.error) {
        'not_allowed' => (
          Symbols.lock_rounded,
          'El teléfono no lo permite todavía',
          'Le avisamos con una notificación. En el teléfono: Alero › Ajustes › Archivos para el ordenador, y activa «Dejar que el ordenador explore mis archivos».',
        ),
        'no_permission' => (
          Symbols.shield_rounded,
          'Falta un permiso en el teléfono',
          'Android pide permiso para ver fotos, vídeos y música. Concédelo en Alero › Ajustes › Permisos.',
        ),
        _ => (
          Symbols.signal_disconnected_rounded,
          'El teléfono no responde',
          'Comprueba que Alero está abierto y conectado, y vuelve a intentarlo.',
        ),
      };
      return Align(
        alignment: Alignment.topCenter,
        child: EmptyState(
          icon: icon,
          title: title,
          body: body,
          action: 'Volver a intentarlo',
          onAction: fs.refresh,
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          SizedBox(
            width: 220,
            child: ListView(
              padding: const EdgeInsets.all(Gap.m),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Gap.m,
                    Gap.s,
                    Gap.m,
                    Gap.s,
                  ),
                  child: Text(
                    'Ubicaciones',
                    style: t.labelLarge?.copyWith(color: s.onSurfaceVariant),
                  ),
                ),
                for (final r in fs.roots)
                  _RootItem(
                    r,
                    selected: r.id == fs.root,
                    onTap: r.ok ? () => fs.selectRoot(r.id) : null,
                  ),
                if (fs.roots.isEmpty && fs.loading)
                  const Padding(
                    padding: EdgeInsets.all(Gap.l),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),
          VerticalDivider(width: 1, color: s.outlineVariant),
          Expanded(child: _files(context)),
        ],
      ),
    );
  }

  Widget _files(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final list = fs.sorted;
    final root = fs.roots.where((r) => r.id == fs.root).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.s),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 2,
            children: [
              if (fs.crumbs.isNotEmpty)
                IconButton(
                  tooltip: 'Subir un nivel',
                  onPressed: fs.up,
                  icon: const Icon(Symbols.arrow_upward_rounded, size: 20),
                ),
              TextButton(
                onPressed: fs.crumbs.isEmpty ? null : () => fs.goTo(0),
                child: Text(root?.name ?? '…'),
              ),
              for (final (i, c) in fs.crumbs.indexed) ...[
                Icon(
                  Symbols.chevron_right_rounded,
                  size: 18,
                  color: s.onSurfaceVariant,
                ),
                TextButton(
                  onPressed: i == fs.crumbs.length - 1
                      ? null
                      : () => fs.goTo(i + 1),
                  child: Text(c.$1),
                ),
              ],
            ],
          ),
        ),
        if (fs.root == 'audio')
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.l,
              vertical: Gap.xs,
            ),
            child: Text(
              'Audio de más de 5 segundos · sin tonos, alarmas ni notificaciones',
              style: t.bodySmall,
            ),
          ),
        if (fs.loading) const LinearProgressIndicator(),
        Expanded(
          child: list.isEmpty && !fs.loading
              ? Center(
                  child: Text(
                    fs.error != null
                        ? 'No se pudo leer esta carpeta.'
                        : 'Esta carpeta está vacía.',
                    style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
                  ),
                )
              : fs.grid
              ? GridView.builder(
                  padding: const EdgeInsets.all(Gap.l),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 150,
                    mainAxisSpacing: Gap.m,
                    crossAxisSpacing: Gap.m,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: list.length,
                  itemBuilder: (_, i) => _GridTile(fs, list[i]),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Gap.m,
                    vertical: Gap.s,
                  ),
                  itemCount: list.length,
                  itemBuilder: (_, i) => _Row(fs, list[i]),
                ),
        ),
        if (fs.total > 0)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.l,
              vertical: Gap.s,
            ),
            child: Text(
              '${fs.total} elementos${fs.selected.isEmpty ? '' : ' · ${fs.selected.length} seleccionados'}',
              style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class _RootItem extends StatelessWidget {
  const _RootItem(this.r, {required this.selected, required this.onTap});
  final FsRoot r;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final icon = switch (r.kind) {
      'images' => Symbols.image_rounded,
      'video' => Symbols.movie_rounded,
      'audio' => Symbols.music_note_rounded,
      'alero' => Symbols.download_done_rounded,
      _ => Symbols.folder_rounded,
    };
    return Tooltip(
      message: r.ok
          ? r.name
          : r.id == 'storage'
          ? 'En el teléfono: Ajustes › Archivos para el ordenador › Todas las carpetas › Permitir'
          : 'Falta el permiso de Android para ver ${r.name.toLowerCase()}',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: selected ? s.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.pill),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.pill),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.m,
                vertical: 10,
              ),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 20,
                    fill: selected ? 1 : 0,
                    color: selected
                        ? s.onSecondaryContainer
                        : s.onSurfaceVariant,
                  ),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: Text(
                      r.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: selected ? s.onSecondaryContainer : s.onSurface,
                      ),
                    ),
                  ),
                  if (!r.ok)
                    Icon(
                      Symbols.lock_rounded,
                      size: 16,
                      color: s.onSurfaceVariant,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The picture of an entry: its thumbnail if the phone sent one, else an icon for its type.
class _Preview extends StatelessWidget {
  const _Preview(this.fs, this.e, {this.size = 56});
  final FsClient fs;
  final FsEntry e;
  final double size;

  @override
  Widget build(BuildContext context) {
    final kind = fileKind(e.name);
    final c = kindColors(context, kind);
    final wantsThumb =
        !e.dir &&
        (kind == FileKind.image ||
            kind == FileKind.video ||
            fs.root == 'images' ||
            fs.root == 'video');
    if (wantsThumb) fs.wantThumb(e);
    final bytes = wantsThumb ? fs.thumb('${fs.root}|${e.id}') : null;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: (size * 2).round(),
        semanticLabel: 'Miniatura de ${e.name}',
      );
    }
    final s = Theme.of(context).colorScheme;
    return ColoredBox(
      color: e.dir ? s.secondaryContainer : c.bg,
      child: Center(
        child: Icon(
          e.dir ? Symbols.folder_rounded : fileIcon(e.name),
          size: size * 0.5,
          fill: e.dir ? 1 : 0,
          color: e.dir ? s.onSecondaryContainer : c.fg,
        ),
      ),
    );
  }
}

class _GridTile extends StatelessWidget {
  const _GridTile(this.fs, this.e);
  final FsClient fs;
  final FsEntry e;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final sel = fs.selected.contains(e.id);
    return Semantics(
      button: true,
      selected: sel,
      label: '${e.name}${e.dir ? ', carpeta' : ''}',
      child: GestureDetector(
        onTap: () => e.dir ? fs.enter(e) : fs.toggle(e),
        onDoubleTap: e.dir ? null : () => fs.download([e], openWhenDone: true),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.tile),
            border: Border.all(
              color: sel ? s.primary : Colors.transparent,
              width: 2,
            ),
            color: sel
                ? s.primaryContainer.withValues(alpha: 0.4)
                : Colors.transparent,
          ),
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.chip),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _Preview(fs, e, size: 120),
                      if (sel)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: s.primary,
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(
                                Symbols.check_rounded,
                                size: 16,
                                color: s.onPrimary,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                e.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: t.bodySmall,
              ),
              Text(
                e.dir ? e.itemCount : size(e.size),
                maxLines: 1,
                textAlign: TextAlign.center,
                style: t.labelSmall?.copyWith(color: s.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.fs, this.e);
  final FsClient fs;
  final FsEntry e;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final sel = fs.selected.contains(e.id);
    return Material(
      color: sel
          ? s.primaryContainer.withValues(alpha: 0.4)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.tile),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.tile),
        onTap: () => e.dir ? fs.enter(e) : fs.toggle(e),
        onDoubleTap: e.dir ? null : () => fs.download([e], openWhenDone: true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: e.dir
                    ? null
                    : Icon(
                        sel
                            ? Symbols.check_box_rounded
                            : Symbols.check_box_outline_blank_rounded,
                        size: 20,
                        color: sel ? s.primary : s.onSurfaceVariant,
                      ),
              ),
              const SizedBox(width: Gap.s),
              ClipRRect(
                borderRadius: BorderRadius.circular(Radii.chip),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: _Preview(fs, e, size: 40),
                ),
              ),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: weight(t.bodyMedium, 500),
                ),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  e.dir ? 'Carpeta' : _ext(e.name),
                  style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                ),
              ),
              SizedBox(
                width: 90,
                child: Text(
                  e.dir ? e.itemCount : size(e.size),
                  textAlign: TextAlign.end,
                  style: t.bodySmall?.copyWith(
                    color: s.onSurfaceVariant,
                    fontFeatures: tabular,
                  ),
                ),
              ),
              SizedBox(
                width: 100,
                child: Text(
                  e.mtime.millisecondsSinceEpoch > 0 ? _date(e.mtime) : '',
                  textAlign: TextAlign.end,
                  style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
