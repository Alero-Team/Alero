// Interactive web simulation of the Android UI with made-up data (no engine, no real device).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n.dart';
import 'sim/demo.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  isPhone = true;
  L10n.instance.set('es');
  for (var i = 0; i < 18; i++) {
    pics.add(await landscape(i));
  }
  icons.addAll({
    'com.whatsapp': await appIcon(const Color(0xFF25A366)),
    'com.google.android.gm': await appIcon(const Color(0xFFD9483B)),
    'com.google.android.calendar': await appIcon(const Color(0xFF3F6FD8)),
    'com.example.parcels': await appIcon(const Color(0xFFE0A030)),
  });
  final hub = phoneDemo();
  runApp(SimApp(hub));
}

class SimApp extends StatelessWidget {
  const SimApp(this.hub, {super.key});
  final ShotHub hub;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([hub.themeMode, hub.amoled, hub.colorStyle, hub.colorSeed, L10n.instance]),
    builder: (_, _) {
      const seed = Color(0xFF3F6FD8);
      final expressive = hub.colorStyle.value == 'expressive';
      final fixed = int.tryParse(hub.colorSeed.value, radix: 16);
      ThemeData th(Brightness b) => buildTheme(expressive && fixed != null ? Color(fixed) : seed, DynamicSchemeVariant.tonalSpot, b,
          amoled: b == Brightness.dark && hub.amoled.value, expressive: expressive);
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Alero',
        theme: th(Brightness.light),
        darkTheme: th(Brightness.dark),
        themeMode: switch (hub.theme) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        themeAnimationDuration: const Duration(milliseconds: 300),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('es'), Locale('en')],
        locale: L10n.instance.locale,
        home: Shell(hub),
      );
    },
  );
}
