import 'dart:io';

import 'package:flutter/material.dart' hide Icon, Text;
import 'package:flutter/material.dart' as m show Icon;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../hub.dart';
import '../native.dart';
import '../src/rust/api/engine.dart' as pb;
import 'expressive.dart';
import 'alero_motion.dart';
import 'theme.dart';
import 'icon.dart';
import '../l10n.dart';

String size(int b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

const tabular = [FontFeature.tabularFigures()];

/// A titled section card: the building block of every screen (title, optional action, content).
/// How roomy Home's tiles are (Personalizar › Tamaño de los mosaicos): scales their padding and spacing.
class TileScale extends InheritedWidget {
  const TileScale(this.factor, {super.key, required super.child});
  final double factor;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TileScale>()?.factor ?? 1;

  /// A number from the slider ("1.15"), or one of the old presets.
  static double forSize(String size) =>
      double.tryParse(size)?.clamp(minFactor, maxFactor) ??
      switch (size) {
        'compact' => 0.75,
        'large' => 1.3,
        _ => 1,
      };

  static const minFactor = 0.7, maxFactor = 1.5;

  @override
  bool updateShouldNotify(TileScale old) => old.factor != factor;
}

/// Resizes Home's tiles for real: spacing, text and icons, shrunk on narrow screens so nothing overflows.
class ScaledTiles extends StatelessWidget {
  const ScaledTiles(this.factor, {super.key, required this.child});
  final double factor;
  final Widget child;

  /// The factor this screen can hold: phones under 400 dp wide get proportionally less.
  static double fit(BuildContext context, double factor) =>
      factor * (MediaQuery.sizeOf(context).width / 400).clamp(0.85, 1.0);

  @override
  Widget build(BuildContext context) {
    final f = fit(context, factor);
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(
        textScaler: TextScaler.linear(mq.textScaler.scale(14) / 14 * f),
      ),
      child: IconTheme.merge(
        data: IconThemeData(size: 24 * f),
        child: TileScale(f, child: child),
      ),
    );
  }
}

/// A button's label that never wraps or spills out: on a narrow button or with big text it shrinks to fit.
class FitLabel extends StatelessWidget {
  const FitLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(text, maxLines: 1, softWrap: false),
  );
}

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.title,
    this.icon,
    this.action,
    required this.child,
    this.padding,
  });
  final String title;
  final IconData? icon;
  final Widget? action;
  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Entrance(
      child: Card(
        child: Padding(
          padding:
              padding ??
              const EdgeInsets.fromLTRB(Gap.l + 4, Gap.m, Gap.m, Gap.l) *
                  TileScale.of(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 20, color: context.pal.muted),
                      const SizedBox(width: Gap.s),
                    ],
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: t.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    ?action,
                  ],
                ),
              ),
              const SizedBox(height: Gap.xs),
              // Content that grows or shrinks (a list, an expanded section) moves instead of jumping.
              AnimatedSize(
                // Resizing the window must follow the pointer, not lag behind it.
                duration: Entrance.quiet
                    ? Duration.zero
                    : motion(context, Spring.spatial.settle),
                curve: Spring.spatial,
                alignment: Alignment.topCenter,
                child: child,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One wording, icon and color per peer state, used everywhere. Color is never the only signal.
({String label, IconData icon, Color color}) peerStatus(
  BuildContext context,
  pb.Peer p,
) {
  final c = context.pal;
  return switch (p.state) {
    pb.PeerState.connected => (
      label: 'Conectado',
      icon: FluentIcons.link_24_regular,
      color: c.signal,
    ),
    pb.PeerState.connecting => (
      label: 'Conectando…',
      icon: FluentIcons.arrow_sync_24_regular,
      color: c.muted,
    ),
    pb.PeerState.rejected => (
      label: 'Te quitó de sus dispositivos',
      icon: FluentIcons.prohibited_24_regular,
      color: c.danger,
    ),
    pb.PeerState.disconnected when p.trusted && p.detail == 'paused' => (
      label: 'Desconectado por ti',
      icon: FluentIcons.pause_circle_24_regular,
      color: c.muted,
    ),
    pb.PeerState.disconnected when p.trusted && p.detail == 'paused_remote' => (
      label: 'Desconectado desde el otro dispositivo',
      icon: FluentIcons.pause_circle_24_regular,
      color: c.muted,
    ),
    pb.PeerState.disconnected =>
      p.trusted
          ? (
              label: 'Sin conexión',
              icon: FluentIcons.link_dismiss_24_regular,
              color: c.muted,
            )
          : (
              label: 'Disponible',
              icon: FluentIcons.link_add_24_regular,
              color: c.muted,
            ),
  };
}

class StatusLine extends StatelessWidget {
  const StatusLine(this.peer, {super.key});
  final pb.Peer peer;

  @override
  Widget build(BuildContext context) {
    final s = peerStatus(context, peer);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: motion(context, const Duration(milliseconds: 300)),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: s.color, shape: BoxShape.circle),
        ),
        const SizedBox(width: Gap.s),
        Flexible(
          child: MotionFade(
            child: Text(
              s.label,
              key: ValueKey(s.label),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ),
      ],
    );
  }
}

enum FileKind { image, video, audio, doc, sheet, archive, app, other }

/// One rule per file type, same on every platform: an icon and a tonal color pair (measured ≥ 4.5:1).
FileKind fileKind(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'jpg' ||
    'jpeg' ||
    'png' ||
    'gif' ||
    'webp' ||
    'heic' ||
    'bmp' ||
    'svg' ||
    'avif' => FileKind.image,
    'mp4' || 'mkv' || 'mov' || 'avi' || 'webm' || '3gp' => FileKind.video,
    'mp3' ||
    'flac' ||
    'wav' ||
    'ogg' ||
    'm4a' ||
    'opus' ||
    'aac' => FileKind.audio,
    'pdf' ||
    'doc' ||
    'docx' ||
    'odt' ||
    'txt' ||
    'md' ||
    'rtf' ||
    'ppt' ||
    'pptx' ||
    'odp' => FileKind.doc,
    'xls' || 'xlsx' || 'ods' || 'csv' => FileKind.sheet,
    'zip' || 'rar' || '7z' || 'tar' || 'gz' || 'xz' => FileKind.archive,
    'apk' || 'exe' || 'msi' || 'deb' || 'appimage' => FileKind.app,
    _ => FileKind.other,
  };
}

IconData fileIcon(String name) => switch (fileKind(name)) {
  FileKind.image => FluentIcons.image_24_regular,
  FileKind.video => FluentIcons.movies_and_tv_24_regular,
  FileKind.audio => FluentIcons.music_note_2_24_regular,
  FileKind.doc => FluentIcons.document_text_24_regular,
  FileKind.sheet => FluentIcons.table_24_regular,
  FileKind.archive => FluentIcons.folder_zip_24_regular,
  FileKind.app => FluentIcons.app_generic_24_regular,
  FileKind.other => FluentIcons.document_24_regular,
};

({Color bg, Color fg}) kindColors(BuildContext c, FileKind k) {
  final dark = Theme.of(c).brightness == Brightness.dark;
  if (k == FileKind.other) {
    final s = Theme.of(c).colorScheme;
    return (bg: s.surfaceContainerHighest, fg: s.onSurfaceVariant);
  }
  // Dark: a vivid tile with a dark glyph, so the type reads at a glance (like the island's lit tiles).
  final (lb, lf, db) = switch (k) {
    FileKind.image => (0xFFE3E8FF, 0xFF3346B8, 0xFF7B95FF),
    FileKind.video => (0xFFFFE6D6, 0xFFA3410A, 0xFFFF9459),
    FileKind.audio => (0xFFFBE1F1, 0xFF9C2873, 0xFFF27BC7),
    FileKind.doc => (0xFFFFE1DE, 0xFFB3261E, 0xFFFF776B),
    FileKind.sheet => (0xFFDDF3E4, 0xFF1E6B3A, 0xFF4CCF7C),
    FileKind.archive => (0xFFFFF0C7, 0xFF7A5A00, 0xFFF5C83F),
    _ => (0xFFEAF7C6, 0xFF3D6B0B, 0xFFB2DE35),
  };
  return dark
      ? (bg: Color(db), fg: const Color(0xFF141414))
      : (bg: Color(lb), fg: Color(lf));
}

class FileTile extends StatelessWidget {
  const FileTile(this.name, {super.key, this.size = 40});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = kindColors(context, fileKind(name));
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(Radii.chip),
      ),
      child: ExcludeSemantics(
        child: Icon(fileIcon(name), size: size * 0.5, color: c.fg, fill: 1),
      ),
    );
  }
}

class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.size = 40, this.tonal = false});
  final IconData icon;
  final double size;
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: AleroMotion.micro(context, Fluent.d167),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tonal ? s.secondaryContainer : s.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.chip),
      ),
      child: ExcludeSemantics(
        child: MotionFade(
          child: Icon(
            icon,
            key: ValueKey(icon),
            size: size * 0.5,
            color: tonal ? s.onSecondaryContainer : s.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// An ongoing transfer row: name, direction, percent, bytes, speed and an always-visible cancel.
class TransferRow extends StatelessWidget {
  const TransferRow(this.x, this.hub, {super.key});
  final Xfer x;
  final Hub hub;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final target = x.size == 0 ? null : (x.done / x.size).clamp(0.0, 1.0);
    // Progress events arrive in steps: glide between them instead of jumping.
    return TweenAnimationBuilder<double>(
      tween: Tween(end: target ?? 0),
      duration: motion(context, const Duration(milliseconds: 450)),
      curve: Curves.easeOutCubic,
      builder: (context, f, _) => _row(context, t, target == null ? null : f),
    );
  }

  Widget _row(BuildContext context, TextTheme t, double? f) {
    final pct = f == null ? '' : '${(f * 100).toStringAsFixed(0)} %';
    final detail = x.note.isNotEmpty
        ? x.note
        : tr('{} de {} · {}/s', [size(x.done), size(x.size), size(x.rate)]);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FileTile(x.name),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      x.name,
                      style: t.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${x.incoming ? 'Recibiendo de' : 'Enviando a'} ${x.peerName} · $detail',
                      style: t.bodySmall?.copyWith(
                        color: context.pal.muted,
                        fontFeatures: tabular,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Text(pct, style: t.labelLarge?.copyWith(fontFeatures: tabular)),
              IconButton(
                tooltip: tr('Cancelar {}', [x.name]),
                icon: const Icon(FluentIcons.dismiss_24_regular),
                onPressed: () => hub.cancel(x.id),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 52, right: Gap.s),
            child: AleroPulse(
              active: x.note.isEmpty,
              child: WavyProgress(
                value: f,
                label: tr('Progreso de {}', [x.name]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HistoryTile extends StatelessWidget {
  const HistoryTile(this.h, this.hub, {super.key});
  final pb.HistoryItem h;
  final Hub hub;

  @override
  Widget build(BuildContext context) {
    final c = context.pal;
    final t = Theme.of(context).textTheme;
    final ok = h.status == 'done';
    final cancelled = h.status == 'cancelled';
    final (label, icon, color) = ok
        ? (
            h.incoming ? 'Recibido de' : 'Enviado a',
            FluentIcons.checkmark_circle_24_regular,
            c.signal,
          )
        : cancelled
        ? (
            h.incoming ? 'Cancelado, de' : 'Cancelado, a',
            FluentIcons.subtract_circle_24_regular,
            c.muted,
          )
        : (
            h.incoming ? 'Falló, de' : 'Falló, a',
            FluentIcons.error_circle_24_regular,
            c.danger,
          );
    final when = DateTime.fromMillisecondsSinceEpoch(h.time.toInt() * 1000);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: InkWell(
        onTap: ok ? () => hub.openHistory(h) : null,
        onSecondaryTapDown: (d) => _menu(context, d.globalPosition, ok),
        onLongPress: () {
          final box = context.findRenderObject() as RenderBox;
          _menu(context, box.localToGlobal(box.size.center(Offset.zero)), ok);
        },
        child: Row(
          children: [
            FileTile(h.name),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    h.name,
                    style: t.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '$label ${h.peerName} · ${size(h.size.toInt())} · ${_date(when)}',
                    style: t.bodySmall?.copyWith(color: c.muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!ok && !cancelled)
                    Text(
                      Hub.explain(h.code, h.message),
                      style: t.bodySmall?.copyWith(color: c.danger),
                    ),
                ],
              ),
            ),
            const SizedBox(width: Gap.s),
            MotionFade(
              child: !ok && !h.incoming
                  ? TextButton(
                      key: const ValueKey('retry'),
                      onPressed: () => hub.retry(h.id),
                      child: const Text('Reintentar'),
                    )
                  // The status is already in words; the icon only repeats it.
                  : Padding(
                      key: ValueKey(icon),
                      padding: const EdgeInsets.only(right: Gap.s),
                      child: ExcludeSemantics(
                        child: Icon(icon, size: 18, color: color, fill: 1),
                      ),
                    ),
            ),
            // Only the list entry goes; the file stays where it is.
            IconButton(
              tooltip: tx('Quitar del historial (no borra el archivo)'),
              visualDensity: VisualDensity.compact,
              icon: Icon(FluentIcons.dismiss_24_regular, size: 18, color: c.muted),
              onPressed: () => hub.removeHistory(h.id),
            ),
          ],
        ),
      ),
    );
  }

  /// Right click (long press on a phone): what you can do with this transfer and its file.
  Future<void> _menu(BuildContext context, Offset at, bool ok) async {
    // A real file on this computer; the phone's received files live behind Android's own storage.
    final onDisk = !isPhone && h.path.isNotEmpty && File(h.path).existsSync();
    PopupMenuItem<String> item(String v, IconData icon, String label) =>
        PopupMenuItem(
          value: v,
          child: Row(
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: Gap.m),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
    final screen = MediaQuery.sizeOf(context);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        at.dx,
        at.dy,
        screen.width - at.dx,
        screen.height - at.dy,
      ),
      items: [
        if (ok) item('open', FluentIcons.open_24_regular, 'Abrir'),
        if (onDisk) ...[
          item('show', FluentIcons.folder_open_24_regular, 'Mostrar en la carpeta'),
          item('path', FluentIcons.copy_24_regular, 'Copiar la ruta'),
          item(
            'again',
            FluentIcons.send_24_regular,
            tr('Enviar de nuevo a {}', [h.peerName]),
          ),
        ],
        item('name', FluentIcons.text_t_24_regular, 'Copiar el nombre'),
        if (!ok && !h.incoming)
          item('retry', FluentIcons.arrow_clockwise_24_regular, 'Reintentar'),
        const PopupMenuDivider(),
        item('forget', FluentIcons.dismiss_24_regular, 'Quitar del historial'),
        if (onDisk)
          item('delete', FluentIcons.delete_24_regular, 'Eliminar el archivo'),
      ],
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'open':
        hub.openHistory(h);
      case 'show':
        Native.showInFolder(h.path);
      case 'path':
        hub.copy(h.path);
      case 'name':
        hub.copy(h.name);
      case 'again':
        hub.sendPaths(h.peerId, [h.path]);
      case 'retry':
        hub.retry(h.id);
      case 'forget':
        hub.removeHistory(h.id);
      case 'delete':
        final sure = await showAleroDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Eliminar el archivo'),
            content: Text(
              tr('«{}» se borrará de este ordenador. No se puede deshacer.', [
                h.name,
              ]),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Eliminar'),
              ),
            ],
          ),
        );
        if (sure != true) return;
        try {
          File(h.path).deleteSync();
          hub.removeHistory(h.id);
        } catch (_) {
          hub.messages.add(
            tr('No se pudo eliminar {}: otro programa lo tiene abierto.', [
              h.name,
            ]),
          );
        }
    }
  }

  static String _date(DateTime d) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(d.hour)}:${two(d.minute)}';
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return tr('hoy {}', [hm]);
    }
    return L10n.instance.en
        ? '${two(d.month)}-${two(d.day)} $hm'
        : '${two(d.day)}/${two(d.month)} $hm';
  }
}

/// Inline empty state: icon, one line of title, one of help, optional action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.onAction,
    this.card = true,
  });
  final IconData icon;
  final String title, body;
  final String? action;
  final VoidCallback? onAction;
  final bool card;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final content = Padding(
      padding: EdgeInsets.all(card ? Gap.xl : Gap.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(icon, tonal: true),
          const SizedBox(width: Gap.l),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.titleSmall),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: t.bodyMedium?.copyWith(color: context.pal.muted),
                ),
                if (action != null) ...[
                  const SizedBox(height: Gap.m),
                  FilledButton.tonal(onPressed: onAction, child: Text(action!)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return Entrance(child: card ? Card(child: content) : content);
  }
}

/// Error banner with the cause; used for start failures.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(Gap.l),
        decoration: BoxDecoration(
          color: s.errorContainer,
          borderRadius: BorderRadius.circular(Radii.tile),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(FluentIcons.error_circle_24_regular, color: s.onErrorContainer),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Text(text, style: TextStyle(color: s.onErrorContainer)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A setting row with one fixed rhythm (title, optional hint, control), so every panel lines up the same way.
class SettingTile extends StatelessWidget {
  const SettingTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AleroPress(
      onTap: onTap,
      radius: Radii.tile,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.xs,
            vertical: Gap.s,
          ),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: Gap.m)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: weight(t.bodyLarge, 500),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: t.bodySmall?.copyWith(color: context.pal.muted),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: Gap.m),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A switch whose thumb shows a check when on (M3 Expressive), as a [SettingTile] trailing control.
class AleroSwitch extends StatelessWidget {
  const AleroSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });
  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Switch(
      value: value,
      onChanged: onChanged,
      thumbIcon: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? const m.Icon(
                FluentIcons.checkmark_24_regular,
                size: 16,
              ) // Switch takes Flutter's own Icon
            : null,
      ),
    ),
  );
}

/// Content that rises into place with a spring, a little after the one before it (list entrance).
class Reveal extends StatelessWidget {
  const Reveal({super.key, required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      AleroMotion.reveal(context, index, child);
}

/// The battery as a drawn glyph: body, nub and a level fill, so it sits on the text baseline whatever the font.
class BatteryGlyph extends StatelessWidget {
  const BatteryGlyph(
    this.level, {
    super.key,
    this.charging = false,
    this.width = 22,
  });
  final int level;
  final bool charging;
  final double width;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final low = level <= 15 && !charging;
    final h = width * 0.5;
    return Semantics(
      label: tr('Batería {} %{}', [level, charging ? ', cargando' : '']),
      child: ExcludeSemantics(
        child: SizedBox(
          width: width + 2,
          height: h,
          child: TweenValue(
            level.clamp(0, 100) / 100,
            builder: (_, v) => CustomPaint(
              painter: _Battery(
                v,
                low ? s.error : s.primary,
                s.onSurfaceVariant,
                charging,
                s.surface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Battery extends CustomPainter {
  _Battery(this.f, this.fill, this.outline, this.charging, this.bg);
  final double f;
  final Color fill, outline, bg;
  final bool charging;

  @override
  void paint(Canvas canvas, Size s) {
    final body = Rect.fromLTWH(0, 0, s.width - 2, s.height);
    final r = Radius.circular(s.height * 0.3);
    final line = Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawRRect(RRect.fromRectAndRadius(body.deflate(0.7), r), line);
    canvas.drawRRect(
      RRect.fromLTRBR(
        s.width - 1.6,
        s.height * 0.3,
        s.width,
        s.height * 0.7,
        const Radius.circular(1),
      ),
      Paint()..color = outline,
    );
    final inner = body.deflate(2.4);
    if (f > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(inner.left, inner.top, inner.width * f, inner.height),
          Radius.circular(s.height * 0.16),
        ),
        Paint()..color = fill,
      );
    }
    if (charging) {
      final c = body.center;
      final bolt = Path()
        ..moveTo(c.dx + 1.5, c.dy - s.height * 0.38)
        ..lineTo(c.dx - 2.6, c.dy + 0.6)
        ..lineTo(c.dx - 0.2, c.dy + 0.6)
        ..lineTo(c.dx - 1.5, c.dy + s.height * 0.38)
        ..lineTo(c.dx + 2.6, c.dy - 0.6)
        ..lineTo(c.dx + 0.2, c.dy - 0.6)
        ..close();
      canvas.drawPath(bolt, Paint()..color = bg);
      canvas.drawPath(
        bolt,
        Paint()
          ..color = outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6,
      );
    }
  }

  @override
  bool shouldRepaint(_Battery o) =>
      o.f != f ||
      o.fill != fill ||
      o.charging != charging ||
      o.outline != outline;
}

/// [all] in the user's [order] first, then whatever [order] does not mention (something added by an update
/// lands at the end instead of vanishing), without the [hidden] ones.
List<String> ordered(
  List<String> all,
  List<String> order,
  Set<String> hidden,
) => {
  ...order.where(all.contains),
  ...all,
}.where((t) => !hidden.contains(t)).toList();

/// Rows to drag into order, each with a switch to show or hide it. Hidden ones stay in the list.
class OrderList extends StatelessWidget {
  const OrderList({
    super.key,
    required this.order,
    required this.names,
    this.icons = const {},
    required this.hidden,
    required this.onChanged,
  });

  /// Every item, shown or not, in its current order.
  final List<String> order;
  final Map<String, String> names;
  final Map<String, IconData> icons;
  final Set<String> hidden;
  final void Function(List<String> order, Set<String> hidden) onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48.0 * order.length,
    child: ReorderableListView(
      buildDefaultDragHandles: false,
      physics: const NeverScrollableScrollPhysics(),
      onReorderItem: (from, to) {
        final next = [...order];
        next.insert(to, next.removeAt(from));
        onChanged(next, hidden);
      },
      children: [
        for (final (i, t) in order.indexed)
          SizedBox(
            key: ValueKey(t),
            height: 48,
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: i,
                  child: const MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Padding(
                      padding: EdgeInsets.all(Gap.s),
                      child: Icon(FluentIcons.re_order_dots_vertical_24_regular, size: 20),
                    ),
                  ),
                ),
                if (icons[t] case final icon?) ...[
                  Icon(icon, size: 20),
                  const SizedBox(width: Gap.m),
                ],
                Expanded(child: Text(names[t] ?? t)),
                AleroSwitch(
                  value: !hidden.contains(t),
                  label: names[t] ?? t,
                  onChanged: (on) => onChanged(order, {
                    ...hidden.where((h) => h != t),
                    if (!on) t,
                  }),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
