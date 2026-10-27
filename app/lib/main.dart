import 'package:flutter/material.dart';

import 'hub.dart';
import 'native.dart';
import 'src/rust/frb_generated.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final color = SystemColor();
  await color.load(); // before the first frame, so the window opens in the user's colors
  await Native.initDesktop();
  final hub = Hub();
  runApp(App(hub, color));
  await hub.start(); // after the first frame is queued, so the window shows at once
}

class App extends StatelessWidget {
  const App(this.hub, this.color, {super.key});
  final Hub hub;
  final SystemColor color;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Only theme inputs rebuild the app; engine events rebuild the screens below.
    listenable: Listenable.merge([color, hub.themeMode]),
    builder: (_, _) {
      final (seed, variant) = color.value;
      return MaterialApp(
        title: 'Alero',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(seed, variant, Brightness.light),
        darkTheme: buildTheme(seed, variant, Brightness.dark),
        themeMode: switch (hub.theme) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        themeAnimationDuration: const Duration(milliseconds: 300),
        // Honor the user's text size, but past 1.5x the layouts (bars, tiles) stop fitting.
        builder: (context, child) {
          final th = Theme.of(context);
          // Toasts are a fixed-width card on big windows and full width (minus margins) on phones.
          final toast = th.snackBarTheme.copyWith(width: MediaQuery.sizeOf(context).width >= 600 ? 420 : null);
          return Theme(
            data: th.copyWith(snackBarTheme: toast),
            child: MediaQuery.withClampedTextScaling(maxScaleFactor: 1.5, child: child!),
          );
        },
        home: Shell(hub, onResume: color.load),
      );
    },
  );
}
