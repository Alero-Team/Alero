import 'dart:async';

import 'package:flutter/material.dart';

import 'hub.dart';
import 'native.dart';
import 'src/rust/api/engine.dart' as pb;
import 'src/rust/frb_generated.dart';

// Test UI for spike S9 (ADR-0007): functional, not the final G5 design. It only reads Hub state and calls Hub.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await Native.initDesktop();
  final hub = Hub();
  runApp(App(hub));
  await hub.start(); // after the first frame is queued, so the window shows at once
}

class App extends StatelessWidget {
  const App(this.hub, {super.key});
  final Hub hub;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Phonebridge',
        theme: ThemeData(colorSchemeSeed: const Color(0xFFB5E61D), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFFB5E61D), brightness: Brightness.dark, useMaterial3: true),
        home: Home(hub),
      );
}

class Home extends StatefulWidget {
  const Home(this.hub, {super.key});
  final Hub hub;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Hub get hub => widget.hub;
  late final StreamSubscription<String> _msgs;
  final _addr = TextEditingController();
  String? _shownPair, _shownOffer;

  @override
  void initState() {
    super.initState();
    _msgs = hub.messages.stream.listen((m) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    });
    hub.addListener(_dialogs);
  }

  @override
  void dispose() {
    _msgs.cancel();
    hub.removeListener(_dialogs);
    super.dispose();
  }

  /// Pair code and incoming-file questions appear as dialogs, once each.
  void _dialogs() {
    final p = hub.pairPrompt;
    if (p != null && _shownPair != p.peerId) {
      _shownPair = p.peerId;
      _ask(
        'Emparejar con ${p.name}',
        'Comprueba que el otro dispositivo muestra el mismo código:\n\n${p.code}',
        'Coinciden',
        hub.answerPair,
      ).then((_) => _shownPair = null);
    }
    final o = hub.offer;
    if (o != null && _shownOffer != o.id) {
      _shownOffer = o.id;
      _ask('Archivo entrante', '${o.peerName} quiere enviarte ${o.name} (${size(o.size.toInt())})', 'Aceptar',
          hub.answerOffer);
    }
  }

  Future<void> _ask(String title, String body, String yes, Future<void> Function(bool) answer) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body, style: const TextStyle(fontSize: 18)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Rechazar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
        ],
      ),
    );
    await answer(ok ?? false);
  }

  Future<void> _rename() async {
    final c = TextEditingController(text: hub.name);
    final n = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nombre de este dispositivo'),
        content: TextField(controller: c, autofocus: true, maxLength: 64),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Guardar'))],
      ),
    );
    if (n != null) hub.setName(n);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: hub,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: Text(hub.name),
            actions: [
              IconButton(tooltip: 'Cambiar nombre', icon: const Icon(Icons.edit), onPressed: _rename),
              IconButton(tooltip: 'Actualizar', icon: const Icon(Icons.refresh), onPressed: hub.refresh),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: hub.refresh,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              if (hub.startError.isNotEmpty)
                Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(hub.startError))),
              _section('Dispositivos'),
              if (hub.peers.isEmpty)
                const Text('No hay dispositivos. Abre la app en el otro equipo, en la misma red Wi-Fi.'),
              for (final p in hub.peers) _peer(p),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _addr,
                    decoration: const InputDecoration(labelText: 'Emparejar por IP (ej. 192.168.1.20)'),
                    onSubmitted: hub.pairAddr,
                  ),
                ),
                IconButton(tooltip: 'Emparejar', icon: const Icon(Icons.link), onPressed: () => hub.pairAddr(_addr.text)),
              ]),
              if (hub.active.isNotEmpty) _section('En curso'),
              for (final x in hub.active) _xfer(x),
              _section('Historial', action: hub.history.isEmpty ? null : ('Borrar', hub.clearHistory)),
              if (hub.history.isEmpty) const Text('Sin transferencias todavía.'),
              for (final h in hub.history.reversed.take(50)) _history(h),
              _section('Ajustes'),
              SwitchListTile(
                title: const Text('Aceptar archivos de dispositivos emparejados sin preguntar'),
                value: hub.autoAccept,
                onChanged: hub.setAutoAccept,
              ),
              ListTile(title: const Text('Carpeta de recepción'), subtitle: Text(hub.downloads)),
              ExpansionTile(
                title: const Text('Diagnóstico'),
                children: [
                  SelectableText('ID: ${hub.myId}\n${hub.diagnostics.join('\n')}'),
                ],
              ),
            ]),
          ),
        ),
      );

  Widget _section(String t, {(String, Future<void> Function())? action}) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Row(children: [
          Expanded(child: Text(t, style: Theme.of(context).textTheme.titleMedium)),
          if (action != null) TextButton(onPressed: action.$2, child: Text(action.$1)),
        ]),
      );

  Widget _peer(pb.Peer p) {
    final connected = p.state == pb.PeerState.connected;
    final state = switch (p.state) {
      pb.PeerState.connected => 'Conectado',
      pb.PeerState.connecting => 'Conectando…',
      pb.PeerState.rejected => 'Te ha quitado de sus dispositivos',
      pb.PeerState.disconnected => p.trusted ? 'Desconectado' : 'Disponible para emparejar',
    };
    return Card(
      child: ListTile(
        leading: Icon(connected ? Icons.link : Icons.link_off),
        title: Text(p.name),
        subtitle: Text([state, p.addr, p.detail].where((s) => s.isNotEmpty).join(' · ')),
        trailing: Wrap(spacing: 4, children: [
          if (!p.trusted) FilledButton(onPressed: () => hub.pair(p.id), child: const Text('Emparejar')),
          if (p.trusted && connected) FilledButton(onPressed: () => hub.send(p.id), child: const Text('Enviar')),
          if (p.trusted)
            IconButton(tooltip: 'Olvidar', icon: const Icon(Icons.delete_outline), onPressed: () => hub.forget(p.id)),
        ]),
      ),
    );
  }

  Widget _xfer(Xfer x) {
    final f = x.size == 0 ? null : x.done / x.size;
    return Card(
      child: ListTile(
        leading: Icon(x.incoming ? Icons.download : Icons.upload),
        title: Text(x.name),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 6),
          LinearProgressIndicator(value: f),
          const SizedBox(height: 4),
          Text(x.note.isNotEmpty
              ? x.note
              : '${f == null ? '' : '${(f * 100).toStringAsFixed(0)} % · '}${size(x.done)} de ${size(x.size)} · ${size(x.rate)}/s'),
        ]),
        trailing: IconButton(tooltip: 'Cancelar', icon: const Icon(Icons.close), onPressed: () => hub.cancel(x.id)),
      ),
    );
  }

  Widget _history(pb.HistoryItem h) {
    final ok = h.status == 'done';
    return ListTile(
      dense: true,
      leading: Icon(ok ? Icons.check_circle_outline : Icons.error_outline),
      title: Text(h.name),
      subtitle: Text('${h.incoming ? 'De' : 'A'} ${h.peerName} · ${size(h.size.toInt())}'
          '${ok ? '' : ' · ${Hub.explain(h.code, h.message)}'}'),
      trailing: ok || h.incoming
          ? null
          : TextButton(onPressed: () => hub.retry(h.id), child: const Text('Reintentar')),
    );
  }
}

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
