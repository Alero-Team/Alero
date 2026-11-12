import 'dart:io';

import 'package:flutter/material.dart' hide Icon;
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../remote.dart';
import '../src/rust/api/engine.dart' as pb;
import 'brand.dart';
import 'clipboard.dart';
import 'expressive.dart';
import 'alero_motion.dart';
import 'media.dart';
import 'notifications.dart';
import 'phone_home.dart';
import 'screen.dart';
import 'settings.dart' show showAppearance;
import 'shell.dart';
import 'theme.dart';
import 'controls.dart';
import 'widgets.dart';
import 'icon.dart';

/// The device Home is about: the one the user picked, else the first paired one online, else the first paired.
pb.Peer? mainPeer(Hub hub) {
  final trusted = hub.peers.where((p) => p.trusted);
  return trusted.where((p) => p.id == hub.activePeerId).firstOrNull ??
      trusted.where((p) => p.state == pb.PeerState.connected).firstOrNull ??
      trusted.firstOrNull;
}

/// Chips to switch the active device; nothing when only one is paired.
class _DevicePicker extends StatelessWidget {
  const _DevicePicker(this.hub, this.current);
  final Hub hub;
  final pb.Peer current;

  @override
  Widget build(BuildContext context) {
    final paired = hub.peers.where((p) => p.trusted).toList();
    if (paired.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.m),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final p in paired)
              Padding(
                padding: const EdgeInsets.only(right: Gap.s),
                child: ChoiceChip(
                  selected: p.id == current.id,
                  // The device icon stays; a checkmark would replace it and change the chip's look.
                  showCheckmark: false,
                  onSelected: (_) => hub.selectPeer(p.id),
                  avatar: Icon(
                    hub.info[p.id]?.phone == true
                        ? Symbols.smartphone_rounded
                        : Symbols.computer_rounded,
                    size: 18,
                  ),
                  label: Text(p.name),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Home's tiles, by name, with the title "Personalizar" shows for each.
const homeTileNames = {
  'device': 'Dispositivo',
  'remote': 'Control remoto',
  'media': 'Reproductor',
  'controls': 'Controles rápidos',
  'notifs': 'Notificaciones',
  'recent': 'Actividad reciente',
};

/// The tiles Home shows, in order: the user's [order] first, then any of [all] it does not mention (a tile
/// added by an update lands at the end instead of vanishing), without the [hidden] ones.
List<String> homeTiles(
  List<String> all,
  List<String> order,
  Set<String> hidden,
) => ordered(all, order, hidden);

/// How many of [count] tiles go in the left column of a wide Home: three fifths, rounded up.
int homeLeftCount(int count) => (count * 3 / 5).ceil();

/// Everything you do with the connected device, in one place: who it is and its state, what you can do
/// (send, clipboard, screen), what it is playing, its notifications and what moved recently.
class HomeScreen extends StatelessWidget {
  const HomeScreen(this.hub, {super.key, required this.go});
  final Hub hub;
  final void Function(Section s) go;

  @override
  Widget build(BuildContext context) {
    final main = mainPeer(hub);
    final online = main?.state == pb.PeerState.connected;
    final info = main == null ? null : hub.info[main.id];
    final phone = info?.phone ?? false;

    if (main == null) {
      return ScreenFrame(
        title: 'Inicio',
        children: [
          if (hub.startError.isNotEmpty) ...[
            ErrorBanner(hub.startError),
            const SizedBox(height: Gap.l),
          ],
          _Welcome(go: go),
        ],
      );
    }

    final recent = _Recent(hub, go: go);
    final media = online && phone
        ? MediaPanel(hub, main.id, compact: !Platform.isAndroid)
        : null;
    final notifs = online && phone ? NotificationsPanel(hub, main.id) : null;
    final controls = online && phone && !Platform.isAndroid
        ? PhoneControlsPanel(hub, main)
        : null;
    final status = phone && info != null
        ? _StatusPanel(info, online: online)
        : null;
    // The device card carries its state too: one tile for who it is, what it has and what you can do.
    final hero = _Hero(main, info, hub, go: go, status: status);
    final scale = TileScale.forSize(hub.tileSize.value);
    // Bigger tiles need more room before Home splits into two columns.
    final wide = MediaQuery.sizeOf(context).width >= 1180 * scale;
    final fit = ScaledTiles.fit(context, scale);
    final gap = SizedBox(height: Gap.l * fit, width: Gap.l * fit);

    if (Platform.isAndroid && !phone) {
      return ScreenFrame(
        title: 'Inicio',
        maxWidth: 980,
        onRefresh: hub.refresh,
        trailing: IconButton(
          tooltip: 'Personalizar',
          onPressed: () => _customize(context, hub, go, _phoneTiles),
          icon: const Icon(Symbols.dashboard_customize_rounded),
        ),
        children: [
          _DevicePicker(hub, main),
          // Same order as the computer's Inicio: device, what it plays, its controls, then activity.
          ScaledTiles(
            scale,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, t) in homeTiles(
                  _phoneTiles,
                  hub.homeOrder,
                  hub.homeHidden,
                ).indexed) ...[
                  if (i > 0) gap,
                  switch (t) {
                    'device' => hero,
                    'remote' => RemoteCard(hub, main),
                    'media' => MediaPanel(hub, main.id, computer: true),
                    _ => recent,
                  },
                ],
              ],
            ),
          ),
        ],
      );
    }

    final shown = homeTiles(_pcTiles, hub.homeOrder, hub.homeHidden);
    // A tile with nothing to show yet (phone offline) is skipped, or says so where a column needs it.
    Widget? tile(String t, {bool placeholder = false}) => switch (t) {
      'device' => hero,
      'media' =>
        media ??
            (placeholder
                ? const Panel(
                    title: 'Reproductor',
                    icon: Symbols.music_note_rounded,
                    child: Text('No hay música en reproducción.'),
                  )
                : null),
      'controls' =>
        controls ??
            (placeholder
                ? const Panel(
                    title: 'Controles rápidos',
                    icon: Symbols.tune_rounded,
                    child: Text('Conecta el teléfono para usar sus controles.'),
                  )
                : null),
      'notifs' =>
        notifs ??
            (placeholder
                ? const Panel(
                    title: 'Notificaciones',
                    icon: Symbols.notifications_rounded,
                    child: Text('Sin notificaciones.'),
                  )
                : null),
      _ => recent,
    };
    // Two columns on a wide window: the first tiles of the user's order on the left (three fifths of
    // them), the rest on the right. One column otherwise. A tile with nothing to show takes no room.
    final two = wide && !Platform.isAndroid && shown.length > 1;
    final cut = two ? homeLeftCount(shown.length) : shown.length;
    final columns = [
      shown.take(cut).map((t) => tile(t, placeholder: two)).nonNulls.toList(),
      if (two)
        shown
            .skip(cut)
            .map((t) => tile(t, placeholder: true))
            .nonNulls
            .toList(),
    ];
    final dashboard = <Widget>[
      if (hub.startError.isNotEmpty) ...[ErrorBanner(hub.startError), gap],
      _DevicePicker(hub, main),
      if (Platform.isAndroid && !hub.notifAccess) ...[_AccessHint(hub), gap],
      // Changing between one and two columns fades instead of jumping while the window is resized.
      AnimatedSwitcher(
        duration: motion(context, const Duration(milliseconds: 220)),
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, ?current],
        ),
        child: KeyedSubtree(
          key: ValueKey(columns.length),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (c, column) in columns.indexed) ...[
                if (c > 0) gap,
                Expanded(
                  flex: c == 0 ? 3 : 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, w) in column.indexed) ...[
                        if (i > 0) gap,
                        w,
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ];

    return ScreenFrame(
      title: 'Inicio',
      maxWidth: 1920,
      trailing: !Platform.isAndroid
          ? OutlinedButton.icon(
              onPressed: () => _customize(context, hub, go, _pcTiles),
              icon: const Icon(Symbols.dashboard_customize_rounded),
              label: const Text('Personalizar'),
            )
          : null,
      children: [
        ScaledTiles(
          scale,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: dashboard,
          ),
        ),
      ],
    );
  }
}

/// Default order on the phone with a computer, and everywhere else (the computer, or two phones).
const _phoneTiles = ['device', 'remote', 'media', 'recent'];
const _pcTiles = ['device', 'media', 'recent', 'controls', 'notifs'];

/// Personalizar: which tiles Home shows, in what order and how big, applied at once; theme and the rest
/// stay in Ajustes.
Future<void> _customize(
  BuildContext context,
  Hub hub,
  void Function(Section) go,
  List<String> tiles,
) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: const Text('Personalizar inicio'),
    content: ListenableBuilder(
      listenable: Listenable.merge([hub, hub.tileSize]),
      builder: (ctx, _) => SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Mosaicos'),
              OrderList(
                order: homeTiles(tiles, hub.homeOrder, const {}),
                names: homeTileNames,
                hidden: hub.homeHidden,
                // Tiles of the other device kind keep their saved place.
                onChanged: (order, hidden) => hub.setHome([
                  ...order,
                  ...hub.homeOrder.where((t) => !order.contains(t)),
                ], hidden),
              ),
              Text(
                'Arrastra para ordenar y apaga los que no uses. En una ventana ancha, '
                'los primeros van a la columna izquierda y el resto a la derecha.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: Gap.l),
              const Text('Tamaño de los mosaicos'),
              const SizedBox(height: Gap.s),
              Row(
                children: [
                  const Icon(Symbols.text_decrease_rounded, size: 18),
                  Expanded(
                    child: Slider(
                      value: TileScale.forSize(hub.tileSize.value),
                      min: TileScale.minFactor,
                      max: TileScale.maxFactor,
                      divisions: 16,
                      label:
                          '${(TileScale.forSize(hub.tileSize.value) * 100).round()} %',
                      onChanged: (v) => hub.setTileSize(v.toStringAsFixed(2)),
                    ),
                  ),
                  const Icon(Symbols.text_increase_rounded, size: 22),
                ],
              ),
              Text(
                'Cambia el tamaño del texto, los iconos y los espacios. En pantallas estrechas se ajusta solo.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    hub.setTileSize('normal');
                    hub.setHome([], {});
                  },
                  child: const Text('Restablecer'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          Navigator.pop(ctx);
          showAppearance.value = true;
          go(Section.settings);
        },
        child: const Text('Tema y apariencia'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Listo'),
      ),
    ],
  ),
);

/// First run (nothing paired yet): the mark draws itself and the next step is one button.
class _Welcome extends StatelessWidget {
  const _Welcome({required this.go});
  final void Function(Section s) go;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    return Card(
      color: s.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(
          children: [
            const AleroIntro(size: 72),
            const SizedBox(height: Gap.l),
            Text(
              'Bienvenido a Alero',
              style: t.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Gap.s),
            Text(
              'Abre Alero en el otro dispositivo, en la misma red Wi-Fi o con un cable USB, y empareja los dos.',
              style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Gap.xl),
            FilledButton.icon(
              onPressed: () => go(Section.devices),
              icon: const Icon(Symbols.add_link_rounded, size: 18),
              label: const Text('Emparejar un dispositivo'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero(this.p, this.info, this.hub, {required this.go, this.status});
  final Widget? status;
  final pb.Peer p;
  final PeerInfo? info;
  final Hub hub;
  final void Function(Section s) go;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    final online = p.state == pb.PeerState.connected;
    final phone = info?.phone ?? !Platform.isAndroid;
    final picture = phone
        ? PhoneMockup(
            info: info,
            wallpaper: hub.wallpaper[p.id],
            width: 84,
            online: online,
          )
        : LaptopMockup(info: info, wallpaper: hub.wallpaper[p.id], width: 104);

    Widget property(IconData icon, String value) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: colors.onSurfaceVariant),
          const SizedBox(width: 7),
          Text(value, style: type.labelSmall),
        ],
      ),
    );

    // Every shortcut lives in this card, as the prototype's buttons, on the computer and on the phone.
    final buttons = Platform.isAndroid
        ? const <Widget>[]
        : [
            FilledButton.icon(
              onPressed: online ? () => hub.send(p.id) : null,
              icon: const Icon(Symbols.upload_rounded, size: 18),
              label: const FitLabel('Enviar archivos'),
            ),
            FilledButton.tonalIcon(
              onPressed: online
                  ? () => openClipboard(context, hub, p.id)
                  : null,
              icon: const Icon(Symbols.content_paste_go_rounded, size: 18),
              label: const FitLabel('Portapapeles'),
            ),
            if (phone)
              OutlinedButton.icon(
                onPressed: online ? () => openScreen(context, hub, p) : null,
                icon: const Icon(Symbols.cast_rounded, size: 18),
                label: const FitLabel('Acceso remoto'),
              ),
          ];
    // One row when every label fits on one line (150 px each); else the main button gets its own row and the rest share the next.
    Widget actions(double width) {
      final n = buttons.length;
      final oneRow = width / n >= 150;
      final rest = oneRow ? n : n - 1;
      final w = (width - Gap.s * (rest - 1)) / rest;
      final tight = w < 200;
      return Theme(
        data: Theme.of(context).copyWith(
          visualDensity: tight ? VisualDensity.compact : null,
          textTheme: tight ? type.copyWith(labelLarge: type.labelMedium) : null,
        ),
        child: Wrap(
          spacing: Gap.s,
          runSpacing: Gap.s,
          children: [
            for (var i = 0; i < n; i++)
              SizedBox(width: !oneRow && i == 0 ? width : w, child: buttons[i]),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: EdgeInsets.all(20 * TileScale.of(context)),
        child: LayoutBuilder(
          builder: (context, outer) {
            // A wide card puts storage, network and battery in its right half instead of leaving it empty.
            final side = status != null && outer.maxWidth >= 760;
            final box = BoxConstraints(
              maxWidth: side ? (outer.maxWidth - 24) * 6 / 11 : outer.maxWidth,
            );
            final phoneSize = box.maxWidth < 420 ? 70.0 : 104.0;
            final identity = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Name on the picture's top edge, buttons on its bottom edge: no empty band above or below.
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: phoneSize,
                        child: Semantics(
                          button: true,
                          label: 'Ver ${p.name} en Dispositivos',
                          child: InkWell(
                            onTap: () => go(Section.devices),
                            borderRadius: BorderRadius.circular(12),
                            child: Center(child: picture),
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 10,
                              runSpacing: 6,
                              children: [
                                Text(
                                  p.name,
                                  style: type.headlineSmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                StatusLine(p),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 7,
                              runSpacing: 7,
                              children: [
                                if ((info?.model ?? '').isNotEmpty)
                                  property(
                                    Symbols.smartphone_rounded,
                                    info!.model,
                                  ),
                                if ((info?.osLabel ?? '').isNotEmpty)
                                  property(
                                    Symbols.layers_rounded,
                                    info!.osLabel,
                                  ),
                                if ((info?.network ?? '').isNotEmpty)
                                  property(Symbols.wifi_rounded, info!.network),
                                // The phone keeps this card short: four buttons, no extra row of chips.
                                if (online && !Platform.isAndroid)
                                  property(
                                    Symbols.verified_user_rounded,
                                    'Conexión cifrada',
                                  ),
                              ],
                            ),
                            // With a status panel, the battery bar goes down there.
                            if ((info?.battery ?? -1) >= 0 &&
                                status == null) ...[
                              const SizedBox(height: 13),
                              Row(
                                children: [
                                  BatteryGlyph(
                                    info!.battery,
                                    charging: info!.charging,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${info!.battery}%',
                                    style: type.titleLarge,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: LinearProgressIndicator(
                                      value: (info!.battery / 100).clamp(0, 1),
                                      minHeight: 7,
                                      borderRadius: BorderRadius.circular(30),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            // The buttons sit beside the picture, under the chips, instead of in a row of their own.
                            // Intrinsic height cannot run a LayoutBuilder: the column's width is known here.
                            if (buttons.isNotEmpty) ...[
                              const SizedBox(height: 14),
                              actions(box.maxWidth - phoneSize - 20),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (!online) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Comprueba que ambos dispositivos estén conectados a la misma red.',
                    style: type.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 18),
                  QuickActions(hub, p),
                ],
                if (status != null && !side) ...[
                  const SizedBox(height: Gap.l),
                  Divider(color: colors.outlineVariant),
                  status!,
                ],
              ],
            );
            if (!side) return identity;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 6, child: identity),
                const SizedBox(width: 24),
                Expanded(flex: 5, child: status!),
              ],
            );
          },
        ),
      ),
    );
  }
}

class BatteryLine extends StatelessWidget {
  const BatteryLine(this.info, {super.key});
  final PeerInfo info;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        BatteryGlyph(info.battery, charging: info.charging),
        const SizedBox(width: Gap.xs + 2),
        AleroMotion.number(
          '${info.battery} %${info.charging ? ' · cargando' : ''}',
          Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: s.onSurfaceVariant, fontFeatures: tabular),
        ),
      ],
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel(this.info, {required this.online});
  final PeerInfo info;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final total = info.storageTotal;
    final used = total > 0 ? total - info.storageFree : 0;

    Widget metric(
      IconData icon,
      String label,
      String value, {
      double? progress,
    }) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colors.onSurfaceVariant),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(label, style: text.titleSmall),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: Text(
                        value,
                        maxLines: 2,
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                if (progress != null) ...[
                  const SizedBox(height: 9),
                  LinearProgressIndicator(
                    value: progress.clamp(0, 1),
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    return Column(
      children: [
        metric(
          Symbols.wifi_rounded,
          'Conectividad',
          info.network.isEmpty
              ? 'Sin conexión'
              : info.wifiLabel.isEmpty
              ? info.network
              : info.wifiLabel,
        ),
        if (total > 0)
          metric(
            Symbols.hard_drive_rounded,
            'Almacenamiento',
            '${size(used)} de ${size(total)}',
            progress: used / total,
          ),
        if (info.battery >= 0)
          metric(
            info.charging
                ? Symbols.battery_charging_full_rounded
                : Symbols.battery_full_rounded,
            'Batería',
            ['${info.battery} %', ?info.chargeLabel].join(' · '),
            progress: info.battery / 100,
          ),
      ],
    );
  }
}

class _Recent extends StatefulWidget {
  const _Recent(this.hub, {required this.go});
  final Hub hub;
  final void Function(Section s) go;

  @override
  State<_Recent> createState() => _RecentState();
}

class _RecentState extends State<_Recent> {
  String filter = 'Todo';
  bool more = false;

  Widget filters() => Wrap(
    spacing: 4,
    children: [
      for (final value in const ['Todo', 'Enviados', 'Recibidos'])
        ChoiceChip(
          label: Text(value),
          selected: filter == value,
          onSelected: (_) => setState(() => filter = value),
          visualDensity: VisualDensity.compact,
          labelStyle: Theme.of(context).textTheme.labelSmall,
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final hub = widget.hub;
    bool matches(bool incoming) =>
        filter == 'Todo' ||
        (filter == 'Recibidos' && incoming) ||
        (filter == 'Enviados' && !incoming);
    final recent = hub.history.where((h) => matches(h.incoming)).toList();
    final active = hub.active.where((x) => matches(x.incoming)).toList();
    // While something moves, it has the card and only the last result stays under it; otherwise the last
    // three, or eight on request.
    final all = recent.length;
    recent.length = all.clamp(0, active.isNotEmpty ? 1 : (more ? 8 : 3));
    final wide = MediaQuery.sizeOf(context).width >= 1180;
    return Panel(
      title: 'Actividad reciente',
      icon: Symbols.history_rounded,
      action: wide ? filters() : null,
      child: AnimatedSize(
        duration: AleroMotion.duration(context, 320),
        curve: AleroMotion.spatial,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!wide) ...[filters(), const SizedBox(height: 12)],
            for (final x in active) TransferRow(x, hub),
            if (recent.isEmpty && active.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.m),
                child: Text(
                  'Todavía no hay archivos en esta categoría.',
                  style: TextStyle(color: context.pal.muted),
                ),
              ),
            for (final h in recent) HistoryTile(h, hub),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (active.isEmpty && all > 3)
                  TextButton(
                    onPressed: () => setState(() => more = !more),
                    child: Text(more ? 'Ver menos' : 'Ver más'),
                  ),
                TextButton(
                  onPressed: hub.openDownloads,
                  child: const Text('Abrir carpeta de descargas'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Phone without notification access: what it unlocks and where to turn it on.
class _AccessHint extends StatelessWidget {
  const _AccessHint(this.hub);
  final Hub hub;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Symbols.notifications_active_rounded,
    title: 'Ver tus notificaciones y tu música en el ordenador',
    body: 'Android pide «Acceso a notificaciones» para leerlas y controlar lo que suena.',
    action: 'Activar',
    onAction: hub.openNotifAccess,
  );
}
