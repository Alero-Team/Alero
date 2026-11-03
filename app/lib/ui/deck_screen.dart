import 'package:flutter/material.dart';

import '../hub.dart';
import 'alero_desktop.dart';
import 'phone_page.dart';

/// "Alero Desktop" in the side menu: the phone as a desktop computer (Alero Desktop) over USB or wireless debugging.
class DeckScreen extends StatelessWidget {
  const DeckScreen(this.hub, {super.key});
  final Hub hub;

  @override
  Widget build(BuildContext context) => PhonePage(
    hub: hub,
    title: 'Alero Desktop',
    body: (context, phone) => AdbFinder(
      hub: hub,
      phone: phone,
      builder: (context, d) => d == null
          ? const Align(
              alignment: Alignment.topCenter,
              child: NeedsAdb('Alero Desktop'),
            )
          : AleroDesktopPage(
              hub: hub,
              serial: d.serial,
              deviceName: phone.name,
              peerId: phone.id,
              embedded: true,
            ),
    ),
  );
}
