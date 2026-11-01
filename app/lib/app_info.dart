import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const aleroVersion = '0.1.5';

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
      'Alero · componentes nativos',
    ], await rootBundle.loadString('assets/NATIVE-LICENSES.txt'));
  });
}
