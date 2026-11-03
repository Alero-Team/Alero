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
  });
  final Hub hub;
  final String title;
  final Widget Function(BuildContext context, pb.Peer phone) body;
  final List<Widget> Function(pb.Peer phone)? actions;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hub,
    builder: (context, _) {
      final phone = hub.connectedPhone;
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
    _look();
  }

  Future<void> _look() async {
    final d = await PhoneAdb.find(
      widget.phone,
      widget.hub.info[widget.phone.id]?.model ?? '',
    );
    if (!mounted) return;
    setState(() {
      _d = d;
      _looking = false;
    });
    // A cable plugged in, or "Permitir" tapped on the phone, shows up within a few seconds.
    if (d == null) Future.delayed(const Duration(seconds: 4), _look);
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
        'Conecta el teléfono por USB con «Depuración USB» activada, o usa la depuración inalámbrica '
        '(Inicio › Controlar teléfono › Preparar el teléfono). Solo se configura una vez.',
  );
}
