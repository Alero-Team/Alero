import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../hub.dart';
import '../phone_adb.dart';
import '../phone_control.dart';
import '../src/rust/api/engine.dart' as pb;
import 'theme.dart';
import 'widgets.dart';

/// Frame of the computer's phone sections (Mensajes, Llamadas, Fotos…): title, actions, and the connected
/// phone handed to [body]; without one, a single "connect a phone" message.
class PhonePage extends StatelessWidget {
  const PhonePage({
    super.key,
    required this.hub,
    required this.title,
    required this.body,
    this.actions,
    this.allowPairedOffline = false,
  });
  final bool allowPairedOffline;
  final Hub hub;
  final String title;
  final Widget Function(BuildContext context, pb.Peer phone) body;
  final List<Widget> Function(pb.Peer phone)? actions;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hub,
    builder: (context, _) {
      // ADB can control a previously paired phone even when Alero's app
      // session is offline; the two connection systems are independent.
      final phone =
          hub.connectedPhone ??
          (allowPairedOffline
              ? hub.peers
                        .where(
                          (p) => p.trusted && hub.info[p.id]?.phone == true,
                        )
                        .firstOrNull ??
                    hub.peers.where((p) => p.trusted).firstOrNull
              : null);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xxl, Gap.xl, Gap.xxl, Gap.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ),
                  ),
                  if (phone != null && actions != null) ...actions!(phone),
                ],
              ),
              const SizedBox(height: Gap.l),
              Expanded(
                child: phone == null
                    ? const Align(
                        alignment: Alignment.topCenter,
                        child: EmptyState(
                          icon: Symbols.smartphone_rounded,
                          title: 'Conecta un teléfono',
                          body: 'Abre Alero en el teléfono emparejado, por Wi-Fi o con el cable.',
                        ),
                      )
                    : body(context, phone),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Finds (and keeps looking for) the adb connection of [phone]; [builder] gets null until there is one.
class AdbFinder extends StatefulWidget {
  const AdbFinder({
    super.key,
    required this.hub,
    required this.phone,
    required this.builder,
  });
  final Hub hub;
  final pb.Peer phone;
  final Widget Function(BuildContext context, AdbDevice? device) builder;

  @override
  State<AdbFinder> createState() => _AdbFinderState();
}

class _AdbFinderState extends State<AdbFinder> {
  AdbDevice? _d;
  bool _looking = true;

  @override
  void initState() {
    super.initState();
    PhoneAdb.selectedChanged.addListener(_look);
    _look();
  }

  @override
  void didUpdateWidget(AdbFinder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phone.id != widget.phone.id) _look();
  }

  @override
  void dispose() {
    PhoneAdb.selectedChanged.removeListener(_look);
    super.dispose();
  }

  int _request = 0;

  Future<void> _look() async {
    final request = ++_request;
    AdbDevice? d;
    try {
      d = await PhoneAdb.find(
        widget.phone,
        widget.hub.info[widget.phone.id]?.model ?? '',
      );
    } catch (_) {
      d = null;
    }
    if (!mounted || request != _request) return;
    if (_looking || d?.serial != _d?.serial) {
      setState(() {
        _d = d;
        _looking = false;
      });
    }
    // Keep watching after it is found too: a Wi-Fi drop ends the transport and find() reconnects it.
    Future.delayed(Duration(seconds: d == null ? 4 : 10), () {
      if (mounted && request == _request) _look();
    });
  }

  @override
  Widget build(BuildContext context) => _looking
      ? const Center(child: CircularProgressIndicator())
      : widget.builder(context, _d);
}

/// What to do when a feature needs adb and there is none.
class NeedsAdb extends StatelessWidget {
  const NeedsAdb(this.feature, {super.key, this.card = true});
  final String feature;
  final bool card;

  @override
  Widget build(BuildContext context) => EmptyState(
    card: card,
    icon: Symbols.usb_rounded,
    title: '$feature necesita la depuración del teléfono',
    body:
        'Utiliza «Depuración USB» o «Depuración inalámbrica» en este apartado. '
        'Android debe autorizar el ordenador para usar ADB; no hace falta root.',
  );
}
