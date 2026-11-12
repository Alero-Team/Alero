#!/usr/bin/env bash
# Builds Alero for Linux x86_64 (the equivalent of tools/build-windows.ps1): the Rust tray daemon, the Flutter
# bundle with the pinned scrcpy + adb inside, and the packages: .deb, .rpm (when `rpmbuild` is on PATH), AppImage
# (when `appimagetool` is on PATH) and a portable .tar.gz. Output and SHA-256 files go to dist/.
# Build on the oldest distribution you want to support: the binaries need at least that glibc (CI uses Ubuntu 22.04,
# glibc 2.35, which runs on Debian 12 and later).
#
# Build dependencies (Debian/Ubuntu):
#   sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libayatana-appindicator3-dev libdbus-1-dev \
#     libxdo-dev liblzma-dev dpkg-dev curl rpm
# Flutter 3.47.8 and Rust stable must be on PATH. Pass the Flutter checkout with FLUTTER=/path/to/flutter/bin/flutter.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
flutter=${FLUTTER:-flutter}
out=${OUT:-$root/dist}
version=$(sed -n 's/^version: \([^+]*\).*/\1/p' app/pubspec.yaml)
[ -n "$version" ] || { echo "No version in app/pubspec.yaml" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "Only x86_64 is supported" >&2; exit 1; }

# scrcpy + adb travel inside every package (like Windows), so the user installs nothing else.
bash tools/fetch-scrcpy.sh
scrcpy_dir=$root/third_party/scrcpy-linux

# The Flutter build installs the daemon into the bundle, so it comes first.
cargo build --release --locked -p pb-daemon
(
  cd app
  "$flutter" pub get --enforce-lockfile
  "$flutter" build linux --release --no-pub
)
bundle=$root/app/build/linux/x64/release/bundle
for f in alero alero_daemon lib/libpb_bridge.so lib/libflutter_linux_gtk.so data/icudtl.dat data/flutter_assets; do
  [ -e "$bundle/$f" ] || { echo "Missing in the bundle: $f" >&2; exit 1; }
done
# Libraries the binaries need at run time: these are the packages the .deb and .rpm depend on.
ldd "$bundle/alero_daemon" | awk '{print "  daemon needs: " $1}'
ldd "$bundle/alero" | grep -i 'not found' && { echo "Unresolved libraries in alero" >&2; exit 1; } || true

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

# --- Install tree shared by every format (paths as on an installed system) -----------------------------------
stage=$work/root
install -d "$stage/usr/lib/alero" "$stage/usr/bin" "$stage/usr/share/applications" \
  "$stage/usr/lib/udev/rules.d" "$stage/usr/lib/modules-load.d" \
  "$stage/usr/share/doc/alero"
cp -a "$bundle/." "$stage/usr/lib/alero/"
# The app looks for scrcpy/ next to its executable (app/lib/scrcpy.dart).
install -d "$stage/usr/lib/alero/scrcpy"
install -m 755 "$scrcpy_dir/scrcpy" "$scrcpy_dir/adb" "$stage/usr/lib/alero/scrcpy/"
install -m 644 "$scrcpy_dir/scrcpy-server" "$scrcpy_dir/scrcpy.png" "$scrcpy_dir/disconnected.png" "$stage/usr/lib/alero/scrcpy/"
ln -s ../lib/alero/alero "$stage/usr/bin/alero"
install -m 644 packaging/linux/dev.alero.app.desktop "$stage/usr/share/applications/"
# PNGs, not branding/alero_icon.svg (KDE draws that SVG blank); light tile so it shows on dark panels.
icon=packaging/linux/icons
for n in 48 72 96 144 192; do
  install -D -m 644 "$icon/$n.png" "$stage/usr/share/icons/hicolor/${n}x${n}/apps/dev.alero.app.png"
done
install -m 644 packaging/linux/70-alero-uinput.rules "$stage/usr/lib/udev/rules.d/"
install -m 644 packaging/linux/alero-uinput.conf "$stage/usr/lib/modules-load.d/alero.conf"
install -m 644 LICENSE "$stage/usr/share/doc/alero/copyright"
cp -a packaging/licenses "$stage/usr/share/doc/alero/licenses"
install -m 644 "$scrcpy_dir/LICENSE" "$stage/usr/share/doc/alero/licenses/scrcpy-LICENSE.txt"
cat > "$stage/usr/share/doc/alero/licenses/THIRD-PARTY.txt" <<'EOF'
Alero includes Flutter/Dart and Rust dependencies. Flutter notices are in data/flutter_assets/NOTICES.Z.
Bundled scrcpy: https://github.com/Genymobile/scrcpy (Apache-2.0), a static build with its adb and scrcpy-server.
ADB: https://android.googlesource.com/platform/packages/modules/adb/ (Apache-2.0).
FFmpeg: https://ffmpeg.org/legal.html (LGPL; linked into scrcpy).
SDL: https://libsdl.org/license.php (zlib).
libusb: https://libusb.info/ (LGPL-2.1).
EOF
find "$stage" -type d -exec chmod 755 {} +
for f in scrcpy adb; do [ -x "$stage/usr/lib/alero/scrcpy/$f" ] || { echo "Missing scrcpy/$f" >&2; exit 1; }; done

sums() { (cd "$out" && sha256sum "$(basename "$1")" > "$(basename "$1").sha256"); }

# --- .deb ---------------------------------------------------------------------------------------------------
pkg=$work/deb
install -d "$pkg"
cp -a "$stage/." "$pkg/"
install -d "$pkg/DEBIAN"
cat > "$pkg/DEBIAN/control" <<EOF
Package: alero
Version: $version
Section: net
Priority: optional
Architecture: amd64
Maintainer: Alero Team <noreply@github.com>
Installed-Size: $(du -sk "$stage" | cut -f1)
Depends: libc6 (>= 2.35), libgtk-3-0 | libgtk-3-0t64, libayatana-appindicator3-1, libdbus-1-3, libxdo3, xdg-utils, wl-clipboard | xclip
Recommends: xdotool, pulseaudio-utils, curl, libxtst6, libxrandr2, libgl1, spectacle | kde-spectacle | grim | gnome-screenshot
Homepage: https://github.com/Alero-Team/Alero
Description: Android and Linux over your local network or a USB cable
 Transfer files, browse the phone, share the clipboard, mirror notifications and
 control either device from the other, without a cloud account. Includes a tray
 service that keeps the connection while the window is closed. scrcpy and adb
 are bundled.
EOF
cat > "$pkg/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
# Best effort: the package works without any of these (the remote controls then say what is missing).
if [ "$1" = configure ]; then
  modprobe uinput 2>/dev/null || true
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger --subsystem-match=misc --action=add 2>/dev/null || true
  command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
exit 0
EOF
cat > "$pkg/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
udevadm control --reload-rules 2>/dev/null || true
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
exit 0
EOF
chmod 755 "$pkg/DEBIAN/postinst" "$pkg/DEBIAN/postrm"

deb=$out/Alero-$version-linux-amd64.deb
dpkg-deb --build --root-owner-group -Zxz "$pkg" "$deb"
dpkg-deb --info "$deb" | sed -n '1,12p'
sums "$deb"
echo "DEB=$deb"

# --- .rpm (Fedora, openSUSE) --------------------------------------------------------------------------------
if command -v rpmbuild >/dev/null; then
  rpmtop=$work/rpm
  mkdir -p "$rpmtop"
  rpmbuild -bb --quiet --define "_topdir $rpmtop" --define "ver $version" --define "stage $stage" \
    --define "_binary_payload w6.xzdio" --define "_buildhost alero" packaging/linux/alero.spec
  rpm=$out/Alero-$version-linux-x86_64.rpm
  cp "$rpmtop"/RPMS/x86_64/alero-"$version"-1.x86_64.rpm "$rpm"
  rpm -qp --requires "$rpm"
  sums "$rpm"
  echo "RPM=$rpm"
else
  echo "rpmbuild not found: skipping the .rpm"
fi

# --- Portable .tar.gz ---------------------------------------------------------------------------------------
# Unpack anywhere and run ./alero. extras/ has the desktop entry, icon and udev rule for a manual install.
tarname=Alero-$version-linux-x86_64
tardir=$work/$tarname
install -d "$tardir/extras"
cp -a "$stage/usr/lib/alero/." "$tardir/"
cp -a "$stage/usr/share/doc/alero/licenses" "$tardir/licenses"
install -m 644 LICENSE "$tardir/LICENSE"
install -m 644 packaging/linux/dev.alero.app.desktop packaging/linux/70-alero-uinput.rules packaging/linux/alero-uinput.conf \
  "$tardir/extras/"
install -m 644 "$icon/192.png" "$tardir/extras/dev.alero.app.png"
cat > "$tardir/INSTALL.txt" <<'EOF'
Alero portable (Linux x86_64)

Run ./alero from this folder. It needs GTK 3, libayatana-appindicator3, libdbus-1, libxdo and wl-clipboard or xclip
(scrcpy and adb are included).

To let the phone control the mouse and keyboard (once, as root), then log in again:
  sudo cp extras/70-alero-uinput.rules /etc/udev/rules.d/
  sudo cp extras/alero-uinput.conf /etc/modules-load.d/
  sudo modprobe uinput && sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=misc

Menu entry (edit Exec= in the .desktop to the full path of ./alero first):
  cp extras/dev.alero.app.desktop ~/.local/share/applications/
  install -D extras/dev.alero.app.png ~/.local/share/icons/hicolor/192x192/apps/dev.alero.app.png
EOF
tgz=$out/$tarname.tar.gz
tar -C "$work" --owner=0 --group=0 --numeric-owner -czf "$tgz" "$tarname"
sums "$tgz"
echo "TARBALL=$tgz"

# --- AppImage -----------------------------------------------------------------------------------------------
# Needs GTK 3, appindicator and libxdo from the system (scrcpy and adb are inside) and no udev rule: see README.
# The tray service keeps running after the window closes, and an AppImage's files vanish with its mount, so AppRun
# copies the bundle once to ~/.local/share/alero and runs it from there.
if command -v appimagetool >/dev/null; then
  app=$work/Alero.AppDir
  install -d "$app/usr/lib/alero"
  cp -a "$stage/usr/lib/alero/." "$app/usr/lib/alero/"
  echo "$version" > "$app/VERSION"
  install -m 644 packaging/linux/dev.alero.app.desktop "$app/dev.alero.app.desktop"
  install -m 644 "$icon/192.png" "$app/dev.alero.app.png"
  cat > "$app/AppRun" <<'EOF'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
base=${XDG_DATA_HOME:-$HOME/.local/share}/alero
dest=$base/app-$(cat "$here/VERSION")
if [ ! -x "$dest/alero" ]; then
  mkdir -p "$base" && tmp=$dest.tmp.$$ && mkdir "$tmp" && cp -a "$here/usr/lib/alero/." "$tmp/" && rm -rf "$dest" && mv "$tmp" "$dest" || exit 1
  for old in "$base"/app-*; do [ "$old" = "$dest" ] || rm -rf "$old"; done
fi
exec "$dest/alero" "$@"
EOF
  chmod 755 "$app/AppRun"
  image=$out/Alero-$version-linux-x86_64.AppImage
  ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 appimagetool --no-appstream "$app" "$image"
  sums "$image"
  echo "APPIMAGE=$image"
else
  echo "appimagetool not found: skipping the AppImage"
fi
