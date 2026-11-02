# Alero

Connect Android and Windows directly over your local network or a USB cable. Transfer files, browse your phone, share the clipboard, mirror notifications and control your computer without a cloud account.

**Alpha software · 0.1.9.** [Download Android and Windows](https://github.com/Alero-Team/Alero/releases).

## Use

1. Install the Android ARM64 APK and the Windows x64 installer from the same release.
2. Open Alero on both devices, use the same Wi-Fi network and pair them in **Devices**. Alternatively, scan the computer's QR code.
3. Allow remote control on Windows and grant only the phone permissions needed for the features you use.

The touchpad moves with one finger and scrolls with two. Tap twice and keep the second touch down to drag or select. The left and right buttons stay selected until tapped again; their label changes to release the button. The keyboard button opens text input and shortcuts.

The file browser's Music section excludes audio lasting 5 seconds or less, ringtones, notification sounds and alarms. **All folders** requires Android's special shared-storage permission. Private app data remains inaccessible. Click a completed transfer to open it with the system's associated application. Android cannot run Windows executables.

Android's optional **Security** setting unlocks the app with the system fingerprint or device PIN. It locks the interface when returning from the background; previously paired connections can continue working in the background. Alero never stores the PIN or biometric data.

Device previews use the reported screen geometry, hardware identity and built-in system wallpaper. Verified hardware profiles: Google Pixel 9a and Lenovo V15 G4 IAH. Other models use the geometry the device reports. Windows uses its installed stock Windows wallpaper; OEM-specific artwork is not bundled.

## Desktop tools (0.1.9)

On Windows, open **Controlar teléfono → Herramientas de escritorio** with an ADB-authorized device. The new Dextop-inspired toolkit reads the actual installed user apps, launches selected apps on an available Android display, saves and restores app sets, supports JSON import/export, and reads real battery/thermal/memory diagnostics on demand. Saved workspaces are local to Alero on Windows; no extra Android permissions or root are requested.

Desktop virtual-screen presets now include 720p, 900p, 1080p and 1440p plus an experimental flexible resize option. The underlying phone input, USB and Wi-Fi controls remain provided by scrcpy.

The multi-window layout selection can **attempt real two-, three- or four-window placement** via ADB's task resize shell command only when Android exposes exact matching task IDs for the selected secondary display. Many OEM builds reject or ignore this command, so a layout is not guaranteed. Cross-display pointer routing or mirroring multiple real Android displays simultaneously depends on Android firmware and additional privileged OEM capabilities. Alero only requests supported Android activity launches and reports failures; it does not silently install or run Dextop's privileged services. Workspaces can be restored manually after reconnecting, not automatically after a phone disconnect.

Design references: [Dextop](https://github.com/NarYuki/Dextop) (GPL-3.0) app catalog, workspace layouts, capability probes and diagnostics. Alero's Flutter models and ADB integration are independently implemented; no Dextop native code or binaries were copied.

## Build

Requirements: Flutter **3.47.8** (Dart 3.13.7), Rust stable, Java 17+, Android SDK with NDK **29.0.14206865**, and Visual Studio C++ desktop tools for Windows. Windows packaging also needs Inno Setup 6.

```powershell
cargo fetch --locked
cargo test --locked --workspace
cd app
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
cd ..
./tools/build-android.ps1 -FlutterRoot C:/src/flutter
./tools/build-windows.ps1 -FlutterRoot C:/src/flutter
```

The build scripts create packages and SHA-256 files in `dist/`. scrcpy is downloaded from its pinned upstream release and checked against its SHA-256 hash. Third-party notices and source licenses are bundled with both apps.

The GitHub **Checks** workflow runs static analysis and regression tests. The **Packages** workflow runs on main and builds both installers, keeps the Android signing identity in encrypted repository secrets, and optionally publishes a preliminary release. It refuses publication without the configured signing key.

## Signing and limitations

This alpha retains the existing Android signing identity so it can update test installations. It is not a production signing certificate. The Android build retains notification mirroring and playback control through a notification-listener service. Google Play Protect may automatically block APKs downloaded from GitHub because they declare this sensitive service, even if the APK is signed correctly. For testing with Play Protect enabled, consider [Google Play internal testing](https://google.play/business/internal-testing/) or [appealing a Play Protect classification](https://developers.google.com/android/play-protect/warning-dev-guidance?hl=es-419). The Windows installer has no commercial Authenticode signature. Android installation and opening apps remain subject to the operating system's normal prompts.

Linux is not packaged in this release. Full phone-to-PC control requires Windows. Device authentication and storage permission prompts must be completed on the phone by its owner.

## Source layout

- `core/`: Rust pairing, TLS and resumable transfers.
- `daemon/`: Windows tray service and native remote control.
- `app/`: Flutter UI, Kotlin Android integration and Windows runner.
- `tools/`, `packaging/`: reproducible build scripts, installer and notices.

## License

GNU GPL-3.0-or-later. See [LICENSE](LICENSE). Third-party components retain their own licenses.
