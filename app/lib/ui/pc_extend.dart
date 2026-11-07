import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../native.dart';
import '../src/rust/api/engine.dart' as pb;
import 'pc_screen.dart';

const _driverUrl = 'https://github.com/VirtualDrivers/Virtual-Display-Driver';

Future<void> openPcExtend(
  BuildContext context,
  Hub hub,
  String peer,
  String name,
) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => PcExtendPage(hub, peer, name)));

/// This does not mirror Windows' primary monitor: a signed IddCx virtual
/// display adds a second monitor in Windows, and Alero streams that monitor.
class PcExtendPage extends StatefulWidget {
  const PcExtendPage(this.hub, this.peer, this.name, {super.key});
  final Hub hub;
  final String peer, name;

  @override
  State<PcExtendPage> createState() => _PcExtendPageState();
}

class _PcExtendPageState extends State<PcExtendPage> {
  bool _starting = false;
  bool _showing = false;
  bool _requested = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    widget.hub.addListener(_onHub);
  }

  @override
  void dispose() {
    widget.hub.removeListener(_onHub);
    if (_requested) {
      widget.hub.sendMessage(widget.peer, 'pb.x.extend.stop', {});
    }
    super.dispose();
  }

  void _onHub() {
    if (!_starting || _showing || !mounted) return;
    final result = widget.hub.extendSession[widget.peer];
    if (result == null) return;
    _starting = false;
    if (result['ok'] == true && result['monitor'] is num) {
      _showing = true;
      final monitor = (result['monitor'] as num).toInt();
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await openPcScreen(
          context,
          widget.hub,
          widget.peer,
          widget.name,
          monitor: monitor,
        );
        if (!mounted) return;
        widget.hub.sendMessage(widget.peer, 'pb.x.extend.stop', {});
        _requested = false;
        setState(() => _showing = false);
      });
    } else {
      setState(
        () => _message = switch (result['reason']) {
          'driver_missing' =>
            'Windows necesita el controlador de pantalla virtual '
                'firmado IddCx. Instálalo en Windows para que aparezca el segundo monitor.',
          'not_allowed' =>
            'Autoriza Pantalla extendida en Ajustes de Alero para Windows.',
          'busy' =>
            'El segundo monitor está siendo utilizado por otro dispositivo.',
          'no_virtual_display' => 'Windows no activó un segundo monitor.',
          _ => 'Windows no pudo crear la pantalla extendida.',
        },
      );
    }
  }

  void _start() {
    if (_starting || _showing) return;
    final online = widget.hub.peers.any(
      (p) => p.id == widget.peer && p.state == pb.PeerState.connected,
    );
    if (!online) {
      setState(() => _message = 'El ordenador no está conectado.');
      return;
    }
    widget.hub.extendSession.remove(widget.peer);
    _requested = true;
    setState(() {
      _starting = true;
      _message = null;
    });
    widget.hub.sendMessage(widget.peer, 'pb.x.extend.start', {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Extender pantalla')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(Symbols.desktop_windows_rounded, size: 64),
          const SizedBox(height: 16),
          Text(
            'Usar el teléfono como segundo monitor de Windows',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          const Text(
            'Windows crea una pantalla nueva: puedes arrastrar ventanas desde '
            'el monitor principal al teléfono. Los datos viajan por la red '
            'local y la conexión cifrada de Alero, sin ADB.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _starting || _showing ? null : _start,
            icon: const Icon(Symbols.add_to_photos_rounded),
            label: Text(
              _starting ? 'Creando pantalla…' : 'Activar segunda pantalla',
            ),
          ),
          if (_starting)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(_message!, textAlign: TextAlign.center),
            ),
          const SizedBox(height: 16),
          Text(
            'Controlador IddCx para Windows',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () {
                  widget.hub.sendMessage(widget.peer, 'pb.x.extend.driver', {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Abriendo la descarga en ${widget.name}…'),
                    ),
                  );
                },
                icon: const Icon(Symbols.computer_rounded),
                label: const Text('Abrir en el PC'),
              ),
              TextButton.icon(
                onPressed: () => Native.openUrl(_driverUrl),
                icon: const Icon(Symbols.open_in_new_rounded),
                label: const Text('Ver en el teléfono'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
