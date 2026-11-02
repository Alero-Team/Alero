import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
import 'expressive.dart';
import 'theme.dart';

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
    return Card(
      child: Padding(
        padding:
            padding ??
            const EdgeInsets.fromLTRB(Gap.l + 4, Gap.m, Gap.m, Gap.l),
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
                      child: Text(title, style: t.titleMedium),
                    ),
                  ),
                  ?action,
                ],
              ),
            ),
            const SizedBox(height: Gap.xs),
            child,
          ],
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
      icon: Symbols.link_rounded,
      color: c.signal,
    ),
    pb.PeerState.connecting => (
      label: 'Conectando…',
      icon: Symbols.sync_rounded,
      color: c.muted,
    ),
    pb.PeerState.rejected => (
      label: 'Te quitó de sus dispositivos',
      icon: Symbols.block_rounded,
      color: c.danger,
    ),
    pb.PeerState.disconnected when p.trusted && p.detail == 'paused' => (
      label: 'Desconectado por ti',
      icon: Symbols.pause_circle_rounded,
      color: c.muted,
    ),
    pb.PeerState.disconnected when p.trusted && p.detail == 'paused_remote' => (
      label: 'Desconectado desde el otro dispositivo',
      icon: Symbols.pause_circle_rounded,
      color: c.muted,
    ),
    pb.PeerState.disconnected =>
      p.trusted
          ? (
              label: 'Sin conexión',
              icon: Symbols.link_off_rounded,
              color: c.muted,
            )
          : (
              label: 'Disponible',
              icon: Symbols.add_link_rounded,
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
          child: Text(s.label, style: Theme.of(context).textTheme.labelLarge),
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
  FileKind.image => Symbols.image_rounded,
  FileKind.video => Symbols.movie_rounded,
  FileKind.audio => Symbols.music_note_rounded,
  FileKind.doc => Symbols.description_rounded,
  FileKind.sheet => Symbols.table_rounded,
  FileKind.archive => Symbols.folder_zip_rounded,
  FileKind.app => Symbols.apk_document_rounded,
  FileKind.other => Symbols.draft_rounded,
};

({Color bg, Color fg}) kindColors(BuildContext c, FileKind k) {
  final dark = Theme.of(c).brightness == Brightness.dark;
  if (k == FileKind.other) {
    final s = Theme.of(c).colorScheme;
    return (bg: s.surfaceContainerHighest, fg: s.onSurfaceVariant);
  }
  final (lb, lf, db, df) = switch (k) {
    FileKind.image => (0xFFE3E8FF, 0xFF3346B8, 0xFF252B4D, 0xFFB4C1FF),
    FileKind.video => (0xFFFFE6D6, 0xFFA3410A, 0xFF4A2817, 0xFFFFB98F),
    FileKind.audio => (0xFFFBE1F1, 0xFF9C2873, 0xFF472038, 0xFFF5A8D6),
    FileKind.doc => (0xFFFFE1DE, 0xFFB3261E, 0xFF4D2220, 0xFFFFB4AB),
    FileKind.sheet => (0xFFDDF3E4, 0xFF1E6B3A, 0xFF1C3A26, 0xFF9FDDB3),
    FileKind.archive => (0xFFFFF0C7, 0xFF7A5A00, 0xFF40330F, 0xFFF2CF6B),
    _ => (0xFFEAF7C6, 0xFF3D6B0B, 0xFF2B3814, 0xFFC8F031),
  };
  return dark ? (bg: Color(db), fg: Color(df)) : (bg: Color(lb), fg: Color(lf));
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
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tonal ? s.secondaryContainer : s.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.chip),
      ),
      child: ExcludeSemantics(
        child: Icon(
          icon,
          size: size * 0.5,
          color: tonal ? s.onSecondaryContainer : s.onSurfaceVariant,
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
    final f = x.size == 0 ? null : (x.done / x.size).clamp(0.0, 1.0);
    final pct = f == null ? '' : '${(f * 100).toStringAsFixed(0)} %';
    final detail = x.note.isNotEmpty
        ? x.note
        : '${size(x.done)} de ${size(x.size)} · ${size(x.rate)}/s';
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
                tooltip: 'Cancelar ${x.name}',
                icon: const Icon(Symbols.close_rounded),
                onPressed: () => hub.cancel(x.id),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 52, right: Gap.s),
            child: WavyProgress(value: f, label: 'Progreso de ${x.name}'),
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
            Symbols.check_circle_rounded,
            c.signal,
          )
        : cancelled
        ? (
            h.incoming ? 'Cancelado, de' : 'Cancelado, a',
            Symbols.do_not_disturb_on_rounded,
            c.muted,
          )
        : (
            h.incoming ? 'Falló, de' : 'Falló, a',
            Symbols.error_rounded,
            c.danger,
          );
    final when = DateTime.fromMillisecondsSinceEpoch(h.time.toInt() * 1000);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: InkWell(
        onTap: ok ? () => hub.openHistory(h) : null,
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
            if (!ok && !h.incoming)
              TextButton(
                onPressed: () => hub.retry(h.id),
                child: const Text('Reintentar'),
              )
            else
              // The status is already in words; the icon only repeats it.
              Padding(
                padding: const EdgeInsets.only(right: Gap.s),
                child: ExcludeSemantics(
                  child: Icon(icon, size: 18, color: color, fill: 1),
                ),
              ),
            // Only the list entry goes; the file stays where it is.
            IconButton(
              tooltip: 'Quitar del historial (no borra el archivo)',
              visualDensity: VisualDensity.compact,
              icon: Icon(Symbols.close_rounded, size: 18, color: c.muted),
              onPressed: () => hub.removeHistory(h.id),
            ),
          ],
        ),
      ),
    );
  }

  static String _date(DateTime d) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(d.hour)}:${two(d.minute)}';
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return 'hoy $hm';
    }
    return '${two(d.day)}/${two(d.month)} $hm';
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
    return card ? Card(child: content) : content;
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
            Icon(Symbols.error_rounded, color: s.onErrorContainer),
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.tile),
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
            ? const Icon(Symbols.check_rounded, size: 16)
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
  Widget build(BuildContext context) {
    final delay = Duration(milliseconds: (index.clamp(0, 6)) * 40);
    final total = motion(context, Spring.spatial.settle + delay);
    if (total == Duration.zero) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: _Delayed(
        delay.inMilliseconds / total.inMilliseconds,
        Spring.spatial,
      ),
      child: child,
      builder: (_, v, c) => Opacity(
        opacity: v.clamp(0, 1),
        child: Transform.translate(offset: Offset(0, (1 - v) * 14), child: c),
      ),
    );
  }
}

class _Delayed extends Curve {
  const _Delayed(this.start, this.inner);
  final double start;
  final Curve inner;

  @override
  double transformInternal(double t) =>
      t <= start ? 0 : inner.transform((t - start) / (1 - start));
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
      label: 'Batería $level %${charging ? ', cargando' : ''}',
      child: ExcludeSemantics(
        child: SizedBox(
          width: width + 2,
          height: h,
          child: CustomPaint(
            painter: _Battery(
              level.clamp(0, 100) / 100,
              low ? s.error : s.primary,
              s.onSurfaceVariant,
              charging,
              s.surface,
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
