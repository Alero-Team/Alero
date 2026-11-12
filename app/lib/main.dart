import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_info.dart';
import 'hub.dart';
import 'native.dart';
import 'src/rust/frb_generated.dart';
import 'ui/shell.dart';
import 'ui/brand.dart';
import 'ui/expressive.dart' show motion, motionScale;
import 'ui/setup.dart';
import 'ui/app_lock.dart';
import 'ui/icon.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerAleroLicenses();
  final color = SystemColor();
  final hub = Hub();
  final boot = ValueNotifier<String?>('');
  runApp(App(hub, color, boot: boot));
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    // The splash plays out even if the engine is quicker; a slower engine just keeps the logo on screen.
    final reduced = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    final hold = Future<void>.delayed(
      reduced ? Duration.zero : splashBase * motionScale,
    );
    try {
      await RustLib.init();
      await color.load();
      await Native.initDesktop();
      await Native.loadLock();
      await hub.start();
      await hold;
      boot.value = null;
    } catch (e) {
      boot.value = 'No se pudo iniciar Alero: $e';
    }
  });
}

class App extends StatelessWidget {
  const App(this.hub, this.color, {super.key, required this.boot});
  final ValueNotifier<String?> boot;
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
              // Every icon springs when its control is tapped (ui/icon.dart).
              child: IconTaps.listen(
                boot.value == null ? AppLock(child: child!) : child!,
              ),
            ),
          );
        },
        home: _Root(boot.value, hub, color),
      );
    },
  );
}

/// Splash (or the start error) until the engine is ready, then a fade-and-scale into Home or Setup.
class _Root extends StatelessWidget {
  const _Root(this.error, this.hub, this.color);
  final String? error;
  final Hub hub;
  final SystemColor color;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: motion(context, const Duration(milliseconds: 250)),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeIn,
    transitionBuilder: (child, a) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        scale: Tween<double>(begin: .97, end: 1).animate(a),
        child: child,
      ),
    ),
    child: error == null
        ? _ReadyHome(hub, color, key: const ValueKey('ready'))
        : Scaffold(
            key: ValueKey(error!.isEmpty ? 'splash' : 'error'),
            body: Center(
              child: error!.isEmpty
                  ? const AleroSplash()
                  : Padding(
                      padding: const EdgeInsets.all(32),
                      child: SelectableText(error!),
                    ),
            ),
          ),
  );
}

class _ReadyHome extends StatefulWidget {
  const _ReadyHome(this.hub, this.color, {super.key});
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
