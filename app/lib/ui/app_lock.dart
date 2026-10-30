import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../native.dart';

/// Above the Navigator so existing dialogs and routes cannot bypass the lock.
class AppLock extends StatefulWidget {
  const AppLock({super.key, required this.child});
  final Widget child;
  @override
  State<AppLock> createState() => _AppLockState();
}

class _AppLockState extends State<AppLock> with WidgetsBindingObserver {
  bool _locked = Native.lock.value, _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Native.lock.addListener(_changed);
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  void _changed() {
    // Enabling the switch itself already required authentication.
    if (!Native.lock.value && mounted) setState(() => _locked = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused && Native.lock.value && !_busy) {
      setState(() => _locked = true);
    } else if (s == AppLifecycleState.resumed && _locked && !_busy) {
      _unlock();
    }
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await Native.authenticate();
      if (mounted) setState(() => _locked = !ok);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Native.lock.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      ExcludeSemantics(excluding: _locked, child: widget.child),
      if (_locked)
        Positioned.fill(
          child: Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_outline, size: 40),
                      const SizedBox(height: 16),
                      Text(
                        'Alero está bloqueado',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _error ?? 'Usa tu huella o el PIN del dispositivo.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _unlock,
                        child: const Text('Desbloquear'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
