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
        (findProperty("decaidAppIdSuffix") as String?)?.let { applicationIdSuffix = it }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = 35
        // Use git commit count as versionCode so debug and release builds always
        // share the same monotonically increasing version, preventing downgrade uninstalls.
        versionCode = providers.exec {
            commandLine("git", "rev-list", "--count", "origin/main")
        }.standardOutput.asText.get().trim().toInt()
        versionName = flutter.versionName
    }

    signingConfigs {
            create("release") {
                storeFile = file("debug.keystore")
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: "android"
                keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "androiddebugkey"
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: "android"
            }
            getByName("debug") {
                storeFile = file("debug.keystore")
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
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

val releaseSigningEnv = listOf(
    "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
)

gradle.taskGraph.whenReady {
    val missing = releaseSigningEnv.filter { System.getenv(it).isNullOrEmpty() }
    val signsRelease = allTasks.any {
        it.project == project && it.name.startsWith("package") && it.name.endsWith("Release")
    }
    if (System.getenv("CI") == "true" && signsRelease && missing.isNotEmpty()) {
        throw GradleException(
            "CI release builds must not fall back to the debug signing " +
                "defaults; set ${missing.joinToString()}",
        )
    }
}





if (findProperty("decaidAppIdSuffix") != null) {
    tasks.matching { it.name.endsWith("GoogleServices") || it.name.contains("Crashlytics") }
        .configureEach { enabled = false }
}
