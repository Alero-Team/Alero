# Builds the Rust core for Android and regenerates the Kotlin bindings. Run from the repo root (use an ASCII path
# such as a junction: AGP refuses project paths with non-ASCII characters on Windows).
$ErrorActionPreference = "Stop"
$env:PATH += ";$env:USERPROFILE\.cargo\bin"
$env:CARGO_HTTP_MULTIPLEXING = "false"   # needed on the dev PC, harmless elsewhere
if (-not $env:ANDROID_NDK_HOME) { $env:ANDROID_NDK_HOME = "$env:LOCALAPPDATA\Android\Sdk\ndk\29.0.14206865" }
cargo ndk -t arm64-v8a -P 26 -o android/app/src/main/jniLibs build -p pb-ffi --release
cargo run -q -p pb-ffi --features bindgen --bin uniffi-bindgen -- generate `
  --library target/aarch64-linux-android/release/libpb_ffi.so --language kotlin `
  --out-dir android/app/src/main/java --no-format
