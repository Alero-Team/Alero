# Alero

[![Checks](https://github.com/Alero-Team/Alero/actions/workflows/ci.yml/badge.svg)](https://github.com/Alero-Team/Alero/actions/workflows/ci.yml)
[![Packages](https://github.com/Alero-Team/Alero/actions/workflows/packages.yml/badge.svg)](https://github.com/Alero-Team/Alero/actions/workflows/packages.yml)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

Connect Android and Windows directly over your local network or a USB cable. Transfer files, browse your phone, share the clipboard, mirror notifications and control either device from the other, without a cloud account.

**Beta software · Beta 1.2.1 (1.2.1).** [Download Android and Windows](https://github.com/Alero-Team/Alero/releases) · [Changelog](CHANGELOG.md)

## Features

| From the computer | From the phone |
| --- | --- |
| Send files and folders, with resumable transfers | Send files and share from any app |
| Browse, rename and delete the phone's files | Browse the folders the computer shares |
| Notifications with replies, SMS and calls | Touchpad, keyboard and media keys for the computer |
| Phone screen, camera, webcam and screen recording (scrcpy) | The computer's screen, live, with its pointer |
| Quick controls: Do Not Disturb, torch, volume, find my phone | The phone as a second Windows monitor |
| Shared clipboard | Shared clipboard |

Devices pair once with a code or a QR and then talk over mutually authenticated TLS. Nothing passes through a server.

## Use

1. Install the Android ARM64 APK and the Windows x64 installer from the same release. The installer program itself is 32-bit (Inno Setup); it installs the 64-bit app. Windows 11 on ARM runs it through x64 emulation; native ARM64 and 32-bit x86 builds are not available.
2. Open Alero on both devices, use the same Wi-Fi network and pair them in **Dispositivos**. Alternatively, scan the computer's QR code.
3. Allow remote control on Windows and grant only the phone permissions needed for the features you use.

The interface is in Spanish.

### Controlling the computer from the phone

The touchpad moves with one finger and scrolls with two. Tap twice and keep the second touch down to drag or select. The left and right buttons stay selected until tapped again. The keyboard button opens text input and shortcuts.

### Using the phone from the computer

**Acceso remoto** opens the phone's screen in a window with [scrcpy](https://github.com/Genymobile/scrcpy) over USB debugging or wireless debugging, which the phone's owner authorises on the phone. The same page opens the phone's camera in a window, turns it into a webcam through OBS Studio, and records the screen to a video file.

### Files and privacy

The file browser's Music section excludes audio lasting 5 seconds or less, ringtones, notification sounds and alarms. **All folders** requires Android's special shared-storage permission. Private app data remains inaccessible. Click a completed transfer to open it with the system's associated application.

Android's optional **Security** setting unlocks the app with the system fingerprint or device PIN. Alero never stores the PIN or biometric data.

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

The **Checks** workflow runs static analysis and the tests on every push and pull request. The **Packages** workflow runs on `main`, builds both installers with the Android signing identity kept in encrypted repository secrets, and publishes a release when the version in `app/pubspec.yaml` has a CHANGELOG section and no release yet.

## Signing and limitations

The Android builds keep one signing identity so each release updates the previous one. It is not a production certificate. Google Play Protect may block APKs downloaded from GitHub because the app declares sensitive capabilities (notification access, SMS), even when the APK is signed correctly; see [Play Protect's developer guidance](https://developers.google.com/android/play-protect/warning-dev-guidance). The Windows installer has no commercial Authenticode signature.

Linux is not packaged. Using the phone from the computer requires Windows.

## Source layout

- `core/`: Rust pairing, TLS and resumable transfers.
- `daemon/`: Windows tray service and native remote control.
- `app/`: Flutter UI, Kotlin Android integration and Windows runner.
- `tools/`, `packaging/`: build scripts, installer and notices.

## Security

Please report vulnerabilities privately: see [SECURITY.md](SECURITY.md).

## License

GNU GPL-3.0-or-later. See [LICENSE](LICENSE). Third-party components retain their own licenses.
