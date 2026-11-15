import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'l10n.dart' show tx;

const aleroVersion = '1.4.0-beta';

/// The release name people see.
const aleroRelease = 'Beta 1.4';

/// Flutter supplies Dart package notices; native components are bundled alongside them.
void registerAleroLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Alero',
    ], await rootBundle.loadString('assets/ALERO-LICENSE.txt'));
    yield LicenseEntryWithLineBreaks([
      'Google Sans Flex',
    ], await rootBundle.loadString('assets/FONT-LICENSE.txt'));
    yield LicenseEntryWithLineBreaks([
      tx('Alero · componentes nativos'),
    ], await rootBundle.loadString('assets/NATIVE-LICENSES.txt'));
  });
}
