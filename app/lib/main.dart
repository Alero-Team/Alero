import 'package:flutter/material.dart';

import 'hub.dart';
import 'native.dart';
import 'src/rust/frb_generated.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

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
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Palette.light, Brightness.light),
    darkTheme: buildTheme(Palette.dark, Brightness.dark),
    home: Shell(hub),
  );
}
