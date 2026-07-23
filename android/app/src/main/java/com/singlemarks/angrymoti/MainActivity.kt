package com.singlemarks.angrymoti

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
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
import com.singlemarks.angrymoti.ui.MountGuideScreen
import com.singlemarks.angrymoti.ui.OnboardingFlow
import com.singlemarks.angrymoti.ui.SessionResultScreen
import com.singlemarks.angrymoti.ui.SessionScreen
import com.singlemarks.angrymoti.ui.theme.AngryMotiTheme
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
        lifecycleScope.launch(Dispatchers.IO) {
            SessionEngine.recoverOrphanIfNeeded()
            AccountStore.syncFromCloud()   // 다른 기기 예약·점수·멤버십·세션 이력 병합
            AppState.refreshSpicyCompletions(this@MainActivity)   // 동기화된 이력으로 미친맛 해제 상태 갱신
            com.singlemarks.angrymoti.services.GroupStore.refresh(this@MainActivity)
            SessionEngine.sweepNoShows()
        }
        AppState.applyPendingDowngradeIfDue()
        AppState.refreshSpicyCompletions(this)
        AlarmScheduler.rescheduleAll(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action == "alarm") {
            val id = intent.getStringExtra("reservationId") ?: return
            val fireAt = intent.getLongExtra("fireAt", System.currentTimeMillis())
            AlarmScheduler.startAlarmSound(this)
            // 키가드(잠금) 해제 요청 — 잠금 상태에서는 안드로이드가 카메라 접근을 막으므로,
            // 촬영을 시작하려면 반드시 잠금을 풀어야 한다 (알람이 잠금 화면에서 울리는 게 정상 시나리오).
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
        // 백그라운드 전환 = 이탈 이벤트 (전화도 백그라운드로 내려가 동일 처리 — 매운맛 긴급용무·미친맛 실패)
        if (!isChangingConfigurations) SessionEngine.handleExitEvent()
    }

    override fun onStart() {
        super.onStart()
        SessionEngine.handleReturnEvent()
        AppState.applyPendingDowngradeIfDue()
        lifecycleScope.launch(Dispatchers.IO) {
            AccountStore.syncFromCloud()   // 다른 기기 예약·점수·멤버십 병합
            com.singlemarks.angrymoti.services.GroupStore.refresh(this@MainActivity)
            SessionEngine.sweepNoShows()
        }
    }
}

@Composable
private fun Root() {
    val route by AppState.route.collectAsStateWithLifecycle()
    val onboarded by AppState.onboarded.collectAsStateWithLifecycle()
    val user by AccountStore.user.collectAsState()
    val phase by SessionEngine.phase.collectAsStateWithLifecycle()

    // 계정 전환 시 그 계정의 강도·하향예약을 다시 불러온다 (#19 — 강도가 계정별이라 공유 기기 누수 차단)
    LaunchedEffect(user?.uid) { AppState.reloadForAccount() }

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
        !onboarded -> OnboardingFlow()
        user == null -> AuthScreen()
        else -> when (val r = route) {
            is Route.Alarm -> AlarmScreen(r.reservationId, r.fireAt)
            is Route.MountGuide -> MountGuideScreen(r.pending)
            Route.Session -> SessionScreen()
            Route.Result -> SessionResultScreen()
            Route.None -> HomeShell()
        }
    }
}
