plugins {
  id("com.android.application")
  id("org.jetbrains.kotlin.android")
}

android {
  namespace = "jp.keihan.doorbell"
  compileSdk = 35
  ndkVersion = "27.1.12297006"

  defaultConfig {
    applicationId = "jp.keihan.doorbell"
    minSdk = 21           // Android 5.0 — 廃品タブレット再利用を想定
    targetSdk = 35
    versionCode = 1
    versionName = "0.3.0"

    externalNativeBuild {
      cmake {
        // core は POSIX ビルド可能 — テスト/ホストランナーは外す。
        // PJSIP は tools/build_pjsip_android.sh のプリビルドがあれば有効 (無ければスタブ)。
        arguments += listOf(
          "-DANDROID_STL=c++_static",
          "-DDB_BUILD_TESTS=OFF",
          "-DDB_WITH_PJSIP=ON")
        targets += "doorbell"   // libdoorbell.so (C ABI + JNI グルー) だけを APK に入れる
      }
    }
    ndk {
      abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
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
      isMinifyEnabled = false  // 依存最小なので縮小不要。JNI 逆参照の保護も兼ねる
      signingConfig = signingConfigs.getByName("debug")  // 実配備は provision 手順で署名鍵を差し替え
    }
  }

  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  kotlinOptions {
    jvmTarget = "17"
  }
}

// 外部ライブラリは意図的にゼロ (Kotlin stdlib のみ)。UI は View/XML、通信・JSON は core 側。
dependencies {
}
