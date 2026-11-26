import 'dart:async';

import 'package:flutter/material.dart' hide Icon, Text;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../hub.dart';
import '../remote.dart';
import '../src/rust/api/engine.dart' as pb;
import 'notifications.dart' show ago;
import 'phone_page.dart';
import 'qollqe_motion.dart';
import 'theme.dart';
import 'widgets.dart';
import 'icon.dart';
import '../l10n.dart';

/// "Llamadas": a dial pad with contact search, and the phone's recent calls. The phone dials; you talk on it
/// (or its headset). Answering and hanging up are on the call bar at the top of every screen.
class CallsScreen extends StatelessWidget {
  const CallsScreen(this.hub, {super.key});
  final Hub hub;

  @override
  Widget build(BuildContext context) => PhonePage(
    hub: hub,
    title: 'Llamadas',
    actions: (p) => [
      IconButton(
        tooltip: tx('Actualizar'),
        onPressed: () => hub.phoneCmd(p.id, 'calllog.request'),
        icon: const Icon(FluentIcons.arrow_clockwise_24_regular),
      ),
    ],
    body: (context, phone) => phoneSwap(
      context,
      hub.info[phone.id]?.calls == true
          ? _Calls(hub, phone, key: const ValueKey('calls'))
          : const Align(
              key: ValueKey('off'),
              alignment: Alignment.topCenter,
              child: EmptyState(
                icon: FluentIcons.call_24_regular,
                title: 'Activa las llamadas en el teléfono',
                body: 'En el teléfono: Alero › Ajustes › Llamadas en el ordenador.',
              ),
            ),
    ),
  );
}

class _Calls extends StatefulWidget {
  const _Calls(this.hub, this.phone, {super.key});
  final Hub hub;
  final pb.Peer phone;

  @override
  State<_Calls> createState() => _CallsState();
}

class _CallsState extends State<_Calls> {
  final _number = TextEditingController();
  Timer? _search;
  Hub get hub => widget.hub;
  String get id => widget.phone.id;

  @override
  void initState() {
    super.initState();
    hub.phoneCmd(id, 'calllog.request');
  }

  @override
  void dispose() {
    _search?.cancel();
    _number.dispose();
    super.dispose();
  }

  void _changed(String v) {
    setState(() {});
    _search?.cancel();
    // Letters search contacts by name; digits by number. The phone answers with at most 60.
    if (v.trim().length >= 2) {
      _search = Timer(
        const Duration(milliseconds: 300),
        () => hub.phoneCmd(id, 'contacts', {'q': v.trim()}),
      );
    }
  }

  void _key(String k) {
    _number.text += k;
    _changed(_number.text);
  }

  Future<void> _call([String? number]) async {
    final n = (number ?? _number.text).trim();
    if (n.isEmpty) return;
    await hub.dial(id, n);
    hub.messages.add(tr('Llamando a {} desde el teléfono…', [n]));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hub,
    builder: (context, _) {
      final s = Theme.of(context).colorScheme;
      final t = Theme.of(context).textTheme;
      final log = hub.callLog[id];
      final found = _number.text.trim().length >= 2
          ? (hub.contacts[id] ?? const <CallEntry>[])
          : const <CallEntry>[];
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.l),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _number,
                        onChanged: _changed,
                        onSubmitted: (_) => _call(),
                        style: t.headlineSmall,
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(
                          hintText: tx('Número o nombre'),
                          suffixIcon: _number.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: tx('Borrar'),
                                  onPressed: () {
                                    _number.clear();
                                    _changed('');
                                  },
                                  icon: const Icon(FluentIcons.backspace_24_regular),
                                ),
                        ),
                      ),
                      ArcExpand(
                        expanded: found.isNotEmpty,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 180),
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final c in found)
                                ListTile(
                                  dense: true,
                                  leading: const Icon(FluentIcons.person_24_regular),
                                  title: Text(c.name),
                                  subtitle: Text(c.number),
                                  onTap: () => _call(c.number),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: Gap.m),
                      GridView.count(
                        crossAxisCount: 3,
                        shrinkWrap: true,
                        mainAxisSpacing: Gap.s,
                        crossAxisSpacing: Gap.s,
                        childAspectRatio: 1.6,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          for (final k in [
                            '1',
                            '2',
                            '3',
                            '4',
                            '5',
                            '6',
                            '7',
                            '8',
                            '9',
                            '*',
                            '0',
                            '#',
                          ])
                            FilledButton.tonal(
                              onPressed: () => _key(k),
                              style: FilledButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    Radii.tile,
                                  ),
                                ),
                              ),
                              child: Text(k, style: t.titleLarge),
                            ),
                        ],
                      ),
                      const SizedBox(height: Gap.m),
                      FilledButton.icon(
                        onPressed: _number.text.trim().isEmpty
                            ? null
                            : () => _call(),
                        icon: const Icon(FluentIcons.call_24_regular),
                        label: const Text('Llamar'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: Gap.l),
          Expanded(
            child: SingleChildScrollView(
              child: Panel(
                title: 'Recientes',
                icon: FluentIcons.history_24_regular,
                child: MotionFade(
                  child: log == null
                      ? const Padding(
                          key: ValueKey('loading'),
                          padding: EdgeInsets.all(Gap.xl),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : hub.phoneState[id]?.callLog == false
                      ? const EmptyState(
                          key: ValueKey('denied'),
                          card: false,
                          icon: FluentIcons.lock_closed_24_regular,
                          title: 'Falta el permiso del registro de llamadas',
                          body: 'En el teléfono: Alero › Ajustes › Llamadas en el ordenador. Apágalo y vuelve a encenderlo para concederlo.',
                        )
                      : log.isEmpty
                      ? const Text(
                          'No hay llamadas recientes.',
                          key: ValueKey('empty'),
                        )
                      : Column(
                          key: const ValueKey('log'),
                          children: [
                            for (final (i, c) in log.take(60).indexed)
                              QollqeMotion.reveal(
                                context,
                                i,
                                ListTile(
                                  leading: Icon(
                                    switch (c.type) {
                                      'in' => FluentIcons.call_inbound_24_regular,
                                      'out' => FluentIcons.call_outbound_24_regular,
                                      'missed' => FluentIcons.call_missed_24_regular,
                                      _ => FluentIcons.call_end_24_regular,
                                    },
                                    color:
                                        c.type == 'missed' ||
                                            c.type == 'rejected'
                                        ? s.error
                                        : s.onSurfaceVariant,
                                  ),
                                  title: Text(c.who),
                                  subtitle: Text(
                                    '${switch (c.type) {
                                      'in' => 'Recibida',
                                      'out' => 'Realizada',
                                      'missed' => 'Perdida',
                                      'rejected' => 'Rechazada',
                                      _ => 'Llamada',
                                    }} · ${ago(c.date)}${c.duration > 0 ? ' · ${c.duration ~/ 60}:${(c.duration % 60).toString().padLeft(2, '0')}' : ''}',
                                  ),
                                  trailing: IconButton(
                                    tooltip: tr('Llamar a {}', [c.who]),
                                    onPressed: c.number.isEmpty
                                        ? null
                                        : () => _call(c.number),
                                    icon: const Icon(FluentIcons.call_24_regular),
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
