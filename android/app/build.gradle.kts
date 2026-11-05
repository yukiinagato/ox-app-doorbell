import java.io.File
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

fun gitRevision(repository: File): String {
  val override = System.getenv("DB_BUILD_ID")?.trim().orEmpty()
  if (override.matches(Regex("^[0-9a-fA-F]{7,64}$"))) return override.lowercase()
  return try {
    val process = ProcessBuilder("git", "-C", repository.absolutePath, "rev-parse", "HEAD")
      .redirectErrorStream(true)
      .start()
    val revision = process.inputStream.bufferedReader().use { it.readText() }.trim()
    if (process.waitFor() == 0 && revision.matches(Regex("^[0-9a-fA-F]{40,64}$")))
      revision.lowercase() else "dev"
  } catch (_: Exception) {
    "dev"
  }
}

val doorbellGitRevision = gitRevision(rootProject.projectDir)

val doorbellTier = providers.gradleProperty("doorbellTier").orElse("modern").get()
require(doorbellTier == "modern" || doorbellTier == "legacy19") {
  "doorbellTier must be 'modern' or 'legacy19' (was '$doorbellTier')"
}
val doorbellNdk = if (doorbellTier == "legacy19") "25.2.9519653" else "27.1.12297006"

// One build number per release; each flavour gets its own versionCode derived from it, so a
// legacy19 and a modern APK of the same release never share a code (and both stay above the
// single shared code 27 used through 0.3.26).
val doorbellBuildNumber = 31
fun flavorVersionCode(flavorDigit: Int): Int = doorbellBuildNumber * 10 + flavorDigit

// Release signing comes from Gradle properties or the environment, never from the repository:
//   doorbell.release.storeFile / DOORBELL_RELEASE_STORE_FILE
//   doorbell.release.storePassword / DOORBELL_RELEASE_STORE_PASSWORD
//   doorbell.release.keyAlias / DOORBELL_RELEASE_KEY_ALIAS
//   doorbell.release.keyPassword / DOORBELL_RELEASE_KEY_PASSWORD
fun releaseSetting(property: String, env: String): String? =
  providers.gradleProperty(property).orNull?.takeIf { it.isNotBlank() }
    ?: System.getenv(env)?.takeIf { it.isNotBlank() }

val releaseStoreFile = releaseSetting("doorbell.release.storeFile", "DOORBELL_RELEASE_STORE_FILE")
val releaseStorePassword =
  releaseSetting("doorbell.release.storePassword", "DOORBELL_RELEASE_STORE_PASSWORD")
val releaseKeyAlias = releaseSetting("doorbell.release.keyAlias", "DOORBELL_RELEASE_KEY_ALIAS")
val releaseKeyPassword =
  releaseSetting("doorbell.release.keyPassword", "DOORBELL_RELEASE_KEY_PASSWORD")
val releaseSigningConfigured = listOf(
  releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword,
).all { it != null }

android {
  namespace = "jp.ox.doorbell"
  compileSdk = 35
  // AGP exposes ndkVersion at module scope, not per product flavor.  CI and
  // provisioning therefore build one selected tier per Gradle invocation.
  ndkVersion = doorbellNdk

  defaultConfig {
    applicationId = "jp.ox.doorbell"
    minSdk = 19
    targetSdk = 35
    testInstrumentationRunner = "jp.ox.doorbell.VisitorUiInstrumentation"
    versionCode = flavorVersionCode(0)
    versionName = "0.3.30+${doorbellGitRevision.take(7)}"
    buildConfigField("String", "DOORBELL_SOURCE_ID", "\"$doorbellSourceIdentity\"")

    externalNativeBuild {
      cmake {
        // Product APKs embed only the Core library, not host tests or runners.
        // Product APKs require the tier-matched PJSIP artifact; CMake fails instead of using a stub.
        arguments += listOf(
          "-DANDROID_STL=c++_static",
          "-DDB_BUILD_TESTS=OFF",
          "-DDB_BUILD_ID_ARG=$doorbellGitRevision",
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
      versionCode = flavorVersionCode(1)
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
      versionCode = flavorVersionCode(2)
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

  signingConfigs {
    if (releaseSigningConfigured) {
      create("release") {
        storeFile = file(releaseStoreFile!!)
        storePassword = releaseStorePassword
        keyAlias = releaseKeyAlias
        keyPassword = releaseKeyPassword
      }
    }
  }

  buildTypes {
    release {
      isMinifyEnabled = false
      // A release signed with a machine's debug key cannot upgrade an installed release and is
      // not release provenance, so a missing release key leaves the APK unsigned and the
      // packaging check below fails the build.
      if (releaseSigningConfigured) signingConfig = signingConfigs.getByName("release")
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

// Fail release packaging without a release key instead of silently shipping a debug signature.
gradle.taskGraph.whenReady {
  val packagesRelease = allTasks.any {
    it.project == project && it.name.startsWith("package") && it.name.endsWith("Release")
  }
  if (packagesRelease && !releaseSigningConfigured) {
    throw GradleException(
      "Release signing is not configured. Set doorbell.release.storeFile, " +
        "doorbell.release.storePassword, doorbell.release.keyAlias and " +
        "doorbell.release.keyPassword (Gradle properties) or the matching " +
        "DOORBELL_RELEASE_* environment variables.")
  }
}
