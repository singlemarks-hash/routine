package com.singlemarks.angrymoti.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.googlefonts.Font
import androidx.compose.ui.text.googlefonts.GoogleFont
import com.singlemarks.angrymoti.R

/**
 * 앱 전역 한글 폰트 — Noto Sans KR.
 *
 * 지금까지 폰트를 지정하지 않아 기기의 시스템 폰트를 그대로 따라갔다. 순정은 Noto,
 * 갤럭시는 삼성 폰트이고 사용자가 시스템 폰트를 바꿀 수도 있어서, 같은 화면이 기기마다
 * 글자 폭·행간이 달랐다 (갤럭시에서만 제목이 줄바꿈되거나 태그 칩 높이가 튀던 원인).
 * 폰트를 못 박아야 레이아웃이 기기와 무관해진다.
 *
 * Downloadable Fonts를 쓰는 이유 — 한글 폰트는 글리프가 많아 웨이트마다 수 MB다.
 * 5종을 APK에 넣는 대신 Play 서비스가 받아 캐시하게 하면 앱 용량이 늘지 않는다.
 * 대가로 첫 실행에는 잠깐 시스템 폰트로 보였다가 교체되고, Play 서비스가 없는 기기
 * (일부 중국향 단말)에서는 계속 시스템 폰트를 쓴다 — 둘 다 기능에는 영향이 없다.
 */
private val provider = GoogleFont.Provider(
    providerAuthority = "com.google.android.gms.fonts",
    providerPackage = "com.google.android.gms",
    certificates = R.array.com_google_android_gms_fonts_certs,
)

private val notoSansKR = GoogleFont("Noto Sans KR")

/** 앱이 쓰는 웨이트만 — 없는 웨이트는 Compose가 가장 가까운 것으로 대체한다. */
val AppFont = FontFamily(
    Font(googleFont = notoSansKR, fontProvider = provider, weight = FontWeight.Normal),
    Font(googleFont = notoSansKR, fontProvider = provider, weight = FontWeight.Medium),
    Font(googleFont = notoSansKR, fontProvider = provider, weight = FontWeight.SemiBold),
    Font(googleFont = notoSansKR, fontProvider = provider, weight = FontWeight.Bold),
    Font(googleFont = notoSansKR, fontProvider = provider, weight = FontWeight.Black),
)

/**
 * 기본 Typography의 15개 스타일 전부에 폰트만 갈아 끼운다.
 *
 * 화면 대부분은 Text에 크기·굵기를 직접 주고 폰트는 LocalTextStyle에서 상속받지만,
 * 버튼·다이얼로그·텍스트필드 같은 머티리얼 컴포넌트는 MaterialTheme.typography를 직접
 * 읽는다. 여기를 통째로 바꿔야 그 안쪽 글자까지 같은 폰트가 된다.
 */
val AppTypography: Typography = Typography().run {
    Typography(
        displayLarge = displayLarge.copy(fontFamily = AppFont),
        displayMedium = displayMedium.copy(fontFamily = AppFont),
        displaySmall = displaySmall.copy(fontFamily = AppFont),
        headlineLarge = headlineLarge.copy(fontFamily = AppFont),
        headlineMedium = headlineMedium.copy(fontFamily = AppFont),
        headlineSmall = headlineSmall.copy(fontFamily = AppFont),
        titleLarge = titleLarge.copy(fontFamily = AppFont),
        titleMedium = titleMedium.copy(fontFamily = AppFont),
        titleSmall = titleSmall.copy(fontFamily = AppFont),
        bodyLarge = bodyLarge.copy(fontFamily = AppFont),
        bodyMedium = bodyMedium.copy(fontFamily = AppFont),
        bodySmall = bodySmall.copy(fontFamily = AppFont),
        labelLarge = labelLarge.copy(fontFamily = AppFont),
        labelMedium = labelMedium.copy(fontFamily = AppFont),
        labelSmall = labelSmall.copy(fontFamily = AppFont),
    )
}
