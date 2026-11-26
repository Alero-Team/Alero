# Copies the Flutter app and rewrites dart:io's Platform to a fake Android one, so the UI runs on the web.
# Usage: python3 tool/make_web_sim.py <app dir> <copy dir>; then in the copy: flutter build web -t lib/sim_main.dart --no-web-resources-cdn --pwa-strategy=none
import re, shutil, sys, pathlib
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
if dst.exists(): shutil.rmtree(dst)
shutil.copytree(src, dst, ignore=shutil.ignore_patterns('build', '.dart_tool', 'android', 'windows', 'linux', 'test', 'target'))
(dst/'lib/sim_platform.dart').write_text('''// Web simulation: pretends to be an Android phone.
class SimPlatform {
  static const isAndroid = true;
  static const isLinux = false;
  static const isWindows = false;
  static const isIOS = false;
  static const isMacOS = false;
  static const pathSeparator = '/';
  static const environment = <String, String>{};
  static const localHostname = 'pixel';
  static const resolvedExecutable = '/system/bin/alero';
  static const operatingSystem = 'android';
  static const numberOfProcessors = 8;
}
''')
for f in (dst/'lib').rglob('*.dart'):
    if f.name == 'sim_platform.dart': continue
    s = f.read_text()
    if not re.search(r'(?<![\w.])Platform\.', s): continue
    s = re.sub(r"import 'dart:io' show Platform;\n", '', s)
    s = re.sub(r"import 'dart:io';", "import 'dart:io' hide Platform;", s)
    s = re.sub(r'(?<![\w.])Platform\.', 'SimPlatform.', s)
    rel = '../' * (len(f.relative_to(dst/'lib').parts) - 1)
    s = f"import '{rel}sim_platform.dart';\n" + s
    f.write_text(s)
