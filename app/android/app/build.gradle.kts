plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.alero.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "29.0.14206865" // the NDK installed for the Rust core

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.alero.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // The Rust core is built for arm64 only for now.
        ndk { abiFilters += "arm64-v8a" }
    }

    signingConfigs {
        val signingFile = System.getenv("ALERO_ANDROID_KEYSTORE")
        if (!signingFile.isNullOrBlank()) {
            create("aleroRelease") {
                storeFile = file(signingFile)
                storePassword = System.getenv("ALERO_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ALERO_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ALERO_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Alpha builds keep the installed identity; CI supplies the same identity through encrypted secrets.
            signingConfig = signingConfigs.findByName("aleroRelease") ?: signingConfigs.getByName("debug")
            // Smaller and faster to load: R8 shrinks code, unused resources go. Rules keep the JNI entry points.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    // QR pairing scanner: Apache-2.0, plain ZXing, no Google Play services.
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
}
