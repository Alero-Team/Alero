import 'package:flutter/material.dart';

import '../hub.dart';
import 'alero_desktop.dart';
import 'adb_connection.dart';
import 'phone_page.dart';
import 'theme.dart';

/// "Alero Desktop" in the side menu: the phone as a desktop computer (Alero Desktop) over USB or wireless debugging.
class DeckScreen extends StatelessWidget {
  const DeckScreen(this.hub, {super.key});
  final Hub hub;

  @override
  Widget build(BuildContext context) => PhonePage(
    hub: hub,
    title: 'Alero Desktop',
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
                    child: NeedsAdb('Alero Desktop'),
                  )
                : AleroDesktopPage(
                    key: ValueKey(d.serial),
                    hub: hub,
                    serial: d.serial,
                    deviceName: phone.name,
                    peerId: phone.id,
                    embedded: true,
                  ),
          ),
        ),
      ],
    ),
  );
}
