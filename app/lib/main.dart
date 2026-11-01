import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_info.dart';
import 'hub.dart';
import 'native.dart';
import 'src/rust/frb_generated.dart';
import 'ui/shell.dart';
import 'ui/brand.dart';
import 'ui/setup.dart';
import 'ui/app_lock.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerAleroLicenses();
  final color = SystemColor();
  final hub = Hub();
  final boot = ValueNotifier<String?>('');
  final animate = await Native.firstLaunch();
  runApp(App(hub, color, boot: boot, animate: animate));
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      await RustLib.init();
      await color.load();
      await Native.initDesktop();
      await Native.loadLock();
      await hub.start();
      boot.value = null;
    } catch (e) {
      boot.value = 'No se pudo iniciar Alero: $e';
    }
  });
}

class App extends StatelessWidget {
  const App(
    this.hub,
    this.color, {
    super.key,
    required this.boot,
    required this.animate,
  });
  final ValueNotifier<String?> boot;
  final bool animate;
  final Hub hub;
  final SystemColor color;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Only theme inputs rebuild the app; engine events rebuild the screens below.
    listenable: Listenable.merge([color, hub.themeMode, hub.amoled, boot]),
    builder: (_, _) {
      final (seed, variant) = color.value;
      return MaterialApp(
        title: 'Alero',
        locale: const Locale('es'),
        supportedLocales: const [Locale('es')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        debugShowCheckedModeBanner: false,
        theme: buildTheme(seed, variant, Brightness.light),
        darkTheme: buildTheme(
          seed,
          variant,
          Brightness.dark,
          amoled: hub.amoled.value,
        ),
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
          final toast = th.snackBarTheme.copyWith(
            width: MediaQuery.sizeOf(context).width >= 600 ? 420 : null,
          );
          return Theme(
            data: th.copyWith(snackBarTheme: toast),
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.5,
              child: boot.value == null ? AppLock(child: child!) : child!,
            ),
          );
        },
        home: boot.value != null
            ? Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: boot.value!.isNotEmpty
                        ? SelectableText(boot.value!)
                        : animate
                        ? const AleroIntro(size: 72)
                        : const AleroMark(size: 72),
                  ),
                ),
              )
            : _ReadyHome(hub, color),
      );
    },
  );
}

class _ReadyHome extends StatefulWidget {
  const _ReadyHome(this.hub, this.color);
  final Hub hub;
  final SystemColor color;
  @override
  State<_ReadyHome> createState() => _ReadyHomeState();
}

class _ReadyHomeState extends State<_ReadyHome> {
  Section _initial = Section.home;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.hub,
    builder: (_, _) => widget.hub.setupDone
        ? Shell(
            widget.hub,
            onResume: widget.color.load,
            initialSection: _initial,
          )
        : SetupScreen(
            widget.hub,
            onDone: (pair) {
              _initial = pair ? Section.devices : Section.home;
              widget.hub.finishSetup();
            },
          ),
  );
}
