import 'package:flutter/material.dart';

import 'expressive.dart';
import 'theme.dart';

class NavData {
  const NavData(this.icon, this.label, {this.badge = 0});
  final IconData icon;
  final String label;
  final int badge;
}

/// Bottom bar for phones: only the selected destination shows its name next to its icon; the others are icon
/// only, spread evenly. The selected pill is as wide as its content; the rest of the bar is shared by the other
/// icons. When the selection changes, every width moves from its old value to its new one with the same spring,
/// and the old and new widths always add up to the bar's width, so nothing jumps and nothing outside the bar moves.
class AleroNavBar extends StatefulWidget {
  const AleroNavBar({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelect,
  });
  final List<NavData> items;
  final int selected;
  final ValueChanged<int> onSelect;

  static const height = 64.0,
      _icon = 24.0,
      _gap = 8.0,
      _pad = 8.0,
      _side = 16.0;

  @override
  State<AleroNavBar> createState() => _AleroNavBarState();
}

class _AleroNavBarState extends State<AleroNavBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    value: 1,
  );
  late int _from = widget.selected, _to = widget.selected;

  @override
  void didUpdateWidget(AleroNavBar o) {
    super.didUpdateWidget(o);
    if (widget.selected != _to) {
      // Start from wherever the last move got to, so quick taps never snap.
      _from = _to;
      _to = widget.selected;
      _c.duration = motion(context, Spring.spatial.settle);
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _textWidth(String s, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final label = Theme.of(context).textTheme.labelLarge!;
    final n = widget.items.length;
    final selW = [
      for (final d in widget.items)
        AleroNavBar._side * 2 +
            AleroNavBar._icon +
            AleroNavBar._gap +
            _textWidth(d.label, label),
    ];
    return Container(
      height: AleroNavBar.height,
      padding: const EdgeInsets.all(AleroNavBar._pad),
      decoration: BoxDecoration(
        color: s.surfaceContainer,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: s.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          // Target widths for a given selection: the selected pill, and the rest shared equally.
          List<double> target(int sel) {
            final w = selW[sel].clamp(0.0, box.maxWidth - (n - 1) * 48.0);
            return [
              for (var i = 0; i < n; i++)
                i == sel ? w : (box.maxWidth - w) / (n - 1),
            ];
          }

          final a = target(_from), b = target(_to);
          return AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              // Orion's spatial spring, shared by every tab width: the
              // selected pill expands as the previous one contracts.
              // Clamping keeps narrow layouts within their exact width.
              final t = Spring.spatial.transform(_c.value).clamp(0.0, 1.0);
              return Row(
                children: [
                  for (var i = 0; i < n; i++)
                    _Item(
                      data: widget.items[i],
                      width: a[i] + (b[i] - a[i]) * t,
                      // 1 while selected, easing 0 -> 1 or 1 -> 0 around a change
                      p: i == _to
                          ? (_from == _to ? 1 : t)
                          : (i == _from ? 1 - t : 0),
                      label: label,
                      textW:
                          selW[i] -
                          2 * AleroNavBar._side -
                          AleroNavBar._icon -
                          AleroNavBar._gap,
                      onTap: () => widget.onSelect(i),
                      selected: i == widget.selected,
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.data,
    required this.width,
    required this.p,
    required this.label,
    required this.textW,
    required this.onTap,
    required this.selected,
  });
  final NavData data;
  final double width, p, textW;
  final TextStyle label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    const icon = AleroNavBar._icon, gap = AleroNavBar._gap;
    final pp = p.clamp(0.0, 1.0);
    // The icon + name group is centered in the item; unselected, only the icon is.
    final groupW = icon + (gap + textW) * pp;
    final x = (width - groupW) / 2;
    return Semantics(
      button: true,
      selected: selected,
      label: data.label,
      child: OrionPress(
        onTap: onTap,
        child: SizedBox(
          width: width < 0 ? 0 : width,
          height: AleroNavBar.height - 2 * AleroNavBar._pad,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color.lerp(
                Colors.transparent,
                s.surfaceContainerHighest,
                pp,
              ),
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned(
                    left: x,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: ExcludeSemantics(
                        child: SizedBox(
                          width: icon,
                          height: icon,
                          child: Center(
                            child: Badge(
                              // A fixed-size icon slot keeps every glyph centered
                              // regardless of whether a message badge is visible.
                              alignment: Alignment.topRight,
                              offset: const Offset(4, -3),
                              isLabelVisible: data.badge > 0,
                              label: Text('${data.badge}'),
                              child: Icon(
                                data.icon,
                                size: icon,
                                fill: pp,
                                color: Color.lerp(
                                  s.onSurfaceVariant,
                                  s.onSurface,
                                  pp,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: x + icon + gap,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Opacity(
                        opacity: ((pp - 0.4) / 0.6).clamp(0.0, 1.0),
                        child: ExcludeSemantics(
                          child: Text(
                            data.label,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                            style: label.copyWith(color: s.onSurface),
                          ),
                        ),
                      ),
                    ),
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
