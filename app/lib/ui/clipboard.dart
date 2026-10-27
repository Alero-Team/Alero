import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import 'notifications.dart' show ago;
import 'theme.dart';

/// Clipboard is an action, not a place: a split button (M3 Expressive). The main part sends this device's
/// clipboard; the arrow (only once there is history) opens recent items to copy one back.
class ClipboardButton extends StatelessWidget {
  const ClipboardButton(this.hub, this.peerId, {super.key, this.enabled = true});
  final Hub hub;
  final String peerId;
  final bool enabled;

  static const _outer = Radius.circular(Radii.pill), _inner = Radius.circular(6);

  @override
  Widget build(BuildContext context) {
    final split = hub.clips.isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.tonalIcon(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.horizontal(left: _outer, right: split ? _inner : _outer),
            ),
          ),
          onPressed: enabled ? () => hub.sendClipboard(peerId) : null,
          icon: const Icon(Symbols.content_paste_go_rounded, size: 18),
          label: const Text('Portapapeles'),
        ),
        if (split) ...[const SizedBox(width: 2), _History(hub)],
      ],
    );
  }
}

class _History extends StatelessWidget {
  const _History(this.hub);
  final Hub hub;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      style: MenuStyle(
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.tile))),
      ),
      menuChildren: [
        for (final c in hub.clips.take(8))
          MenuItemButton(
            leadingIcon: Icon(c.incoming ? Symbols.south_west_rounded : Symbols.north_east_rounded, size: 18),
            onPressed: () => hub.copy(c.text),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.text.replaceAll('\n', ' '), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    '${c.incoming ? 'De' : 'A'} ${c.peerName} · ${ago(c.time)}',
                    style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
      ],
      builder: (context, menu, _) => FilledButton.tonal(
        style: FilledButton.styleFrom(
          minimumSize: const Size(40, 40),
          padding: const EdgeInsets.symmetric(horizontal: Gap.s + 2),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.horizontal(left: ClipboardButton._inner, right: ClipboardButton._outer),
          ),
        ),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        child: Semantics(
          label: 'Historial del portapapeles',
          child: AnimatedRotation(
            turns: menu.isOpen ? 0.5 : 0,
            duration: const Duration(milliseconds: 200),
            child: const Icon(Symbols.keyboard_arrow_down_rounded, size: 20),
          ),
        ),
      ),
    );
  }
}
