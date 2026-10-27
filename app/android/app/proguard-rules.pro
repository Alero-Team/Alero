# JNI: the Rust library looks these methods up by name (app/rust/src/jni_api.rs).
-keepclasseswithmembernames class dev.alero.app.Bridge { native <methods>; }
-keep class dev.alero.app.Bridge { *; }
