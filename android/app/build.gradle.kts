plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.firebase-perf")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    // id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Reads the committed Android versionCode counter. Kept in version control so a
// full clone, a `git clone --depth 1` CI checkout and an exported source tree all
// agree on one number. Bump procedure and CI guard: doc/RELEASE.md, section
// "Android versionCode".
val committedVersionCode: Int = rootProject.file("version.properties").let { counterFile ->
    require(counterFile.isFile) {
        "Missing ${counterFile.path}. It must contain a single 'versionCode=<integer>' entry."
    }
    // Plain parsing: in a project script `java` resolves to the Java plugin
    // extension accessor, so java.util.Properties needs an explicit import.
    val raw = counterFile.readLines()
        .asSequence()
        .map { line -> line.trim() }
        .firstOrNull { line -> line.startsWith("versionCode=") }
        ?.substringAfter('=')
        ?.trim()
    require(!raw.isNullOrEmpty()) { "${counterFile.path} is missing the 'versionCode' property." }
    val code = raw.toIntOrNull()
    if (code == null || code <= 0) {
        throw GradleException("${counterFile.path}: versionCode must be a positive integer, got '$raw'.")
    }
    code
}

android {
    namespace = "net.tadel.reaprime"
    compileSdk = 36
    // ndkVersion = flutter.ndkVersion
		ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    defaultConfig {
        applicationId = "net.tadel.reaprime"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = 35
        // versionCode is a committed counter (android/version.properties), not a
        // value derived from git history: the same commit must yield the same
        // versionCode in every clone. `git rev-list --count origin/main` failed
        // in shallow clones and in checkouts without an `origin/main` ref.
        versionCode = committedVersionCode
        versionName = flutter.versionName
    }

    // The release config still points at android/app/debug.keystore (unchanged
    // behaviour): CI writes that file from secrets.ANDROID_KEYSTORE_B64 before
    // building, so release signing keys are unaffected by this change.
    //
    // The debug config is deliberately NOT declared. AGP's built-in "debug"
    // signing config signs with the well-known ~/.android/debug.keystore, which
    // AGP creates on first use. Declaring `storeFile = file("debug.keystore")`
    // pointed at a path that android/.gitignore excludes (**/*.keystore), so a
    // fresh clone could not build a debug APK at all.
    signingConfigs {
            create("release") {
                storeFile = file("debug.keystore")
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: "android"
                keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "androiddebugkey"
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: "android"
            }
        }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
        }
        getByName("debug") {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}




