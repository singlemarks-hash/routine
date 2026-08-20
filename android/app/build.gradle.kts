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
    compileSdk = 36

    defaultConfig {
        applicationId = "com.selfer.angrymoti"
        minSdk = 26
        targetSdk = 36
        versionCode = 19
        versionName = "1.2.0"
        // G2 스크린샷 하네스 (docs/영어화-설계도.md §2) — androidTest 캡처 실행용.
        // useTestStorageService: 캡처 PNG를 TestStorage로 저장하면 AGP가 테스트 종료(=앱
        // 언인스톨) 전에 build/outputs/connected_android_test_additional_output/으로 자동
        // 회수한다 — 앱 외부 저장소에 직접 쓰면 언인스톨과 함께 지워져 회수가 불가능했다.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        testInstrumentationRunnerArguments["useTestStorageService"] = "true"
    }

    signingConfigs {
        // debug 서명을 저장소의 공유 키스토어로 고정한다. 기본 동작(~/.android/debug.keystore)은
        // 머신마다 지문이 달라서 — 특히 CI 러너는 매 실행 새 키를 만들어 — Firebase에 SHA-1을
        // 등록할 수 없고, 그 빌드에서는 Google 로그인이 항상 NoCredentialException으로 죽는다.
        // 이 키의 SHA-1(D8:3D:D2:C8:C6:52:E4:72:E1:65:C3:73:01:1A:28:91:C2:BE:16:53)을
        // Firebase 콘솔에 1회 등록하면 CI APK·로컬 빌드 모두에서 로그인이 된다.
        getByName("debug") {
            storeFile = rootProject.file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
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
    // 앱 전역 한글 폰트(Noto Sans KR) — Downloadable Fonts로 받는다.
    // 인증서 배열(com_google_android_gms_fonts_certs)은 res/values/font_certs.xml에 별도 선언.
    implementation("androidx.compose.ui:ui-text-google-fonts")
    // 앱 전역 아이콘 — Material Icons Extended의 Filled(솔리드) 세트 사용 (AppIcon 매핑)
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.navigation:navigation-compose:2.8.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.core:core-splashscreen:1.0.1")

    // Room (SwiftData 대응) — KSP 2.2.21-2.0.x는 KSP2 전용이라 KSP2를 공식 지원하는 2.7로 상향
    implementation("androidx.room:room-runtime:2.7.2")
    implementation("androidx.room:room-ktx:2.7.2")
    ksp("androidx.room:room-compiler:2.7.2")

    // 설정 저장

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
    // 7.x는 2026-08-31부터 업데이트 거부 대상 — Play 정책상 v8 이상 필수라 9.x로 상향.
    // (9.x 요구사항: minSdk 23·targetSdk 35 이상 — 우리는 26/36이라 충족)
    implementation("com.android.billingclient:billing-ktx:9.1.0")

    // Firebase (iOS와 같은 프로젝트 timelock-eba85 재사용 — 계정·점수 공유)
    implementation(platform("com.google.firebase:firebase-bom:33.3.0"))
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-firestore")
    implementation("com.google.android.gms:play-services-auth:21.2.0")
    implementation("androidx.credentials:credentials:1.3.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.3.0")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.1.1")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.8.1")

    // G3 매핑 왕복 테스트 (JVM 단위 테스트 — CanonicalKeys 키↔한글 왕복)
    testImplementation("junit:junit:4.13.2")

    // G2 스크린샷 하네스 — 실제 화면 컴포저블을 에뮬레이터에서 렌더해 PNG로 캡처한다.
    // (영어화 ko 베이스라인/en 검수용. 단말 로케일 대신 테스트 프로세스에서 로케일을 주입)
    androidTestImplementation(composeBom)
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    // TestStorage API(캡처 저장) + 기기에 설치되는 서비스 APK(androidTestUtil)
    androidTestImplementation("androidx.test.services:storage:1.5.0")
    androidTestUtil("androidx.test.services:test-services:1.5.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
