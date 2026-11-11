# Alero — Android and Windows, connected

<div align="center">

  <img src="branding/alero_icon.svg" alt="Official Alero logo" width="180" />

  <h2>One connection. No friction.</h2>

  <p>Alero connects your Android phone and your Windows PC directly over your local network or a USB cable, built with <strong>Flutter</strong>, <strong>Rust</strong> and <strong>Kotlin</strong>.</p>

  <p>Transfer files, browse your phone, share the clipboard, mirror notifications and control either device from the other, with no account and no cloud.</p>

  <p>
    <a href="https://github.com/Alero-Team/Alero/releases">
      <img src="https://img.shields.io/badge/Download-GitHub%20Releases-238636?style=for-the-badge&logo=github&logoColor=white" alt="Download Alero from GitHub Releases" />
    </a>
    <a href="README.md"><img src="https://img.shields.io/badge/Idioma-Espa%C3%B1ol-6B7280?style=for-the-badge" alt="Leer en español" /></a>
    <a href="README.en.md"><img src="https://img.shields.io/badge/Language-English-2563EB?style=for-the-badge" alt="Read in English" /></a>
  </p>

  <p>
    <img src="https://img.shields.io/badge/Android-8.0%2B-3DDC84?logo=android&logoColor=black" alt="Android 8.0 or later" />
    <img src="https://img.shields.io/badge/Windows-x64-0078D4?logo=windows&logoColor=white" alt="Windows x64" />
    <img src="https://img.shields.io/badge/Flutter-Rust-02569B?logo=flutter&logoColor=white" alt="Flutter and Rust" />
    <img src="https://img.shields.io/badge/Status-Beta-F59E0B" alt="Beta version" />
    <img src="https://img.shields.io/badge/License-GPL--3.0--or--later-blue" alt="GPL-3.0-or-later license" />
  </p>

</div>

## Overview

**Alero** lets you use your phone and your computer as a single device. Devices pair once with a code or a QR and then talk over mutually authenticated TLS. Nothing passes through a server and you never need an account.

## Developers

A project by **Alero Team**, developed by:

- **[@edwindidier17](https://github.com/edwindidier17)**
- **[@k0op4](https://github.com/k0op4)**

## Main features

| From the computer | From the phone |
| --- | --- |
| Send files and folders, with resumable transfers | Send files and share from any app |
| Browse, rename and delete the phone's files | Browse the folders the computer shares |
| Notifications with replies, SMS and calls | Touchpad, keyboard and media keys for the computer |
| Phone screen, camera, webcam and screen recording (scrcpy) | The computer's screen, live, with its pointer |
| Quick controls: Do Not Disturb, torch, volume, find my phone | The phone as a second Windows monitor |
| Shared clipboard | Shared clipboard |

## How it works

1. Install the Android APK and the Windows installer from the same release.
2. Open Alero on both devices, join the same Wi-Fi network and pair them in **Dispositivos** (Devices), or scan the computer's QR code.
3. Allow remote control on Windows and grant the phone only the permissions needed for the features you use.

The app interface is in Spanish.

### Controlling the computer from the phone

The touchpad moves the pointer with one finger and scrolls with two. Tap twice and keep the second touch down to drag or select. The left and right buttons stay selected until tapped again. The keyboard button opens text input and shortcuts.

### Using the phone from the computer

**Acceso remoto** (Remote access) opens the phone's screen in a window with [scrcpy](https://github.com/Genymobile/scrcpy) over USB debugging or wireless debugging, which the phone's owner authorises in Android. The same page opens the phone's camera in a window, turns it into a webcam through OBS Studio, and records the screen to a video file.

### Files and privacy

The file browser's Music section excludes audio lasting 5 seconds or less, ringtones, notification sounds and alarms. **All folders** requires Android's special shared-storage permission. Other apps' private data remains inaccessible. Tap a completed transfer to open it with the system's associated app.

Android's optional **Security** setting unlocks the app with the system fingerprint or device PIN. Alero never stores the PIN or biometric data.

## Downloads

Android and Windows packages are published on **[GitHub Releases](https://github.com/Alero-Team/Alero/releases)** together with the release notes of each version. See also the [changelog](CHANGELOG.md).

Alero is still in Beta. Always download the APK and the installer from the same version.

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

## App information

| | |
| --- | --- |
| **Name** | Alero |
| **Platforms** | Android 8.0 or later and Windows (x64) |
| **Package** | `dev.alero.app` |
| **Technologies** | Flutter, Rust and Kotlin |
| **Connection** | Local network or USB, mutually authenticated TLS, no servers |
| **License** | GNU GPL-3.0-or-later. See [LICENSE](LICENSE); third-party components retain their own licenses |

---

<div align="center">
  <sub>Designed for Android and Windows · Alero Team</sub>
</div>
