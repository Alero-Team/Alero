# RPM for Fedora, openSUSE and derivatives. Built by tools/build-linux.sh from an already staged tree:
#   rpmbuild -bb --define "ver X" --define "stage /path" packaging/linux/alero.spec
Name:           alero
Version:        %{ver}
Release:        1
Summary:        Android and Linux over your local network or a USB cable
License:        GPL-3.0-only
URL:            https://github.com/Alero-Team/Alero
BuildArch:      x86_64

# The bundle ships its own libraries and static scrcpy/adb: no automatic dependency or provides, no stripping.
AutoReqProv:    no
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

# Sonames instead of package names: they resolve on Fedora (gtk3, libayatana-appindicator-gtk3, dbus-libs, libxdo)
# and on openSUSE (libgtk-3-0, libayatana-appindicator3-1, libdbus-1-3, libxdo3).
Requires:       libc.so.6(GLIBC_2.35)(64bit)
Requires:       libgtk-3.so.0()(64bit)
Requires:       libayatana-appindicator3.so.1()(64bit)
Requires:       libdbus-1.so.3()(64bit)
Requires:       libxdo.so.3()(64bit)
Requires:       xdg-utils
Requires:       (wl-clipboard or xclip)
Recommends:     xdotool
Recommends:     pulseaudio-utils
Recommends:     curl

%description
Transfer files, browse the phone, share the clipboard, mirror notifications and control either device from the
other, without a cloud account. Includes a tray service that keeps the connection while the window is closed.
scrcpy and adb are bundled.

%install
mkdir -p %{buildroot}
cp -a %{stage}/. %{buildroot}/

%post
modprobe uinput 2>/dev/null || :
udevadm control --reload-rules 2>/dev/null || :
udevadm trigger --subsystem-match=misc --action=add 2>/dev/null || :
update-desktop-database -q /usr/share/applications 2>/dev/null || :
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || :

%postun
udevadm control --reload-rules 2>/dev/null || :
update-desktop-database -q /usr/share/applications 2>/dev/null || :

%files
/usr/bin/alero
/usr/lib/alero
/usr/lib/udev/rules.d/70-alero-uinput.rules
/usr/lib/modules-load.d/alero.conf
/usr/share/applications/dev.alero.app.desktop
/usr/share/icons/hicolor/*/apps/dev.alero.app.png
/usr/share/doc/alero
