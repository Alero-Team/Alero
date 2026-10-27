import 'package:flutter/material.dart';

import '../hub.dart';
import '../src/rust/api/engine.dart' as pb;
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

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction, this.top = true});
  final String title;
  final bool top;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top ? Gap.xl : 0, bottom: Gap.xs),
    child: ConstrainedBox(
      // Same height with or without an action button, so side-by-side headers line up.
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Expanded(
            child: Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
          ),
          if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    ),
  );
}

/// One wording, icon and color per peer state, used everywhere. Color is never the only signal.
({String label, IconData icon, Color color}) peerStatus(BuildContext context, pb.Peer p) {
  final c = context.pal;
  return switch (p.state) {
    pb.PeerState.connected => (label: 'Conectado', icon: Icons.link, color: c.signal),
    pb.PeerState.connecting => (label: 'Conectando…', icon: Icons.sync, color: c.muted),
    pb.PeerState.rejected => (label: 'Te quitó de sus dispositivos', icon: Icons.block, color: c.danger),
    pb.PeerState.disconnected =>
      p.trusted
          ? (label: 'Sin conexión', icon: Icons.link_off, color: c.muted)
          : (label: 'Disponible', icon: Icons.add_link, color: c.muted),
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
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: s.color, shape: BoxShape.circle),
        ),
        const SizedBox(width: Gap.s),
        Flexible(
          child: Text(
            s.label,
            style: TextStyle(color: context.pal.ink, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}

/// One icon rule per file type, same on every platform; the container is always neutral.
IconData fileIcon(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'heic' || 'bmp' || 'svg' => Icons.image_outlined,
    'mp4' || 'mkv' || 'mov' || 'avi' || 'webm' => Icons.movie_outlined,
    'mp3' || 'flac' || 'wav' || 'ogg' || 'm4a' || 'opus' => Icons.music_note_outlined,
    'pdf' || 'doc' || 'docx' || 'odt' || 'txt' || 'md' || 'rtf' => Icons.description_outlined,
    'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_outlined,
    'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_outlined,
    'apk' || 'exe' || 'msi' => Icons.install_desktop_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.size = 44});
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: context.pal.alt, borderRadius: BorderRadius.circular(Radii.chip)),
    child: ExcludeSemantics(
      child: Icon(icon, size: size * 0.5, color: context.pal.ink),
    ),
  );
}

/// An ongoing transfer: name, direction, percent, bytes, speed and an always-visible cancel.
class TransferCard extends StatelessWidget {
  const TransferCard(this.x, this.hub, {super.key});
  final Xfer x;
  final Hub hub;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final f = x.size == 0 ? null : (x.done / x.size).clamp(0.0, 1.0);
    final pct = f == null ? '' : '${(f * 100).toStringAsFixed(0)} %';
    final detail = x.note.isNotEmpty ? x.note : '${size(x.done)} de ${size(x.size)} · ${size(x.rate)}/s';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconTile(fileIcon(x.name)),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(x.name, style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        '${x.incoming ? 'Recibiendo de' : 'Enviando a'} ${x.peerName}',
                        style: t.bodySmall?.copyWith(color: context.pal.muted),
                      ),
                    ],
                  ),
                ),
                Text(pct, style: t.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                IconButton(
                  tooltip: 'Cancelar ${x.name}',
                  icon: const Icon(Icons.close),
                  onPressed: () => hub.cancel(x.id),
                ),
              ],
            ),
            const SizedBox(height: Gap.m),
            Padding(
              padding: const EdgeInsets.only(right: Gap.s),
              child: LinearProgressIndicator(value: f, semanticsLabel: 'Progreso de ${x.name}', semanticsValue: pct),
            ),
            const SizedBox(height: Gap.s),
            Text(
              detail,
              style: t.bodySmall?.copyWith(
                color: context.pal.muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
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
        ? (h.incoming ? 'Recibido de' : 'Enviado a', Icons.check_circle, c.signal)
        : cancelled
        ? (h.incoming ? 'Cancelado, de' : 'Cancelado, a', Icons.remove_circle_outline, c.muted)
        : (h.incoming ? 'Falló, de' : 'Falló, a', Icons.error, c.danger);
    final when = DateTime.fromMillisecondsSinceEpoch(h.time.toInt() * 1000);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: Row(
        children: [
          IconTile(fileIcon(h.name)),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(h.name, style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  '$label ${h.peerName} · ${size(h.size.toInt())} · ${_date(when)}',
                  style: t.bodySmall?.copyWith(color: c.muted),
                ),
                if (!ok && !cancelled)
                  Text(Hub.explain(h.code, h.message), style: t.bodySmall?.copyWith(color: c.danger)),
              ],
            ),
          ),
          const SizedBox(width: Gap.s),
          if (!ok && !h.incoming)
            TextButton(onPressed: () => hub.retry(h.id), child: const Text('Reintentar'))
          else
            // The status is already in words above; the icon only repeats it.
            ExcludeSemantics(child: Icon(icon, size: 20, color: color)),
        ],
      ),
    );
  }

  static String _date(DateTime d) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(d.hour)}:${two(d.minute)}';
    if (d.year == now.year && d.month == now.month && d.day == now.day) return 'hoy $hm';
    return '${two(d.day)}/${two(d.month)} $hm';
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.onAction,
  });
  final IconData icon;
  final String title, body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconTile(icon, size: 48),
            const SizedBox(height: Gap.l),
            Text(title, style: t.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(body, style: t.bodyMedium?.copyWith(color: context.pal.muted)),
            if (action != null) ...[
              const SizedBox(height: Gap.l),
              FilledButton(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Error banner with the cause; used for start failures.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(Gap.l),
      decoration: BoxDecoration(
        color: context.pal.surface,
        borderRadius: BorderRadius.circular(Radii.tile),
        border: Border.all(color: context.pal.danger),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: context.pal.danger),
          const SizedBox(width: Gap.m),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );
}
