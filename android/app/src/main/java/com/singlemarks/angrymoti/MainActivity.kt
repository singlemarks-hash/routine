package com.singlemarks.angrymoti

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.singlemarks.angrymoti.data.Prefs
import com.singlemarks.angrymoti.models.SessionOutcome
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.AlarmScheduler
import com.singlemarks.angrymoti.services.SessionEngine
import com.singlemarks.angrymoti.ui.AlarmScreen
import com.singlemarks.angrymoti.ui.AuthScreen
import com.singlemarks.angrymoti.ui.HomeShell
import com.singlemarks.angrymoti.ui.IntroFlow
import com.singlemarks.angrymoti.ui.MountGuideScreen
import com.singlemarks.angrymoti.ui.OnboardingFlow
import com.singlemarks.angrymoti.ui.SessionResultScreen
import com.singlemarks.angrymoti.ui.SessionScreen
import androidx.compose.ui.Modifier
import com.singlemarks.angrymoti.ui.theme.AngryMotiTheme
import com.singlemarks.angrymoti.ui.theme.TL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import androidx.lifecycle.lifecycleScope

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 잠금 화면 위에 표시 + 화면 켜기 (매니페스트 플래그의 코드 버전 — 더 신뢰성 높음)
        if (android.os.Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        AppState.bootstrap()
        setContent { AngryMotiTheme { Root() } }
        handleIntent(intent)
        launchSyncPipeline(includeStartupExtras = true)
        AppState.applyPendingDowngradeIfDue()
        // rescheduleAll은 위 IO 파이프라인 끝에서 클라우드 병합 이후 데이터로 한 번만 건다 —
        // 여기서 또 걸면 옛 데이터 기준으로 걸었다가 다시 거는 낭비이자 경합 여지다.
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action != "alarm") return
        val id = intent.getStringExtra("reservationId") ?: return
        val fireAt = intent.getLongExtra("fireAt", System.currentTimeMillis())
        // 스테일 인텐트 방어 — 알람으로 실행된 액티비티의 마지막 인텐트는 최근 앱 목록에
        // 보존된다. 프로세스가 죽은 뒤 recents에서 다시 열면 며칠 전 알람이 그대로
        // 재처리되므로, 시작 창(10분)을 지난 알람은 무시한다.
        if (System.currentTimeMillis() - fireAt >
            com.singlemarks.angrymoti.models.TimePolicy.START_WINDOW_SECONDS * 1000) return
        // 진행 중 세션·다른 캡처 화면을 빼앗지 않는다 (iOS checkDueAlarm의 route/session
        // 가드). 뺏으면 촬영 화면이 알람 화면으로 교체되고 세션으로 돌아갈 동선이 없다.
        if (AppState.route.value != Route.None) return
        if (SessionEngine.phase.value !is SessionEngine.Phase.Idle) return
        // 온보딩·로그인 전에는 알람 화면을 띄울 수 없다 — 이 상태에서 소리부터 시작하면
        // 끌 수 있는 버튼이 화면에 없다.
        if (!AppState.onboarded.value || AccountStore.user.value == null) return
        lifecycleScope.launch {
            // 유령 알람 방어 — 삭제된 예약의 잔여 알람이면 화면·소리 없이 알림만 걷는다
            val r = kotlinx.coroutines.withContext(Dispatchers.IO) {
                com.singlemarks.angrymoti.data.AppDb.get(this@MainActivity).reservations().byId(id)
            }
            // 소유자 확인 — 공유 기기에서 계정을 전환한 경우, 이전 계정의 알람이 현재 계정
            // 화면으로 라우팅되면 '일정 취소' 벌점이 엉뚱한 계정에 찍힌다.
            if (r == null || !r.isActive || r.ownerUserID != AccountStore.currentUserID) {
                AlarmScheduler.cancelAlarmNotification(this@MainActivity)
                return@launch
            }
            AlarmScheduler.startAlarmSound(this@MainActivity)
            // 키가드(잠금) 해제 요청 — 잠금 상태에서는 안드로이드가 카메라 접근을 막으므로,
            // 촬영을 시작하려면 반드시 잠금을 풀어야 한다 (알람이 잠금 화면에서 울리는 게 정상).
            dismissKeyguardForCamera()
            AppState.route.value = Route.Alarm(id, fireAt)
        }
    }

    /** 잠금 해제 요청 — 성공해야 카메라가 열린다. 실패(보안 잠금 미해제) 시 촬영 진입에서 재시도 가능. */
    private fun dismissKeyguardForCamera() {
        val km = getSystemService(android.app.KeyguardManager::class.java)
        if (km != null && km.isKeyguardLocked && android.os.Build.VERSION.SDK_INT >= 26) {
            km.requestDismissKeyguard(this, null)
        }
    }

    override fun onStop() {
        super.onStop()
        tickerJob?.cancel(); tickerJob = null
        // 백그라운드 전환 = 이탈 이벤트 (전화도 백그라운드로 내려가 동일 처리 — 매운맛 긴급용무·미친맛 실패)
        if (!isChangingConfigurations) SessionEngine.handleExitEvent()
    }

    override fun onStart() {
        super.onStart()
        SessionEngine.handleReturnEvent()
        AppState.applyPendingDowngradeIfDue()
        startForegroundTicker()
        launchSyncPipeline()
    }

    /** 콜드 스타트에서 onCreate와 onStart가 거의 동시에 불린다 — 같은 파이프라인이 겹쳐
     *  돌면 세션 이력이 절반만 병합된 상태로 게이트가 열려 노쇼 스윕이 잘못 돈다.
     *  인플라이트 가드로 한 번에 하나만 돌린다 (겹치면 늦은 쪽은 건너뛴다 — 앞선 실행이
     *  같은 일을 끝까지 해 준다). */
    private val syncInFlight = java.util.concurrent.atomic.AtomicBoolean(false)

    private fun launchSyncPipeline(includeStartupExtras: Boolean = false) {
        if (!syncInFlight.compareAndSet(false, true)) return
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                // 순서 불변식 (iOS와 동일): 동기화 → 기록 수렴 → 방 정리 → 게이트 open →
                // 노쇼 집계 → 만료 은퇴 → 재스케줄. 방 정리가 집계보다 먼저여야 취소·삭제예정
                // 방의 예약이 사라진 뒤 집계가 돌아 부당 벌점이 안 찍히고, 만료 은퇴가 집계
                // 뒤여야 마지막 날 노쇼가 유실되지 않는다.
                if (includeStartupExtras) SessionEngine.recoverOrphanIfNeeded()
                val syncOk = AccountStore.syncFromCloud()   // 다른 기기 예약·점수·멤버십·세션 이력 병합
                SessionEngine.reconcileDuplicateOutcomes()   // 성공 기록이 노쇼를 덮는다
                com.singlemarks.angrymoti.services.GroupStore.refresh(this@MainActivity)
                // 동기화가 조용히 실패했으면(오프라인 등) 게이트를 열지 않는다 — 다른 기기의
                // 성공 기록이 내려오기 전에 노쇼 스윕이 돌면 벌점이 잘못 찍혔다 사라진다.
                if (syncOk) SessionEngine.markInitialSyncComplete()
                SessionEngine.sweepNoShows()
                SessionEngine.cleanupExpiredReservations()
                AlarmScheduler.rescheduleAll(this@MainActivity)
            } finally {
                syncInFlight.set(false)
            }
        }
    }

    private var tickerJob: kotlinx.coroutines.Job? = null

    /** 포그라운드 30초 틱 (iOS sweepTimer 대응) — OEM이 정확 알람을 지연·삭제해도 앱을
     *  보고 있는 동안에는 하향 적용·노쇼 집계·발화 알람 감지가 늦지 않게 돈다 */
    private fun startForegroundTicker() {
        tickerJob?.cancel()
        tickerJob = lifecycleScope.launch {
            while (true) {
                kotlinx.coroutines.delay(30_000)
                AppState.applyPendingDowngradeIfDue()
                kotlinx.coroutines.withContext(Dispatchers.IO) { SessionEngine.sweepNoShows() }
                checkDueAlarm()
            }
        }
    }

    /** 발화 시각이 지났는데 알람 리시버가 안 온 경우의 안전망 — 시작 창 안의 발생을 찾아
     *  직접 알람 화면으로 라우팅한다 (iOS checkDueAlarm 1:1). 자정 직후를 위해 어제도 본다. */
    private suspend fun checkDueAlarm() {
        if (AppState.route.value != Route.None) return
        if (SessionEngine.phase.value !is SessionEngine.Phase.Idle) return
        if (!AppState.onboarded.value || AccountStore.user.value == null) return
        val now = System.currentTimeMillis()
        val owner = AccountStore.currentUserID
        val windowMs = com.singlemarks.angrymoti.models.TimePolicy.START_WINDOW_SECONDS * 1000
        val due = kotlinx.coroutines.withContext(Dispatchers.IO) {
            val db = com.singlemarks.angrymoti.data.AppDb.get(this@MainActivity)
            val sessions = db.sessions().all(owner)
            db.reservations().active(owner).firstNotNullOfOrNull { r ->
                for (offset in -1..0) {
                    val day = java.util.Calendar.getInstance().apply {
                        timeInMillis = now
                        set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
                        set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
                        add(java.util.Calendar.DAY_OF_MONTH, offset)
                    }.timeInMillis
                    val fire = r.occurrenceOn(day) ?: continue
                    if (now < fire || now >= fire + windowMs) continue
                    // 이 발생을 이미 시작(완료·취소 포함)했으면 다시 울리지 않는다
                    val handled = sessions.any {
                        it.reservationID == r.id && it.scheduledAt != null &&
                            kotlin.math.abs(it.scheduledAt!! - fire) < 60_000L
                    }
                    if (!handled) return@firstNotNullOfOrNull r.id to fire
                }
                null
            }
        } ?: return
        AlarmScheduler.startAlarmSound(this)
        AppState.route.value = Route.Alarm(due.first, due.second)
    }
}

@Composable
private fun Root() {
    val route by AppState.route.collectAsStateWithLifecycle()
    val onboarded by AppState.onboarded.collectAsStateWithLifecycle()
    val introSeen by AppState.introSeen.collectAsStateWithLifecycle()
    val user by AccountStore.user.collectAsState()
    val phase by SessionEngine.phase.collectAsStateWithLifecycle()

    // 계정 전환 시 그 계정의 강도·하향예약을 다시 불러온다 (#19 — 강도가 계정별이라 공유 기기 누수 차단)
    // 고아 세션 복구도 함께 — 계정별 슬롯이라 '그 계정으로 다시 로그인했을 때'가 복구
    // 시점인데, 콜드 스타트에만 걸어두면 앱을 완전히 껐다 켜야만 복구된다.
    LaunchedEffect(user?.uid) {
        AppState.reloadForAccount()
        kotlinx.coroutines.withContext(Dispatchers.IO) { SessionEngine.recoverOrphanIfNeeded() }
    }

    // 세션 종료 → 결과 화면 (iOS RootView.onChange(engine.phase) 대응)
    LaunchedEffect(phase) {
        if (phase is SessionEngine.Phase.Finished &&
            (route is Route.Session || route is Route.None) &&
            SessionEngine.lastFinishedSession.value != null
        ) {
            AppState.sessionFinished()
        }
    }

    when {
        // 첫 실행 순서: 인트로(촬영하기·기록관리) → 로그인(또는 게스트) → 권한 설정 → 홈.
        // 인트로를 로그인보다 앞에 두는 이유 — 무엇을 하는 앱인지 먼저 보여줘야
        // 로그인 장벽이 낮아진다 (iOS RootView 1:1).
        !introSeen -> IntroFlow(onFinish = { AppState.completeIntro() })
        user == null -> AuthScreen()
        !onboarded -> OnboardingFlow()
        else -> when (val r = route) {
            is Route.Alarm -> AlarmScreen(r.reservationId, r.fireAt)
            is Route.MountGuide -> MountGuideScreen(r.pending)
            Route.Session -> SessionScreen()
            Route.Result -> SessionResultScreen()
            // 홈 셸(홈·일정·그룹 + 기록·마이페이지·예약 편집)은 상태바 아래~내비바 위에 그린다 —
            // edge-to-edge 기본값(targetSdk 35) 그대로 두면 상단 배지가 상태바와, 하단 탭바가
            // 갤럭시 3버튼 내비바와 겹친다. 배경은 인셋 밖까지 채워 양쪽 바 뒤도 잉크색으로
            // 이어지게 한다 (iOS 세이프 에어리어 1:1).
            Route.None -> Box(
                Modifier.fillMaxSize().background(TL.ink)
                    .statusBarsPadding().navigationBarsPadding()
            ) { HomeShell() }
        }
    }
}
