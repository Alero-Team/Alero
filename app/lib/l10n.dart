import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/material.dart' as m show Text;

import 'l10n_en.dart';

/// Alero's languages. The source strings are Spanish and double as the lookup keys, so a string with no English
/// entry simply stays in Spanish instead of breaking. English lives in `l10n_en.dart`.
///
/// The choice is stored by `Hub` as `'system' | 'es' | 'en'`; `system` follows the device and falls back to English
/// for every language other than Spanish.
class L10n extends ChangeNotifier {
  L10n._();
  static final instance = L10n._();

  static const languages = ['system', 'es', 'en'];

  // Spanish until the settings are read, which is also what the widget tests expect.
  String _pref = 'es';

  /// 'system' | 'es' | 'en', as the user picked it.
  String get pref => _pref;

  /// The language in use right now: 'es' or 'en'.
  String get lang => switch (_pref) {
    'es' => 'es',
    'en' => 'en',
    _ =>
      PlatformDispatcher.instance.locale.languageCode == 'es' ? 'es' : 'en',
  };

  bool get en => lang == 'en';
  Locale get locale => Locale(lang);

  void set(String pref) {
    final next = languages.contains(pref) ? pref : 'system';
    if (next == _pref) return;
    _pref = next;
    _memo.clear();
    notifyListeners();
  }

  // Looked-up strings by source text; cleared when the language changes.
  final _memo = <String, String>{};

  String _lookup(String es) =>
      _memo[es] ??= en ? (kEnglish[es] ?? es) : es;
}

/// Translates a fixed Spanish string, or returns it as is in Spanish (and when it has no translation).
String tx(String es) => L10n.instance._lookup(es);

/// Translates a Spanish template and fills its `{}` slots in order (`{0}`, `{1}`… in the English text when its word
/// order differs). Text arguments that are themselves translatable ("archivos", "vídeos") are translated too.
String tr(String es, [List<Object?> args = const []]) {
  final text = L10n.instance._lookup(es);
  if (args.isEmpty) return text;
  var next = 0;
  return text.replaceAllMapped(_slot, (m) {
    final i = m[1]!.isEmpty ? next++ : int.parse(m[1]!);
    if (i >= args.length) return '';
    final a = args[i];
    return a is String ? tx(a) : '$a';
  });
}

final _slot = RegExp(r'\{(\d*)\}');

/// Flutter's `Text` that translates its (Spanish) string when the app is in English. Files import this one and
/// hide Flutter's, like `Icon`, so every label in the app follows the language without each call site asking, and
/// `const Text('…')` keeps working: the lookup happens in `build`, which re-runs when the locale changes.
class Text extends StatelessWidget {
  const Text(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });

  final String data;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) {
    // Depending on the locale is what rebuilds a const Text when the language changes.
    Localizations.localeOf(context);
    return m.Text(
      tx(data),
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semanticsLabel == null ? null : tx(semanticsLabel!),
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}
