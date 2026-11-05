import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../phone_control.dart';
import '../scrcpy.dart';
import 'adb_connection.dart';
import 'phone_page.dart';
import 'theme.dart';

/// "Aplicaciones": the phone's apps; each opens in its own computer window, on a virtual display of its own, so
/// the phone stays free and several apps run side by side. Needs adb (USB or wireless debugging).
class AppsScreen extends StatelessWidget {
  const AppsScreen(this.hub, {super.key});
  final Hub hub;

  @override
  Widget build(BuildContext context) => PhonePage(
    hub: hub,
    title: 'Aplicaciones',
    allowPairedOffline: true,
    body: (context, phone) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdbConnectionPanel(hub: hub, phone: phone),
        const SizedBox(height: Gap.m),
        Expanded(
          child: AdbFinder(
            hub: hub,
            phone: phone,
            builder: (context, d) => d == null
                ? const Align(
                    alignment: Alignment.topCenter,
                    child: NeedsAdb('Abrir apps en ventanas'),
                  )
                : _Apps(hub, d, phone.id, phone.name, key: ValueKey(d.serial)),
          ),
        ),
      ],
    ),
  );
}

class _Apps extends StatefulWidget {
  const _Apps(this.hub, this.device, this.phoneId, this.phoneName, {super.key});
  final Hub hub;
  final AdbDevice device;
  final String phoneId, phoneName;

  @override
  State<_Apps> createState() => _AppsState();
}

class _AppsState extends State<_Apps> {
  late Future<List<(String, String)>> _apps = _load();
  String _q = '';

  /// adb gives names only: the icons come from Alero on the phone, once per app.
  Future<List<(String, String)>> _load() async {
    final apps = await Scrcpy.appsWithNames(widget.device.serial);
    final missing = [
      for (final a in apps)
        if (!widget.hub.appIcons.containsKey(a.$2)) a.$2,
    ];
    // Application icons are an optional Alero TLS feature. Opening apps
    // via authorised ADB must also work while that channel is offline.
    if (missing.isNotEmpty && widget.hub.connectedPhone?.id == widget.phoneId) {
      widget.hub.phoneCmd(widget.phoneId, 'icons', {'pkgs': missing});
    }
    return apps;
  }

  Future<void> _open((String, String) a) => PhoneSessions.instance.start(
    widget.device.serial,
    '${a.$1} · ${widget.phoneName}',
    SessionOptions(appWindow: true, startApp: a.$2, maxSize: 1280),
    extra: 'app:${a.$2}',
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                decoration: const InputDecoration(
                  hintText: 'Buscar apps',
                  prefixIcon: Icon(Symbols.search_rounded),
                ),
              ),
            ),
            const SizedBox(width: Gap.s),
            IconButton(
              tooltip: 'Actualizar',
              onPressed: () => setState(() => _apps = _load()),
              icon: const Icon(Symbols.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: Gap.s),
        Text(
          'Cada app se abre en su propia ventana, en una pantalla virtual: el teléfono sigue libre. '
          'Cerrar la ventana cierra la app en el ordenador.',
          style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
        ),
        const SizedBox(height: Gap.l),
        Expanded(
          child: FutureBuilder(
            future: _apps,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final list = snap.data!
                  .where(
                    (a) =>
                        _q.isEmpty ||
                        a.$1.toLowerCase().contains(_q) ||
                        a.$2.contains(_q),
                  )
                  .toList();
              if (list.isEmpty) {
                return const Center(child: Text('Ninguna app coincide.'));
              }
              return ListenableBuilder(
                listenable: Listenable.merge([
                  PhoneSessions.instance,
                  widget.hub,
                ]),
                builder: (context, _) => GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 150,
                    mainAxisSpacing: Gap.m,
                    crossAxisSpacing: Gap.m,
                    childAspectRatio: 0.95,
                  ),
                  itemCount: list.length,
                  itemBuilder: (_, i) => AppTile(
                    name: list[i].$1,
                    icon: widget.hub.appIcons[list[i].$2],
                    open: PhoneSessions.instance.runningExtra(
                      widget.device.serial,
                      'app:${list[i].$2}',
                    ),
                    onTap: () => _open(list[i]),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// An app as a big tile: its icon (its initial on a tonal shape until the icon arrives), the name, and a dot while open.
class AppTile extends StatelessWidget {
  const AppTile({
    super.key,
    required this.name,
    required this.onTap,
    this.open = false,
    this.dark = false,
    this.icon,
  });
  final String name;
  final Uint8List? icon;
  final VoidCallback onTap;
  final bool open, dark;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    // A stable color per app, from its name.
    final tones = [
      (s.primaryContainer, s.onPrimaryContainer),
      (s.secondaryContainer, s.onSecondaryContainer),
      (s.tertiaryContainer, s.onTertiaryContainer),
    ];
    final (bg, fg) =
        tones[name.codeUnits.fold(0, (a, b) => a + b) % tones.length];
    return Semantics(
      button: true,
      label: '$name${open ? ', abierta' : ''}',
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.tile),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.s),
          child: Column(
            children: [
              Expanded(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: icon != null
                      ? Image.memory(
                          icon!,
                          filterQuality: FilterQuality.medium,
                          gaplessPlayback: true,
                        )
                      : DecoratedBox(
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(Radii.tile + 6),
                    ),
                    child: Center(
                      child: Text(
                        name.isEmpty
                            ? '?'
                            : name.characters.first.toUpperCase(),
                        style: t.headlineMedium?.copyWith(color: fg),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Gap.s),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (open) ...[
                    Icon(Symbols.circle, size: 8, fill: 1, color: s.primary),
                    const SizedBox(width: Gap.xs),
                  ],
                  Flexible(
                    child: ExcludeSemantics(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(
                          color: dark ? Colors.white : null,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
