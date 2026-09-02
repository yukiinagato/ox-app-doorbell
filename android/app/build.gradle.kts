import java.security.MessageDigest

plugins {
  id("com.android.application")
  id("org.jetbrains.kotlin.android")
}

fun sourceIdentity(): String {
  val digest = MessageDigest.getInstance("SHA-256")
  val roots = listOf(
    project.file("src"),
  )
  for ((rootIndex, root) in roots.withIndex()) {
    root.walkTopDown().filter { it.isFile }.sortedBy { it.relativeTo(root).invariantSeparatorsPath }
      .forEach { file ->
        digest.update("$rootIndex:${file.relativeTo(root).invariantSeparatorsPath}\u0000"
          .toByteArray(Charsets.UTF_8))
        file.inputStream().use { input ->
          val buffer = ByteArray(64 * 1024)
          while (true) {
            val size = input.read(buffer)
            if (size < 0) break
            digest.update(buffer, 0, size)
          }
        }
      }
  }
  digest.update(project.file("build.gradle.kts").readBytes())
  return digest.digest().joinToString("") { "%02x".format(it) }
}

val doorbellSourceIdentity = sourceIdentity()

val doorbellTier = providers.gradleProperty("doorbellTier").orElse("modern").get()
require(doorbellTier == "modern" || doorbellTier == "legacy19") {
  "doorbellTier must be 'modern' or 'legacy19' (was '$doorbellTier')"
}
val doorbellNdk = if (doorbellTier == "legacy19") "25.2.9519653" else "27.1.12297006"

android {
  namespace = "jp.keihan.doorbell"
  compileSdk = 35
  // AGP exposes ndkVersion at module scope, not per product flavor.  CI and
  // provisioning therefore build one selected tier per Gradle invocation.
  ndkVersion = doorbellNdk

  defaultConfig {
    applicationId = "jp.keihan.doorbell"
    minSdk = 19
    targetSdk = 35
    versionCode = 1
    versionName = "0.3.0"
    buildConfigField("String", "DOORBELL_SOURCE_ID", "\"$doorbellSourceIdentity\"")

    externalNativeBuild {
      cmake {
        // Product APKs embed only the Core library, not host tests or runners.
        // Product APKs require the tier-matched PJSIP artifact; CMake fails instead of using a stub.
        arguments += listOf(
          "-DANDROID_STL=c++_static",
          "-DDB_BUILD_TESTS=OFF",
          "-DDB_WITH_PJSIP=ON")
        targets += "doorbell"
      }
    }
  }

  buildFeatures {
    buildConfig = true
  }

  flavorDimensions += "platform"
  productFlavors {
    create("legacy19") {
      dimension = "platform"
      minSdk = 19
      versionNameSuffix = "-legacy19"
      ndk { abiFilters += listOf("armeabi-v7a") }
      externalNativeBuild {
        cmake { arguments += "-DDB_ANDROID_PJSIP_TIER=api19" }
      }
      resValue("string", "android_build_tier", "legacy19")
    }
    create("modern") {
      dimension = "platform"
      minSdk = 21
      ndk { abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64") }
      externalNativeBuild {
        cmake { arguments += "-DDB_ANDROID_PJSIP_TIER=api21" }
      }
      resValue("string", "android_build_tier", "modern")
    }
  }

  externalNativeBuild {
    cmake {
      path = file("src/main/cpp/CMakeLists.txt")
      version = "3.22.1"
    }
  }

  buildTypes {
    release {
      isMinifyEnabled = false
      signingConfig = signingConfigs.getByName("debug")
    }
  }

  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  kotlinOptions {
    jvmTarget = "17"
  }

  sourceSets.getByName("main").assets.srcDir("../../assets")

  // Keep every locale in the AAB because the app switches Japanese, English, and Chinese.
  bundle {
    language { enableSplit = false }
  }
}

// The application runtime intentionally uses only Kotlin stdlib; these dependencies are host tests.
dependencies {
  testImplementation("junit:junit:4.13.2")
  testImplementation("org.json:json:20240303")
}

// Prevent aggregate tasks from mixing NDK r25 and r27 in one invocation.
// Examples:
//   ./gradlew -PdoorbellTier=modern assembleModernDebug
//   ./gradlew -PdoorbellTier=legacy19 assembleLegacy19Debug
androidComponents {
  beforeVariants(selector().all()) { variant ->
    val tier = variant.productFlavors.firstOrNull { it.first == "platform" }?.second
    if (tier != null && tier != doorbellTier) variant.enable = false
  }
}
