import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名配置从 android/key.properties 读（该文件不入库）。缺失时整段跳过。
// 注意：这里必须 import java.util.Properties。脚本体里裸写 `java.util.Properties()`
// 会被解析成 Project 的 `java` 扩展（JavaPluginExtension），报 Unresolved reference 'util'。
val keystorePropsFile = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        keystorePropsFile.inputStream().use { load(it) }
    }
}

android {
    namespace = "com.emfox.famdaily"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    signingConfigs {
        if (keystorePropsFile.exists()) {
            create("release") {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 22.x 需要 core library desugaring：
        // 它内部用 java.time 做时区换算，而 java.time 在 Android 上要 API 26 才有。
        // 本项目 minSdk = 24（Flutter 3.44 默认），Android 7.x 那批机器因此必须靠脱糖补齐。
        // 少了这行不是警告，是硬失败：':app:checkDebugAarMetadata' 直接中断构建。
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.emfox.famdaily"
        // minSdk 取 Flutter 默认 24（Android 7.0）。刻意不抬到 26：家里的旧安卓机往往就是那台
        // 摆客厅、谁都能点一下的机器，抬到 26 等于把它排除在外。见 docs/tech-stack 平台支持一节。
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 正式签名走 key.properties（不入库，见 .gitignore）。文件不在时回退 debug 签名，
            // 这样没配签名的机器也能 `flutter build apk --release` 出包自测；
            // 但这种包的签名指纹是 debug 的，不能上架、也不能覆盖安装到正式版上。
            signingConfig = if (keystorePropsFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                logger.lifecycle(
                    "[famdaily] 未找到 key.properties，release 将使用 debug 签名（仅限自测）。"
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 配合上面的 isCoreLibraryDesugaringEnabled。版本由 AGP 校验，不匹配会报错。
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
