package com.singlemarks.angrymoti

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.os.LocaleList
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.core.app.ActivityOptionsCompat
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.services.storage.TestStorage
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.data.Reservation
import com.singlemarks.angrymoti.ui.AlarmHealthScreen
import com.singlemarks.angrymoti.ui.SessionScreen
import com.singlemarks.angrymoti.ui.AuthScreen
import com.singlemarks.angrymoti.ui.CalendarScreen
import com.singlemarks.angrymoti.ui.GroupTab
import com.singlemarks.angrymoti.ui.HomeShell
import com.singlemarks.angrymoti.ui.IntroFlow
import com.singlemarks.angrymoti.ui.MyPageScreen
import com.singlemarks.angrymoti.ui.OnboardingFlow
import com.singlemarks.angrymoti.ui.PaywallScreen
import com.singlemarks.angrymoti.ui.ReservationEditScreen
import com.singlemarks.angrymoti.ui.theme.AngryMotiTheme
import kotlinx.coroutines.runBlocking
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Calendar
import java.util.Locale

/**
 * G2 스크린샷 하네스 (docs/영어화-설계도.md §2).
 *
 * 실제 화면 컴포저블을 렌더해 PNG로 남긴다 — 영어화 전 ko '베이스라인'을 뜨고,
 * 포맷터 교체(0.5) 후 회귀 대조, 영어화 후 en 검수에 재사용한다.
 *
 * 로케일은 단말 설정 대신 테스트 프로세스에서 주입한다:
 *  - `Locale.setDefault` → TLFormat 등 java.util 포맷터
 *  - `createConfigurationContext` + CompositionLocal 오버라이드 → stringResource (Phase 3 이후)
 * 실행 인자 `-e locale en` 으로 전환 (기본 ko).
 *
 * 카메라·촬영 계열 화면(거치 가이드·세션·알람)은 하드웨어/권한 의존이라 v1에서 제외 —
 * G4 실기기 검수 항목으로 남긴다 (설계도 §5 비고).
 */
@RunWith(AndroidJUnit4::class)
class ScreenshotTour {

    @get:Rule
    val rule = createComposeRule()

    private val localeTag: String =
        InstrumentationRegistry.getArguments().getString("locale") ?: "ko"

    private val appContext: Context =
        InstrumentationRegistry.getInstrumentation().targetContext

    @Before
    fun seed() {
        Locale.setDefault(Locale.forLanguageTag(localeTag))
        // L10n(비컴포저블 경로 — CanonicalKeys label() 등)은 Application Context를 쓰는데,
        // 에뮬레이터 기본 로케일(en)이라 LocalContext 오버라이드가 닿지 않는다. 실기기에서는
        // 앱 로케일이 Application Context에도 적용되므로 하네스만의 문제 — 여기서 직접 주입한다.
        val localized = appContext.createConfigurationContext(
            Configuration(appContext.resources.configuration).apply {
                setLocales(LocaleList(Locale.forLanguageTag(localeTag)))
            })
        L10n.initForTest { id, args ->
            if (args.isEmpty()) localized.getString(id) else localized.getString(id, *args)
        }
        // 포맷터가 실제로 보이는 베이스라인을 위해 예약 2건 시딩 (게스트 소유, 멱등 ID)
        val today = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        runBlocking {
            val dao = AppDb.get(appContext).reservations()
            dao.upsert(Reservation(
                id = "shot-weekly", ownerUserID = "guest",
                name = "아침 독서", tag = "독서",
                startMinute = 7 * 60, durationMinutes = 30,
                repeatWeekdaysCsv = "2,3,4,5,6",
            ))
            dao.upsert(Reservation(
                id = "shot-oneoff", ownerUserID = "guest",
                name = "저녁 운동", tag = "운동",
                startMinute = 19 * 60 + 30, durationMinutes = 60,
                oneOffDayStart = today,
            ))
        }
    }

    /** 로케일 오버라이드 컨텍스트로 감싼 렌더 → 안정화 대기 → 캡처 저장 */
    private fun shot(name: String, content: @Composable () -> Unit) {
        rule.setContent {
            LocaleHost(localeTag) { AngryMotiTheme { content() } }
        }
        rule.waitForIdle()
        Thread.sleep(700)   // Room flow 첫 방출·이미지 로드 대기
        rule.waitForIdle()
        val bmp = rule.onRoot().captureToImage().asAndroidBitmap()
        // TestStorage: AGP가 테스트 종료(=앱 언인스톨로 앱 저장소가 통째로 삭제되기) 전에
        // 호스트의 build/outputs/connected_android_test_additional_output/으로 자동 회수한다.
        // 앱 외부 files 디렉터리에 직접 쓰는 방식은 언인스톨과 함께 지워져 회수가 불가능했다.
        TestStorage().openOutputFile("$localeTag-$name.png").use {
            bmp.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    @Composable
    private fun LocaleHost(tag: String, content: @Composable () -> Unit) {
        val base = LocalContext.current
        val ctx = remember(tag) {
            base.createConfigurationContext(Configuration(base.resources.configuration).apply {
                setLocales(LocaleList(Locale.forLanguageTag(tag)))
            })
        }
        // 권한 요청 런처(rememberLauncherForActivityResult)를 쓰는 화면(온보딩·예약 편집)이
        // 테스트 컴포지션에서 죽지 않게 무동작 레지스트리를 공급한다 — 캡처만 하므로 실제 발사는 불필요.
        val registryOwner = remember {
            object : ActivityResultRegistryOwner {
                override val activityResultRegistry = object : ActivityResultRegistry() {
                    override fun <I, O> onLaunch(
                        requestCode: Int,
                        contract: ActivityResultContract<I, O>,
                        input: I,
                        options: ActivityOptionsCompat?,
                    ) { /* no-op */ }
                }
            }
        }
        CompositionLocalProvider(
            LocalContext provides ctx,
            LocalConfiguration provides ctx.resources.configuration,
            LocalActivityResultRegistryOwner provides registryOwner,
        ) { content() }
    }

    // ── 화면 목록 (설계도 §5의 하네스 대상 부분집합) ─────────────────────────

    @Test fun intro() = shot("intro") { IntroFlow(onFinish = {}) }
    @Test fun auth() = shot("auth") { AuthScreen() }
    @Test fun permissions() = shot("permissions") { OnboardingFlow() }
    @Test fun home() = shot("home") { HomeShell() }
    @Test fun reservationNew() = shot("reservation-new") {
        ReservationEditScreen(reservationId = null, onDone = {})
    }
    @Test fun reservationEdit() = shot("reservation-edit") {
        ReservationEditScreen(reservationId = "shot-weekly", onDone = {})
    }
    @Test fun calendar() = shot("calendar") { CalendarScreen(onBack = {}) }
    @Test fun groups() = shot("groups") { GroupTab() }
    @Test fun myPage() = shot("mypage") { MyPageScreen(onBack = {}) }
    @Test fun paywall() = shot("paywall") { PaywallScreen(onBack = {}) }
    @Test fun alarmHealth() = shot("alarm-health") { AlarmHealthScreen(onBack = {}) }

    // 세션 세로 화면 — 카메라 없이 상태만 주입해 레이아웃 비율을 본다 (프리뷰는 검은 카드).
    // 25분 목표에 7분 경과 시점: 다이얼 부채꼴·타이머가 실사용 모습으로 찍힌다.
    @Test fun session() {
        com.singlemarks.angrymoti.services.SessionEngine.seedForScreenshot(
            com.singlemarks.angrymoti.data.FocusSession(
                activityName = "아침 독서", tag = "독서",
                intensityRaw = "spicy", targetSeconds = 25 * 60,
            ),
            recorded = 7 * 60,
        )
        shot("session") { SessionScreen() }
    }
}
