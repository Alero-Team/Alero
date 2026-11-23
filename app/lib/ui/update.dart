import 'dart:io';

import 'package:flutter/material.dart' hide Icon, Text;
import 'package:flutter/services.dart' show PlatformException;

import '../l10n.dart';
import '../native.dart';
import '../updater.dart';
import 'expressive.dart' show showAleroDialog;
import 'alero_motion.dart' show ToastMotion;
import 'theme.dart' show Gap;

bool _checking = false;

/// On open: looks for a newer release and, if there is one, offers it. Offline or up to date, it says nothing.
Future<void> checkUpdatesOnOpen(BuildContext context) =>
    _check(context, manual: false);

/// The "Buscar actualizaciones" button: also says when there is nothing new or the check failed.
Future<void> checkUpdatesNow(BuildContext context) =>
    _check(context, manual: true);

String _why(Object e) => switch (e) {
  PlatformException(:final message) when message != null => message,
  HttpException(:final message) => message,
  _ => '$e',
};

Future<void> _check(BuildContext context, {required bool manual}) async {
  if (_checking) return;
  _checking = true;
  final messenger = ScaffoldMessenger.of(context);
  void say(String m) => messenger.showToast(SnackBar(content: Text(m)));
  try {
    final u = await checkForUpdate();
    if (u == null) {
      if (manual) say(tx('Alero está al día.'));
    } else if (context.mounted) {
      messenger.showToast(
        SnackBar(
          content: Text(tr('Alero {} disponible', [u.version])),
          persist: true,
          showCloseIcon: true, // "Más tarde"
          action: SnackBarAction(
            label: tx('Actualizar ahora'),
            onPressed: () => _update(context, u),
          ),
        ),
      );
    }
  } catch (e) {
    if (manual) say(tr('No se pudo buscar actualizaciones: {}', [_why(e)]));
  } finally {
    _checking = false;
  }
}

Future<void> _update(BuildContext context, UpdateInfo u) async {
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context, rootNavigator: true);
  void say(String m) => messenger.showToast(SnackBar(content: Text(m)));
  final kind = updateKind();
  final asset = assetFor(u, kind);
  if (asset == null) return Native.openUrl(u.page);
  if (kind == UpdateKind.android && !await Native.installPermission()) {
    await Native.requestInstallPermission();
    return say(
      tx('Permite instalar apps desde Alero y vuelve a pulsar Actualizar.'),
    );
  }
  final progress = ValueNotifier<double?>(0);
  var cancel = false, open = true;
  void close() {
    if (open) nav.pop();
    open = false;
  }

  if (!context.mounted) return;
  showAleroDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Descargando Alero {}', [u.version])),
      content: SizedBox(
        width: 320,
        child: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: v),
              const SizedBox(height: Gap.s),
              Text(v == null ? '' : '${(v * 100).round()} %'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => cancel = true,
          child: const Text('Cancelar'),
        ),
      ],
    ),
  ).whenComplete(() => open = false);
  try {
    final file = await updateFile(asset, kind);
    await downloadVerified(
      asset,
      file,
      onProgress: (p) => progress.value = p,
      cancelled: () => cancel,
    );
    close();
    await installUpdate(kind, file);
    if (kind == UpdateKind.appImage) {
      messenger.showToast(
        SnackBar(
          content: Text(tr('Alero {} instalado.', [u.version])),
          persist: true,
          action: SnackBarAction(
            label: tx('Reiniciar'),
            onPressed: restartAppImage,
          ),
        ),
      );
    }
  } catch (e) {
    close();
    if (!isCancelled(e)) say(tr('No se pudo actualizar: {}', [_why(e)]));
  }
}
