plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val youtubedlAndroidVersion = "0.18.1"

android {
    namespace = "com.linkdrop.linkdrop_downloader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.linkdrop.linkdrop_downloader"
        // youtubedl-android requires minSdk >= 24
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // Required by youtubedl-android so bundled Python/FFmpeg/Aria2c binaries are extracted
            useLegacyPackaging = true
            // Prevent llvm-strip warnings on zip archives packaged as .zip.so
            keepDebugSymbols += "**/*.zip.so"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            // Disable R8 shrinking/obfuscation so reflection-heavy libraries
            // (youtubedl-android, Apache Commons Compress, Jackson, JNI shared_preferences)
            // never get stripped and crash on launch.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("io.github.junkfood02.youtubedl-android:library:$youtubedlAndroidVersion")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:$youtubedlAndroidVersion")
    implementation("io.github.junkfood02.youtubedl-android:aria2c:$youtubedlAndroidVersion")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.1")
    implementation("androidx.core:core-ktx:1.15.0")
}

flutter {
    source = "../.."
}
