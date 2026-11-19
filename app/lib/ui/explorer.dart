import 'alero_motion.dart';

import 'package:flutter/material.dart' hide Icon, Text;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../fs_client.dart';
import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'phone_page.dart';
import 'shell.dart' show confirm;
import 'theme.dart';
import 'widgets.dart';
import 'icon.dart';
import '../l10n.dart';
import 'expressive.dart';
import 'controls.dart' show Presence;

String _date(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  // Day first in Spanish; year first in English, which every reader can tell apart.
  return L10n.instance.en
      ? '${d.year}-${two(d.month)}-${two(d.day)}'
      : '${two(d.day)}/${two(d.month)}/${d.year}';
}

String _ext(String name) =>
    name.contains('.') ? name.split('.').last.toUpperCase() : '';

/// Asks before deleting: nothing on the phone goes to a trash can.
Future<void> _delete(
  BuildContext context,
  FsClient fs,
  List<FsEntry> items,
) async {
  if (items.isEmpty) return;
  final one = items.length == 1 ? items.first : null;
  final ok = await confirm(
    context,
    one == null
        ? tr('¿Eliminar {} elementos?', [items.length])
        : tr('¿Eliminar «{}»?', [one.name]),
    tr('{} del teléfono. No se puede deshacer.', [
      one?.dir == true
          ? 'La carpeta y todo su contenido se borrarán'
          : 'Se borrará',
    ]),
    'Eliminar',
  );
  if (ok) fs.delete(items);
}

Future<void> _rename(BuildContext context, FsClient fs, FsEntry e) async {
  final c = TextEditingController(text: e.name);
  final dot = e.dir ? -1 : e.name.lastIndexOf('.');
  c.selection = TextSelection(
    baseOffset: 0,
    extentOffset: dot > 0 ? dot : e.name.length,
  );
  final to = await showAleroDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Renombrar'),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(labelText: tx('Nombre nuevo')),
        onSubmitted: (v) => Navigator.pop(d, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(d, c.text),
          child: const Text('Renombrar'),
        ),
      ],
    ),
  );
  // Not disposed here: the dialog's closing animation still reads it.
  if (to != null && to.trim().isNotEmpty && to.trim() != e.name) {
    fs.rename(e, to);
  }
}

/// Right click or long press on an entry.
Future<void> _menu(
  BuildContext context,
  FsClient fs,
  FsEntry e,
  Offset at,
) async {
  final size = MediaQuery.sizeOf(context);
  final pick = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
      at.dx,
      at.dy,
      size.width - at.dx,
      size.height - at.dy,
    ),
    items: [
      PopupMenuItem(
        value: 'open',
        child: ListTile(
          leading: Icon(
            e.dir ? FluentIcons.folder_open_24_regular : FluentIcons.open_24_regular,
          ),
          title: Text(e.dir ? 'Abrir' : 'Abrir en el ordenador'),
        ),
      ),
      if (e.dir && fs.root != 'images' && fs.root != 'video')
        const PopupMenuItem(
          value: 'downloadDir',
          child: ListTile(
            leading: Icon(FluentIcons.arrow_download_24_regular),
            title: Text('Descargar carpeta'),
          ),
        ),
      if (!e.dir)
        const PopupMenuItem(
          value: 'download',
          child: ListTile(
            leading: Icon(FluentIcons.arrow_download_24_regular),
            title: Text('Descargar'),
          ),
        ),
      const PopupMenuItem(
        value: 'rename',
        child: ListTile(
          leading: Icon(FluentIcons.edit_24_regular),
          title: Text('Renombrar'),
        ),
      ),
      PopupMenuItem(
        value: 'delete',
        child: ListTile(
          leading: Icon(
            FluentIcons.delete_24_regular,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text(
            'Eliminar',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ),
    ],
  );
  if (!context.mounted) return;
  switch (pick) {
    case 'open':
      e.dir ? fs.enter(e) : fs.download([e], openWhenDone: true);
    case 'download':
      fs.download([e]);
    case 'downloadDir':
      fs.downloadDir(e);
    case 'rename':
      await _rename(context, fs, e);
    case 'delete':
      await _delete(context, fs, [e]);
  }
}

/// The phone's files, on the computer. It lists what the phone chooses to show (photos, videos, music,
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
  // Folder changes slide forward when going in and back when going up.
  int _depth = 0;
  bool _forward = true;

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
                            : tr('Archivos de {}', [phone.name]),
                        style: t.headlineMedium,
                      ),
                    ),
                  ),
                  if (phone != null) ..._actions(context, phone),
                ],
              ),
              const SizedBox(height: Gap.l),
              Expanded(
                child: MotionSwitch(
                  axis: Axis.vertical,
                  child: KeyedSubtree(
                    key: ValueKey(
                      phone == null
                          ? 'none'
                          : fs.error != null && fs.roots.isEmpty
                          ? 'error-${fs.error}'
                          : 'files',
                    ),
                    child: phone == null
                        ? const Align(
                            alignment: Alignment.topCenter,
                            child: EmptyState(
                              icon: FluentIcons.phone_24_regular,
                              title: 'Conecta un teléfono',
                              body: 'Abre Alero en el teléfono emparejado (por Wi-Fi o con el cable) y aquí aparecerán sus archivos.',
                            ),
                          )
                        : _body(context, phone),
                  ),
                ),
              ),
              Presence(
                child: hub.active.isEmpty
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(top: Gap.m),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 190),
                          child: Panel(
                            title: 'Transferencias en curso',
                            icon: FluentIcons.arrow_sync_24_regular,
                            child: SingleChildScrollView(
                              child: Column(
                                children: [
                                  for (final x in hub.active)
                                    TransferRow(x, hub),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );

  List<Widget> _actions(BuildContext context, pb.Peer phone) {
    final chosen = fs.entries.where((e) => fs.selected.contains(e.id)).toList();
    return [
      Presence(
        alignment: Alignment.centerRight,
        child: chosen.isEmpty
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.s),
                    child: FilledButton.icon(
                      onPressed: () {
                        fs.download(chosen);
                        hub.messages.add(
                          tr('Pidiendo {} al teléfono…', [
                            chosen.length == 1
                                ? chosen.first.name
                                : tr('{} archivos', [chosen.length]),
                          ]),
                        );
                        fs.clearSelection();
                      },
                      icon: const Icon(FluentIcons.arrow_download_24_regular, size: 18),
                      label: Text(tr('Descargar ({})', [chosen.length])),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.s),
                    child: IconButton.filledTonal(
                      tooltip: tr('Eliminar ({})', [chosen.length]),
                      onPressed: () => _delete(context, fs, chosen),
                      icon: const Icon(FluentIcons.delete_24_regular),
                    ),
                  ),
                ],
              ),
      ),
      FilledButton.tonalIcon(
        onPressed: () => hub.send(phone.id),
        icon: const Icon(FluentIcons.arrow_upload_24_regular, size: 18),
        label: const Text('Subir'),
      ),
      const SizedBox(width: Gap.xs),
      FilledButton.tonalIcon(
        onPressed: () => hub.sendFolder(phone.id),
        icon: const Icon(FluentIcons.folder_arrow_up_24_regular, size: 18),
        label: const Text('Subir carpeta'),
      ),
      const SizedBox(width: Gap.xs),
      PopupMenuButton<String>(
        popUpAnimationStyle: popUpMotion(context),
        tooltip: tx('Ordenar'),
        icon: const Icon(FluentIcons.arrow_sort_24_regular),
        initialValue: fs.sort,
        onSelected: fs.setSort,
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'name', child: Text('Por nombre')),
          PopupMenuItem(value: 'date', child: Text('Por fecha')),
          PopupMenuItem(value: 'size', child: Text('Por tamaño')),
        ],
      ),
      IconButton(
        tooltip: tx(fs.grid ? 'Ver como lista' : 'Ver como cuadrícula'),
        onPressed: fs.toggleView,
        icon: Icon(
          fs.grid ? FluentIcons.text_bullet_list_ltr_24_regular : FluentIcons.grid_24_regular,
        ),
      ),
      IconButton(
        tooltip: tx('Actualizar'),
        onPressed: fs.refresh,
        icon: const Icon(FluentIcons.arrow_clockwise_24_regular),
      ),
    ];
  }

  Widget _body(BuildContext context, pb.Peer phone) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    if (fs.error != null && fs.roots.isEmpty) {
      final (icon, title, body) = switch (fs.error) {
        'not_allowed' => (
          FluentIcons.lock_closed_24_regular,
          'El teléfono no lo permite todavía',
          'Le avisamos con una notificación. En el teléfono: Alero › Ajustes › Archivos para el ordenador, y activa «Dejar que el ordenador explore mis archivos».',
        ),
        'no_permission' => (
          FluentIcons.shield_24_regular,
          'Falta un permiso en el teléfono',
          'Android pide permiso para ver fotos, vídeos y música. Concédelo en Alero › Ajustes › Permisos.',
        ),
        _ => (
          FluentIcons.plug_disconnected_24_regular,
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
                // The highlight glides between locations; the items draw no background of their own.
                SlidingSelection(
                  selected: fs.roots.indexWhere((r) => r.id == fs.root),
                  color: s.secondaryContainer,
                  radius: Radii.pill,
                  inset: const EdgeInsets.only(bottom: 2),
                  children: [
                    for (final r in fs.roots)
                      _RootItem(
                        r,
                        selected: r.id == fs.root,
                        onTap: r.ok ? () => fs.selectRoot(r.id) : null,
                      ),
                  ],
                ),
                Presence(
                  child: fs.roots.isEmpty && fs.loading
                      ? const Padding(
                          padding: EdgeInsets.all(Gap.l),
                          child: LinearProgressIndicator(),
                        )
                      : null,
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
    if (fs.crumbs.length != _depth) {
      _forward = fs.crumbs.length > _depth;
      _depth = fs.crumbs.length;
    }
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
                  tooltip: tx('Subir un nivel'),
                  onPressed: fs.up,
                  icon: const Icon(FluentIcons.arrow_up_24_regular, size: 20),
                ),
              TextButton(
                onPressed: fs.crumbs.isEmpty ? null : () => fs.goTo(0),
                child: Text(root?.name ?? '…'),
              ),
              for (final (i, c) in fs.crumbs.indexed) ...[
                Icon(
                  FluentIcons.chevron_right_24_regular,
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
        Presence(
          child: fs.root == 'audio'
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Gap.l,
                    vertical: Gap.xs,
                  ),
                  child: Text(
                    'Audio de más de 5 segundos · sin tonos, alarmas ni notificaciones',
                    style: t.bodySmall,
                  ),
                )
              : null,
        ),
        Presence(child: fs.loading ? const LinearProgressIndicator() : null),
        Expanded(
          child: MotionSwitch(
            forward: _forward,
            child: KeyedSubtree(
              // One key per folder and state: a new folder slides in, the same one just fills.
              key: ValueKey(
                '${fs.root}|${fs.crumbs.map((c) => c.$1).join('/')}|${fs.grid}|${list.isEmpty && !fs.loading}',
              ),
              child: list.isEmpty && !fs.loading
                  ? Center(
                      child: Text(
                        fs.error != null
                            ? 'No se pudo leer esta carpeta.'
                            : 'Esta carpeta está vacía.',
                        style: t.bodyMedium?.copyWith(
                          color: s.onSurfaceVariant,
                        ),
                      ),
                    )
                  : fs.grid
                  ? _Scrolled(
                      (c) => GridView.builder(
                        controller: c,
                        padding: const EdgeInsets.all(Gap.l),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 150,
                              mainAxisSpacing: Gap.m,
                              crossAxisSpacing: Gap.m,
                              childAspectRatio: 0.82,
                            ),
                        itemCount: list.length,
                        itemBuilder: (_, i) => AleroMotion.reveal(
                          context,
                          i,
                          _GridTile(fs, list[i]),
                        ),
                      ),
                    )
                  : _Scrolled(
                      (c) => ListView.builder(
                        controller: c,
                        padding: const EdgeInsets.symmetric(
                          horizontal: Gap.m,
                          vertical: Gap.s,
                        ),
                        itemCount: list.length,
                        itemBuilder: (_, i) =>
                            AleroMotion.reveal(context, i, _Row(fs, list[i])),
                      ),
                    ),
            ),
          ),
        ),
        Presence(
          child: fs.total > 0
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Gap.l,
                    vertical: Gap.s,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AleroMotion.number(
                      tr('{} elementos{}', [
                        fs.total,
                        fs.selected.isEmpty
                            ? ''
                            : tr(' · {} seleccionados', [fs.selected.length]),
                      ]),
                      t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                    ),
                  ),
                )
              : null,
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
      'images' => FluentIcons.image_24_regular,
      'video' => FluentIcons.movies_and_tv_24_regular,
      'audio' => FluentIcons.music_note_2_24_regular,
      'alero' => FluentIcons.arrow_download_24_regular,
      _ => FluentIcons.folder_24_regular,
    };
    return Tooltip(
      message: r.ok
          ? tx(r.name)
          : r.id == 'storage'
          ? tx(
              'En el teléfono: Ajustes › Archivos para el ordenador › Todas las carpetas › Permitir',
            )
          : tr('Falta el permiso de Android para ver {}', [
              r.name.toLowerCase(),
            ]),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: AleroPress(
          radius: Radii.pill,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.m,
              vertical: 10,
            ),
            child: TweenValue(
              selected ? 1 : 0,
              builder: (_, v) => Row(
                children: [
                  Icon(
                    icon,
                    size: 20,
                    fill: selected ? 1 : 0,
                    color: Color.lerp(
                      s.onSurfaceVariant,
                      s.onSecondaryContainer,
                      v,
                    ),
                  ),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: Text(
                      r.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Color.lerp(
                          s.onSurface,
                          s.onSecondaryContainer,
                          v,
                        ),
                      ),
                    ),
                  ),
                  if (!r.ok)
                    Icon(
                      FluentIcons.lock_closed_24_regular,
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
        semanticLabel: tr('Miniatura de {}', [e.name]),
      );
    }
    final s = Theme.of(context).colorScheme;
    return ColoredBox(
      color: e.dir ? s.secondaryContainer : c.bg,
      child: Center(
        child: Icon(
          e.dir ? FluentIcons.folder_24_regular : fileIcon(e.name),
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
      // The press tints and shrinks; double tap, right click and long press stay on the outer detector.
      child: GestureDetector(
        onDoubleTap: e.dir ? null : () => fs.download([e], openWhenDone: true),
        onSecondaryTapUp: (d) => _menu(context, fs, e, d.globalPosition),
        onLongPressStart: (d) => _menu(context, fs, e, d.globalPosition),
        child: AleroPress(
          radius: Radii.tile,
          onTap: () => e.dir ? fs.enter(e) : fs.toggle(e),
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
                        // Always mounted: it pops in and out instead of appearing.
                        Positioned(
                          top: 6,
                          right: 6,
                          child: AnimatedScale(
                            scale: sel ? 1 : 0,
                            duration: AleroMotion.micro(context, Fluent.d167),
                            curve: Fluent.enter,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: s.primary,
                                shape: BoxShape.circle,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  FluentIcons.checkmark_24_regular,
                                  size: 16,
                                  color: s.onPrimary,
                                ),
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
      child: GestureDetector(
        onDoubleTap: e.dir ? null : () => fs.download([e], openWhenDone: true),
        onSecondaryTapUp: (d) => _menu(context, fs, e, d.globalPosition),
        child: AleroPress(
          radius: Radii.tile,
          onTap: () => e.dir ? fs.enter(e) : fs.toggle(e),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: e.dir
                      ? null
                      : MotionFade(
                          child: Icon(
                            sel
                                ? FluentIcons.checkbox_checked_24_regular
                                : FluentIcons.checkbox_unchecked_24_regular,
                            key: ValueKey(sel),
                            size: 20,
                            color: sel ? s.primary : s.onSurfaceVariant,
                          ),
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
                Builder(
                  builder: (b) => IconButton(
                    tooltip: tx('Más opciones'),
                    iconSize: 20,
                    onPressed: () {
                      final box = b.findRenderObject()! as RenderBox;
                      _menu(
                        context,
                        fs,
                        e,
                        box.localToGlobal(box.size.center(Offset.zero)),
                      );
                    },
                    icon: const Icon(FluentIcons.more_vertical_24_regular),
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

/// A scroll view with its own controller, so two of them mounted while a folder switch plays never share the primary one.
class _Scrolled extends StatefulWidget {
  const _Scrolled(this.build);
  final Widget Function(ScrollController) build;

  @override
  State<_Scrolled> createState() => _ScrolledState();
}

class _ScrolledState extends State<_Scrolled> {
  final _c = ScrollController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.build(_c);
}

/// "Fotos": the phone's photos (or videos), newest first, as a big grid. Same session, thumbnails and actions
/// as the explorer; click selects, double click opens on the computer, right click for more.
class PhotosScreen extends StatefulWidget {
  const PhotosScreen(this.hub, {super.key});
  final Hub hub;

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  Hub get hub => widget.hub;
  FsClient get fs => hub.fs;
  String _kind = 'images';

  @override
  void initState() {
    super.initState();
    fs.sort = 'date';
    fs.grid = true;
    hub.addListener(_ensure);
    fs.addListener(_pick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensure());
  }

  @override
  void dispose() {
    hub.removeListener(_ensure);
    fs.removeListener(_pick);
    fs.close();
    super.dispose();
  }

  void _ensure() {
    final p = hub.connectedPhone;
    if (p != null &&
        (fs.peerId != p.id ||
            (fs.roots.isEmpty && !fs.loading && fs.error == null))) {
      fs.open(p.id);
    }
  }

  /// The explorer opens the first location; this screen wants the photo (or video) library.
  void _pick() {
    if (fs.root != _kind && fs.roots.any((r) => r.id == _kind && r.ok)) {
      fs.selectRoot(_kind);
    }
  }

  @override
  Widget build(BuildContext context) => PhonePage(
    hub: hub,
    title: 'Fotos',
    actions: (phone) => [
      ListenableBuilder(
        listenable: fs,
        builder: (context, _) {
          final chosen = fs.entries
              .where((e) => fs.selected.contains(e.id))
              .toList();
          return Row(
            children: [
              Presence(
                alignment: Alignment.centerRight,
                child: chosen.isEmpty
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FilledButton.icon(
                            onPressed: () {
                              fs.download(chosen);
                              fs.clearSelection();
                            },
                            icon: const Icon(
                              FluentIcons.arrow_download_24_regular,
                              size: 18,
                            ),
                            label: Text(tr('Descargar ({})', [chosen.length])),
                          ),
                          const SizedBox(width: Gap.s),
                          IconButton.filledTonal(
                            tooltip: tr('Eliminar ({})', [chosen.length]),
                            onPressed: () => _delete(context, fs, chosen),
                            icon: const Icon(FluentIcons.delete_24_regular),
                          ),
                          const SizedBox(width: Gap.s),
                        ],
                      ),
              ),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'images',
                    label: FitLabel('Fotos'),
                    icon: Icon(FluentIcons.image_24_regular),
                  ),
                  ButtonSegment(
                    value: 'video',
                    label: FitLabel('Vídeos'),
                    icon: Icon(FluentIcons.movies_and_tv_24_regular),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (v) {
                  setState(() => _kind = v.first);
                  _pick();
                },
              ),
              IconButton(
                tooltip: tx('Actualizar'),
                onPressed: fs.refresh,
                icon: const Icon(FluentIcons.arrow_clockwise_24_regular),
              ),
            ],
          );
        },
      ),
    ],
    body: (context, phone) => ListenableBuilder(
      listenable: fs,
      builder: (context, _) {
        final s = Theme.of(context).colorScheme;
        final root = fs.roots.where((r) => r.id == _kind).firstOrNull;
        final locked =
            fs.error == 'not_allowed' ||
            (root != null && !root.ok) ||
            fs.error == 'no_permission';
        final list = fs.root == _kind ? fs.sorted : const <FsEntry>[];
        final state = locked
            ? 'locked'
            : list.isEmpty
            ? (fs.loading ? 'loading' : 'empty')
            : 'grid-$_kind';
        return MotionSwitch(
          forward: _kind == 'video',
          child: KeyedSubtree(
            key: ValueKey(state),
            child: locked
                ? const Align(
                    alignment: Alignment.topCenter,
                    child: EmptyState(
                      icon: FluentIcons.lock_closed_24_regular,
                      title: 'El teléfono aún no comparte sus fotos',
                      body: 'En el teléfono: Alero › Ajustes › Archivos para el ordenador, y concede «Fotos y vídeos».',
                    ),
                  )
                : list.isEmpty
                ? Center(
                    child: fs.loading
                        ? const CircularProgressIndicator()
                        : Text(
                            'No hay nada aquí.',
                            style: TextStyle(color: s.onSurfaceVariant),
                          ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Presence(
                        child: fs.loading
                            ? const LinearProgressIndicator()
                            : null,
                      ),
                      Expanded(
                        child: _Scrolled(
                          (c) => GridView.builder(
                            controller: c,
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 200,
                                  mainAxisSpacing: Gap.m,
                                  crossAxisSpacing: Gap.m,
                                  childAspectRatio: 0.85,
                                ),
                            itemCount: list.length,
                            itemBuilder: (_, i) => AleroMotion.reveal(
                              context,
                              i,
                              _GridTile(fs, list[i]),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: Gap.s),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: AleroMotion.number(
                            tr('{} elementos{}', [
                              fs.total,
                              fs.selected.isEmpty
                                  ? ''
                                  : tr(' · {} seleccionados', [
                                      fs.selected.length,
                                    ]),
                            ]),
                            Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: s.onSurfaceVariant),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    ),
  );
}
