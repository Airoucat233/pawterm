import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun signingValue(propertyName: String, envName: String): String? =
    System.getenv(envName) ?: keystoreProperties.getProperty(propertyName)

val releaseStoreFile = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")
val releaseStorePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }
val pawtermAbiFilters = providers.gradleProperty("pawtermAbiFilter")
    .orNull
    ?.split(",")
    ?.map { it.trim() }
    ?.filter { it.isNotEmpty() }
    ?: emptyList()

fun resolveStoreFile(path: String): File =
    if (File(path).isAbsolute) file(path) else rootProject.file(path)

android {
    namespace = "com.airoucat.pawterm"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.airoucat.pawterm"
        base.archivesName = "pawterm"
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (pawtermAbiFilters.isNotEmpty()) {
            ndk {
                abiFilters += pawtermAbiFilters
            }
        }
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = resolveStoreFile(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    flavorDimensions += "channel"
    productFlavors {
        create("prod") {
            dimension = "channel"
            applicationId = "com.airoucat.pawterm"
            resValue("string", "app_name", "PawTerm")
            signingConfig = signingConfigs.getByName("release")
        }
        create("dev") {
            dimension = "channel"
            applicationId = "com.airoucat.pawterm.dev"
            resValue("string", "app_name", "PawTerm Dev")
            versionNameSuffix = "-dev"
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    buildTypes {
        release {
            // Signing is selected per flavor: prod uses release keys, dev uses debug keys.
        }
    }
}

gradle.taskGraph.whenReady {
    val buildsProdRelease = allTasks.any { task ->
        task.name.contains("ProdRelease", ignoreCase = false)
    }
    if (buildsProdRelease && !hasReleaseSigning) {
        throw GradleException(
            "prod release builds require Android release signing. " +
                "Set app/android/key.properties or ANDROID_KEYSTORE_PATH, " +
                "ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD."
        )
    }
}

flutter {
    source = "../.."
}
