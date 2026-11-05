import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../phone_adb.dart';
import '../phone_control.dart';
import '../scrcpy.dart';
import '../src/rust/api/engine.dart' as pb;
import 'theme.dart';
import 'widgets.dart';

/// The same ADB controls in Dispositivos, Aplicaciones and Alero Desktop.
/// This does not pair/unpair Alero's TLS engine; it only selects an authorised
/// Android Debug Bridge transport for features implemented through scrcpy.
class AdbConnectionPanel extends StatefulWidget {
  const AdbConnectionPanel({super.key, required this.hub, this.phone});

  final Hub hub;
  final pb.Peer? phone;

  @override
  State<AdbConnectionPanel> createState() => _AdbConnectionPanelState();
}

class _AdbConnectionPanelState extends State<AdbConnectionPanel> {
  bool _busy = false;
  String? _message;

  Future<void> _usb() async {
    if (!Scrcpy.available) {
      setState(() => _message = 'El paquete adb/scrcpy no está instalado en este ordenador.');
      return;
    }
    setState(() => _busy = true);
    try {
      final all = (await Scrcpy.list()).where((d) => !d.wifi).toList();
      final ready = all.where((d) => d.ready).toList();
      if (ready.isEmpty) {
        throw StateError(all.any((d) => d.unauthorized)
            ? 'Autoriza la depuración USB desde la pantalla del teléfono.'
            : 'No se detecta ningún teléfono USB autorizado. Revisa el cable y la depuración USB.');
      }
      final model = widget.phone == null
          ? ''
          : widget.hub.info[widget.phone!.id]?.model.toLowerCase().replaceAll(' ', '_') ?? '';
      final match = ready
          .where((d) => model.isNotEmpty &&
              d.model.toLowerCase().replaceAll(' ', '_') == model)
          .toList();
      final choices = match.isNotEmpty ? match : ready;
      AdbDevice? selected;
      if (choices.length == 1) {
        selected = choices.first;
      } else if (mounted) {
        selected = await showDialog<AdbDevice>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Selecciona el teléfono USB'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final device in choices)
                  ListTile(
                    title: Text(device.name),
                    subtitle: Text(device.serial),
                    onTap: () => Navigator.of(ctx).pop(device),
                  ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancelar')),
            ],
          ),
        );
      }
      if (selected == null) return;
      if (widget.phone != null) PhoneAdb.choose(widget.phone!.id, selected.serial);
      if (mounted) setState(() => _message = 'Depuración USB autorizada: ${selected!.name}.');
    } catch (e) {
      if (mounted) setState(() => _message = e is StateError ? e.message : 'No se pudo consultar adb por USB.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _wireless() async {
    if (!Scrcpy.available) {
      setState(() => _message = 'El paquete adb/scrcpy no está instalado en este ordenador.');
      return;
    }
    final serial = await showDialog<String>(
      context: context,
      builder: (_) => const _WirelessDialog(),
    );
    if (!mounted || serial == null) return;
    if (widget.phone != null) PhoneAdb.choose(widget.phone!.id, serial);
    setState(() => _message = 'ADB inalámbrico conectado y autorizado: $serial');
  }

  Future<void> _disconnectWireless() async {
    final peer = widget.phone;
    if (peer == null) return;
    final serial = PhoneAdb.selectedSerial(peer.id);
    if (serial == null || !AdbDevice(serial, 'device', '').wifi) return;
    setState(() => _busy = true);
    try {
      await Scrcpy.disconnectWireless(serial);
      PhoneAdb.forgetChoice(peer.id);
      if (mounted) setState(() => _message = 'ADB inalámbrico desconectado. El emparejamiento Alero se conserva.');
    } catch (_) {
      if (mounted) setState(() => _message = 'No se pudo desconectar el transporte ADB.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) return const SizedBox.shrink();
    final s = Theme.of(context).colorScheme;
    final serial = widget.phone == null ? null : PhoneAdb.selectedSerial(widget.phone!.id);
    return Panel(
      title: 'Depuración del teléfono',
      icon: Symbols.developer_mode_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Gap.s,
            runSpacing: Gap.s,
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _usb,
                icon: const Icon(Symbols.usb_rounded, size: 18),
                label: const Text('Depuración USB'),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _wireless,
                icon: const Icon(Symbols.wifi_rounded, size: 18),
                label: const Text('Depuración inalámbrica'),
              ),
              if (serial != null && AdbDevice(serial, 'device', '').wifi)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _disconnectWireless,
                  icon: const Icon(Symbols.link_off_rounded, size: 18),
                  label: const Text('Desconectar ADB Wi-Fi'),
                ),
            ],
          ),
          const SizedBox(height: Gap.s),
          Text(
            _message ??
                (serial == null
                    ? 'USB requiere autorización del teléfono. Para Wi-Fi, activa Depuración inalámbrica en Android y utiliza su IP, puerto y código de vinculación.'
                    : 'Transporte ADB elegido: $serial'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Android displays a *pairing port* and a potentially different *connect
/// port*. Both are collected independently. Never persist the one-time code.
class _WirelessDialog extends StatefulWidget {
  const _WirelessDialog();

  @override
  State<_WirelessDialog> createState() => _WirelessDialogState();
}

class _WirelessDialogState extends State<_WirelessDialog> {
  final _ip = TextEditingController();
  final _pairPort = TextEditingController();
  final _code = TextEditingController();
  final _connectPort = TextEditingController();
  bool _pair = true, _busy = false;
  String? _error;

  @override
  void dispose() {
    _ip.dispose();
    _pairPort.dispose();
    _code.dispose();
    _connectPort.dispose();
    super.dispose();
  }

  bool _validIp(String ip) {
    final parts = ip.split('.');
    return parts.length == 4 && parts.every((part) {
      final n = int.tryParse(part);
      return n != null && n >= 0 && n <= 255 && part.isNotEmpty;
    });
  }

  bool _validPort(String port) {
    final n = int.tryParse(port);
    return n != null && n >= 1 && n <= 65535;
  }

  Future<void> _submit() async {
    final ip = _ip.text.trim();
    if (!_validIp(ip)) {
      setState(() => _error = 'Introduce una dirección IPv4 válida del teléfono.');
      return;
    }
    if (_pair && (!_validPort(_pairPort.text.trim()) ||
        !RegExp(r'^\d{6}$').hasMatch(_code.text.trim()))) {
      setState(() => _error = 'Introduce el puerto de vinculación y el código temporal de seis dígitos de Android.');
      return;
    }
    final port = _connectPort.text.trim();
    if (port.isNotEmpty && !_validPort(port)) {
      setState(() => _error = 'El puerto de conexión ADB debe estar entre 1 y 65535.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      if (_pair) {
        await Scrcpy.pair(ip, _pairPort.text.trim(), _code.text.trim());
      }
      // Pairing and connecting are separate operations on Android 11+.
      final address = port.isNotEmpty ? '$ip:$port' : await Scrcpy.find(ip);
      if (address == null) {
        throw StateError('No se encontró el puerto ADB por mDNS. Introduce el puerto de conexión que aparece en Depuración inalámbrica (distinto del de vinculación).');
      }
      if (!await Scrcpy.connect(address)) {
        throw StateError('Android no autorizó la conexión ADB. Revisa la IP, el puerto y el emparejamiento.');
      }
      if (mounted) Navigator.of(context).pop(address);
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'No fue posible establecer ADB por Wi-Fi. Comprueba que los dispositivos estén en la misma red y el teléfono autorice la depuración inalámbrica.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Depuración inalámbrica'),
    content: SizedBox(
      width: 430,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('En el teléfono abre Ajustes › Opciones de desarrollador › Depuración inalámbrica. Actívala y, si es la primera vez, selecciona «Vincular dispositivo con código de vinculación».'),
            const SizedBox(height: Gap.m),
            TextField(
              controller: _ip,
              decoration: const InputDecoration(labelText: 'Dirección IP del teléfono (p. ej., 192.168.1.10)'),
              keyboardType: TextInputType.url,
            ),
            SwitchListTile(
              title: const Text('Vincular por primera vez'),
              subtitle: const Text('Desactívalo si este ordenador ya está autorizado.'),
              value: _pair,
              onChanged: _busy ? null : (value) => setState(() => _pair = value),
            ),
            if (_pair) ...[
              TextField(
                controller: _pairPort,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Puerto de vinculación'),
              ),
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Código temporal de 6 dígitos'),
              ),
            ],
            TextField(
              controller: _connectPort,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Puerto de conexión ADB (opcional con mDNS)',
                helperText: 'No reutilices el puerto de vinculación salvo que Android muestre el mismo.',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.s),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: Text(_busy ? 'Conectando…' : 'Conectar'),
      ),
    ],
  );
}
