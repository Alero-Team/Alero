import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../scrcpy.dart';
import '../src/rust/api/engine.dart' as pb;
import 'theme.dart';

/// "Ver pantalla" is an action: it opens the phone's screen in its own window (scrcpy). If the phone is not
/// ready yet, a dialog walks through the one-time setup.
Future<void> openScreen(BuildContext context, pb.Peer phone) =>
    showDialog<void>(context: context, builder: (_) => _ScreenDialog(phone));

String _ipOf(pb.Peer p) {
  final i = p.addr.lastIndexOf(':');
  return i > 0 ? p.addr.substring(0, i) : '';
}

class _ScreenDialog extends StatefulWidget {
  const _ScreenDialog(this.phone);
  final pb.Peer phone;

  @override
  State<_ScreenDialog> createState() => _ScreenDialogState();
}

class _ScreenDialogState extends State<_ScreenDialog> {
  final _port = TextEditingController(), _code = TextEditingController();
  String _status = '';
  bool _busy = false, _screenOff = false, _audio = true, _ready = false;

  @override
  void initState() {
    super.initState();
    if (Scrcpy.available) _run('Buscando el teléfono…', _check);
  }

  @override
  void dispose() {
    _port.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(String doing, Future<String> Function() f) async {
    setState(() {
      _busy = true;
      _status = doing;
    });
    String s;
    try {
      s = await f();
    } catch (e) {
      s = 'No se pudo: $e';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _status = s;
      });
    }
  }

  Future<String> _check() async {
    _ready = await Scrcpy.ready(_ipOf(widget.phone)) != null;
    return _ready
        ? 'Listo para abrir la pantalla.'
        : 'Prepara el teléfono una vez con los pasos de abajo.';
  }

  Future<String> _pair() async {
    final out = await Scrcpy.pair(
      _ipOf(widget.phone),
      _port.text.trim(),
      _code.text.trim(),
    );
    if (!out.toLowerCase().contains('successfully')) {
      return 'No se vinculó. El puerto y el código cambian cada vez que abres la pantalla de vinculación.';
    }
    _code.clear();
    _port.clear();
    return _check();
  }

  Future<String> _start() async {
    final serial = await Scrcpy.ready(_ipOf(widget.phone));
    if (serial == null) {
      return 'No se encuentra el teléfono. Comprueba la depuración inalámbrica.';
    }
    final p = await Scrcpy.start(
      serial,
      title: widget.phone.name,
      screenOff: _screenOff,
      audio: _audio,
    );
    p.stderr.drain<void>();
    p.stdout.drain<void>();
    if (mounted) Navigator.pop(context);
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    if (Platform.isAndroid || !Scrcpy.available) {
      return AlertDialog(
        icon: const Icon(Symbols.cast_rounded),
        title: const Text('Ver pantalla'),
        content: const Text(
          'Esta instalación no incluye el componente de pantalla (scrcpy). Reinstala la app o copia la carpeta «scrcpy» junto al programa.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
        ],
      );
    }
    return AlertDialog(
      icon: const Icon(Symbols.cast_rounded),
      title: Text('Ver ${widget.phone.name}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Se abre en otra ventana con imagen y sonido. Usa el ratón y el teclado como si tocaras el teléfono.',
                style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant),
              ),
              const SizedBox(height: Gap.s),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Apagar la pantalla del teléfono mientras tanto',
                ),
                value: _screenOff,
                onChanged: (v) => setState(() => _screenOff = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sonido del teléfono en el ordenador'),
                value: _audio,
                onChanged: (v) => setState(() => _audio = v),
              ),
              if (_status.isNotEmpty)
                Semantics(
                  liveRegion: true,
                  child: Row(
                    children: [
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.only(right: Gap.s),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      Expanded(child: Text(_status, style: t.bodyMedium)),
                    ],
                  ),
                ),
              const SizedBox(height: Gap.s),
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  initiallyExpanded: false,
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    'Preparar el teléfono (una sola vez)',
                    style: t.titleSmall,
                  ),
                  childrenPadding: const EdgeInsets.only(bottom: Gap.s),
                  expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, step) in const [
                      'Ajustes › Información del teléfono › toca 7 veces «Número de compilación».',
                      'Ajustes › Sistema › Opciones de desarrollador › activa «Depuración inalámbrica».',
                      'Toca «Vincular dispositivo con código de vinculación» y escribe aquí el puerto y el código.',
                    ].indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Gap.s),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(
                              radius: 11,
                              backgroundColor: s.secondaryContainer,
                              child: Text(
                                '${i + 1}',
                                style: t.labelSmall?.copyWith(
                                  color: s.onSecondaryContainer,
                                ),
                              ),
                            ),
                            const SizedBox(width: Gap.m),
                            Expanded(child: Text(step, style: t.bodyMedium)),
                          ],
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _port,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Puerto',
                            ),
                          ),
                        ),
                        const SizedBox(width: Gap.s),
                        Expanded(
                          child: TextField(
                            controller: _code,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Código',
                            ),
                          ),
                        ),
                        const SizedBox(width: Gap.s),
                        FilledButton.tonal(
                          onPressed: _busy
                              ? null
                              : () => _run('Vinculando…', _pair),
                          child: const Text('Vincular'),
                        ),
                      ],
                    ),
                    const SizedBox(height: Gap.s),
                    Text(
                      'La depuración inalámbrica da control total del teléfono a los equipos vinculados. Desactívala cuando no la uses.',
                      style: t.bodySmall?.copyWith(color: s.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          onPressed: _busy || !_ready ? null : () => _run('Abriendo…', _start),
          icon: const Icon(Symbols.cast_rounded, size: 18),
          label: const Text('Ver pantalla'),
        ),
      ],
    );
  }
}
