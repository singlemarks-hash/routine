import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.devtools.ksp")
}

// Firebase 구성 파일이 있을 때만 google-services 적용 (iOS의 canImport 격리와 동일한 전략)
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// 업로드 키스토어 — android/keystore.properties가 있을 때만 release 서명 구성
// (파일·키스토어는 .gitignore 대상, docs/안드로이드-가이드.md 배포 절차 참고)
val keystoreProps = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.singlemarks.angrymoti"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.selfer.angrymoti"
        minSdk = 26
        targetSdk = 35
        versionCode = 7
        versionName = "1.1.0"
    }

    signingConfigs {
        if (keystoreProps.isNotEmpty()) {
            create("upload") {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // keystore.properties가 있으면 업로드 키, 없으면 debug 키 (로컬 테스트용)
            signingConfig = if (keystoreProps.isNotEmpty())
                signingConfigs.getByName("upload") else signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.02")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.material3:material3")
    // 앱 전역 아이콘 — Material Icons Extended의 Filled(솔리드) 세트 사용 (AppIcon 매핑)
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.navigation:navigation-compose:2.8.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.core:core-splashscreen:1.0.1")

    // Room (SwiftData 대응)
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")

    // 설정 저장
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // CameraX (AVFoundation 대응) — ProcessCameraProvider가 Guava ListenableFuture를 노출하므로 guava 필요
    implementation("com.google.guava:guava:33.0.0-android")
    val camerax = "1.4.2"
    implementation("androidx.camera:camera-core:$camerax")
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")

    // ML Kit 얼굴 감지 — 온디바이스, 자리비움 판정 (Vision 대응)
    implementation("com.google.mlkit:face-detection:16.1.6")
    // ML Kit 포즈 감지 — 얼굴이 안 잡혀도 상반신이 보이면 재석 판정 (iOS upperBody 기준과 통일)
    implementation("com.google.mlkit:pose-detection:18.0.0-beta5")

    // Google Play Billing (StoreKit 2 대응)
    implementation("com.android.billingclient:billing-ktx:7.0.0")

    // Firebase (iOS와 같은 프로젝트 timelock-eba85 재사용 — 계정·점수 공유)
    implementation(platform("com.google.firebase:firebase-bom:33.3.0"))
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-firestore")
    implementation("com.google.android.gms:play-services-auth:21.2.0")
    implementation("androidx.credentials:credentials:1.3.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.3.0")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.1.1")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.8.1")
}
