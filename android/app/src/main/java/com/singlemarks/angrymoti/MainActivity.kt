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
        AppState.bootstrap()
        setContent { AngryMotiTheme { Root() } }
        handleIntent(intent)
        lifecycleScope.launch(Dispatchers.IO) {
            SessionEngine.recoverOrphanIfNeeded()
            AccountStore.syncScoreEventsFromCloud()   // 다른 기기 점수 병합
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
            AppState.route.value = Route.Alarm(id, fireAt)
        }
    }

    override fun onStop() {
        super.onStop()
        // 백그라운드 전환 = 이탈 이벤트 (통화 중은 엔진이 무시)
        if (!isChangingConfigurations) SessionEngine.handleExitEvent()
    }

    override fun onStart() {
        super.onStart()
        SessionEngine.handleReturnEvent()
        AppState.applyPendingDowngradeIfDue()
        lifecycleScope.launch(Dispatchers.IO) {
            AccountStore.syncScoreEventsFromCloud()   // 다른 기기 점수 병합
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
