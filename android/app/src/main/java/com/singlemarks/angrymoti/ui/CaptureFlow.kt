package com.singlemarks.angrymoti.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.border
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.singlemarks.angrymoti.AppState
import com.singlemarks.angrymoti.PendingSession
import com.singlemarks.angrymoti.R
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.models.AbsencePolicy
import com.singlemarks.angrymoti.models.Intensity
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.SessionOutcome
import com.singlemarks.angrymoti.models.TimePolicy
import com.composables.icons.lucide.*
import com.singlemarks.angrymoti.services.AlarmScheduler
import com.singlemarks.angrymoti.services.CameraRecorder
import com.singlemarks.angrymoti.services.SessionEngine
import com.singlemarks.angrymoti.ui.theme.TL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

// MARK: 알람 화면 — 촬영 준비 / 일정 취소(사유 기록)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AlarmScreen(reservationId: String, fireAt: Long) {
    val context = LocalContext.current
    val db = remember { AppDb.get(context) }
    var reservation by remember { mutableStateOf<com.singlemarks.angrymoti.data.Reservation?>(null) }
    var showCancel by remember { mutableStateOf(false) }
    var reason by remember { mutableStateOf("") }
    var remaining by remember { mutableIntStateOf(TimePolicy.START_WINDOW_SECONDS.toInt()) }

    LaunchedEffect(reservationId) {
        withContext(Dispatchers.IO) { reservation = db.reservations().byId(reservationId) }
        while (true) {
            val left = (fireAt + TimePolicy.START_WINDOW_SECONDS * 1000 - System.currentTimeMillis()) / 1000
            remaining = left.toInt().coerceAtLeast(0)
            if (left <= 0) {
                // 10분 창 종료 — 노쇼는 스위퍼가 기록. 알람만 정리하고 홈으로.
                AlarmScheduler.stopAlarmSound()
                AlarmScheduler.cancelAlarmNotification(context)
                AppState.route.value = com.singlemarks.angrymoti.Route.None
                break
            }
            delay(1000)
        }
    }
    val r = reservation ?: return

    Column(
        Modifier.fillMaxSize().background(TL.ink).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(60.dp))
        Text("활동 시간!", color = TL.rec, fontSize = 34.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(10.dp))
        Text(r.name, color = TL.paper, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Text("${TLFormat.durationLabel(r.durationMinutes)} · ${r.tag}", color = TL.muted, fontSize = 15.sp)
        Spacer(Modifier.height(30.dp))
        Text(TLFormat.hms(remaining.toLong()), color = TL.amber, fontSize = 44.sp, fontWeight = FontWeight.Black)
        Text("이 안에 촬영을 시작하지 않으면 노쇼로 기록됩니다", color = TL.muted, fontSize = 13.sp)
        Spacer(Modifier.weight(1f))
        TLPrimaryButton("촬영 준비") {
            AppState.beginRecording(context, PendingSession(
                activityName = r.name, tag = r.tag, targetSeconds = r.durationMinutes * 60,
                reservationId = r.id, scheduledAt = fireAt,
                intensityOverrideRaw = r.intensityOverrideRaw,
            ))
        }
        Spacer(Modifier.height(12.dp))
        Text("일정 취소 (긴급 벌점 ${ScoreRules.points(SessionOutcome.EMERGENCY, AppState.intensity.value, r.durationMinutes)?.second ?: -5}점)",
            color = TL.muted, fontSize = 14.sp,
            modifier = Modifier.clickable { showCancel = true }.padding(8.dp))
        Spacer(Modifier.height(24.dp))
    }

    if (showCancel) {
        ModalBottomSheet(onDismissRequest = { showCancel = false }, containerColor = TL.surface) {
            Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp)) {
                Text("일정을 취소할까요?", color = TL.paper, fontSize = 19.sp, fontWeight = FontWeight.Black)
                Text("취소 사유가 기록되고 긴급 벌점이 부과됩니다.", color = TL.muted, fontSize = 13.sp)
                Spacer(Modifier.height(14.dp))
                OutlinedTextField(reason, { reason = it }, modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("사유 (예: 몸살)", color = TL.faint) },
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = TL.paper, unfocusedTextColor = TL.paper,
                        focusedBorderColor = TL.rec, unfocusedBorderColor = TL.hairline, cursorColor = TL.rec))
                Spacer(Modifier.height(14.dp))
                TLPrimaryButton("취소 확정", enabled = reason.isNotBlank()) {
                    AppState.cancelSchedule(context, r, fireAt, reason.trim())
                }
            }
        }
    }
}

// MARK: 거치 가이드 — 방향 선택·프리뷰·3-2-1 카운트다운 (녹화는 카운트다운과 병렬 시작)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MountGuideScreen(pending: PendingSession) {
    val context = LocalContext.current
    var portrait by remember { mutableStateOf(true) }
    var check1 by remember { mutableStateOf(false) }   // 거치대에 폰 고정
    var check2 by remember { mutableStateOf(false) }   // 구도 안에 내가 보임
    var countdown by remember { mutableStateOf<Int?>(null) }
    var waitingCamera by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { CameraRecorder.startPreview(context) }

    LaunchedEffect(countdown) {
        if (countdown == 3) {
            AppState.startArmedRecording(pending, portrait)   // 카운트다운과 병렬로 녹화 시작
        }
        when (val c = countdown) {
            null -> {}
            0 -> {
                // "시작!" — 첫 프레임 확인 후 세션 진입 (최대 8초 대기)
                var waited = 0
                while (CameraRecorder.frameCount.value == 0 && waited < 8) {
                    waitingCamera = true
                    delay(1000); waited++
                }
                waitingCamera = false
                AppState.enterSessionIfRecording()
            }
            else -> { delay(1000); countdown = c - 1 }
        }
    }

    // iOS 1:1 — 전체 화면 프리뷰 위에 오버레이 (헤더·방향 토글·점선 구도 가이드·체크리스트·시작 버튼)
    Box(Modifier.fillMaxSize().background(TL.ink)) {
        AndroidView(
            factory = { ctx ->
                androidx.camera.view.PreviewView(ctx).also { pv ->
                    CameraRecorder.previewUseCase.setSurfaceProvider(pv.surfaceProvider)
                }
            },
            modifier = Modifier.fillMaxSize(),
        )

        Column(
            Modifier.fillMaxSize().padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(18.dp))
            Text("거치 가이드", color = TL.amber, fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold, letterSpacing = 2.2.sp)
            Spacer(Modifier.height(4.dp))
            Text(pending.activityName, color = TL.paper, fontSize = 24.sp, fontWeight = FontWeight.Black)
            if (pending.scheduledAt != null) {
                Spacer(Modifier.height(4.dp))
                Text("${TimePolicy.START_WINDOW_MINUTES}분 안에 시작하지 않으면 노쇼 처리됩니다",
                    color = TL.rec, fontSize = 14.sp, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.height(16.dp))

            // 방향 토글 캡슐 + 카메라 전환 원형 버튼 (iOS 1:1)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Row(
                    Modifier.background(TL.ink.copy(alpha = 0.55f), CircleShape).padding(5.dp),
                ) {
                    listOf(true to "세로", false to "가로").forEach { (isPortrait, label) ->
                        val selected = portrait == isPortrait
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .background(if (selected) TL.paper else Color.Transparent, CircleShape)
                                .clickable { if (countdown == null) portrait = isPortrait }
                                .padding(horizontal = 20.dp, vertical = 11.dp),
                        ) {
                            androidx.compose.material3.Icon(
                                if (isPortrait) Lucide.Smartphone else Lucide.Tablet, null,
                                tint = if (selected) TL.ink else TL.paper,
                                modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(label, color = if (selected) TL.ink else TL.paper,
                                fontSize = 15.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                }
                Spacer(Modifier.width(10.dp))
                Box(
                    Modifier.size(48.dp).background(TL.ink.copy(alpha = 0.55f), CircleShape)
                        .clickable { if (countdown == null) CameraRecorder.flipCamera(context) },
                    contentAlignment = Alignment.Center,
                ) {
                    androidx.compose.material3.Icon(Lucide.SwitchCamera, "카메라 전환",
                        tint = TL.paper, modifier = Modifier.size(20.dp))
                }
            }
            Spacer(Modifier.height(20.dp))

            // 점선 구도 가이드 프레임 (iOS 1:1)
            Box(
                Modifier.fillMaxWidth(0.64f).weight(1f)
                    .drawBehind {
                        drawRoundRect(
                            color = Color.White.copy(alpha = 0.65f),
                            style = Stroke(
                                width = 2.dp.toPx(),
                                pathEffect = PathEffect.dashPathEffect(floatArrayOf(20f, 16f)),
                            ),
                            cornerRadius = CornerRadius(24.dp.toPx()),
                        )
                    },
                contentAlignment = Alignment.TopCenter,
            ) {
                Text("얼굴과 책상이 프레임 안에", color = Color.White.copy(alpha = 0.75f),
                    fontSize = 13.sp, modifier = Modifier.padding(top = 14.dp))
            }
            Spacer(Modifier.height(18.dp))

            // 체크리스트 2개 — 둘 다 체크해야 시작 가능 (iOS 1:1)
            MountCheckRow("거치대에 폰을 고정했어요", check1) { if (countdown == null) check1 = !check1 }
            Spacer(Modifier.height(10.dp))
            MountCheckRow("구도 안에 내가 보여요", check2) { if (countdown == null) check2 = !check2 }
            Spacer(Modifier.height(14.dp))

            TLPrimaryButton(
                if (countdown != null) "곧 시작합니다…" else "◉  촬영 시작",
                enabled = check1 && check2 && countdown == null,
            ) { countdown = 3 }
            Spacer(Modifier.height(8.dp))
            Text("취소하기", color = if (countdown == null) TL.paper.copy(alpha = 0.8f) else TL.faint,
                fontSize = 15.sp,
                modifier = Modifier.clickable(enabled = countdown == null) {
                    AppState.cancelMountGuide(pending)
                }.padding(8.dp))
            Spacer(Modifier.height(14.dp))
        }

        // 3-2-1 카운트다운 오버레이
        countdown?.let { c ->
            Box(Modifier.fillMaxSize().background(TL.ink.copy(alpha = 0.62f)),
                contentAlignment = Alignment.Center) {
                if (waitingCamera) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator(color = TL.rec)
                        Spacer(Modifier.height(10.dp))
                        Text("카메라 준비 중…", color = TL.paper, fontSize = 15.sp)
                    }
                } else {
                    Text(if (c == 0) "시작!" else "$c", color = TL.paper,
                        fontSize = 84.sp, fontWeight = FontWeight.Black)
                }
            }
        }
    }
}

/** 거치 가이드 체크리스트 행 — 원형 라디오 + 라벨 (iOS 1:1) */
@Composable
private fun MountCheckRow(label: String, checked: Boolean, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
            .background(TL.ink.copy(alpha = 0.6f), TL.cornerM)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 15.dp),
    ) {
        Box(
            Modifier.size(24.dp)
                .background(if (checked) TL.jade else Color.Transparent, CircleShape)
                .border(2.dp, if (checked) TL.jade else TL.muted, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (checked) {
                androidx.compose.material3.Icon(Lucide.Check, null,
                    tint = TL.ink, modifier = Modifier.size(15.dp))
            }
        }
        Spacer(Modifier.width(12.dp))
        Text(label, color = TL.paper, fontSize = 16.sp, fontWeight = FontWeight.Bold)
    }
}

/** 세션 하단 사각 버튼 — 아이콘 위 + 라벨 아래, 활성 시 종이색 (iOS 1:1) */
@Composable
private fun SessionSquareButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    active: Boolean,
    onClick: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier.size(86.dp)
            .background(if (active) TL.paper else TL.raised, TL.cornerM)
            .clickable(onClick = onClick),
    ) {
        androidx.compose.material3.Icon(icon, null,
            tint = if (active) TL.ink else TL.paper, modifier = Modifier.size(24.dp))
        Spacer(Modifier.height(6.dp))
        Text(label, color = if (active) TL.ink else TL.muted,
            fontSize = 12.sp, fontWeight = FontWeight.Bold)
    }
}

// MARK: 세션 화면 — 타이머·자리비움 배너(n/3)·긴급 용무·브레이크 오버레이

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionScreen() {
    val context = LocalContext.current
    val phase by SessionEngine.phase.collectAsStateWithLifecycle()
    val recorded by SessionEngine.recordedSeconds.collectAsStateWithLifecycle()
    val budget by SessionEngine.breakBudgetRemaining.collectAsStateWithLifecycle()
    val absenceWarning by SessionEngine.absenceWarning.collectAsStateWithLifecycle()
    val episodes by SessionEngine.absenceEpisodeCount.collectAsStateWithLifecycle()
    var showEmergency by remember { mutableStateOf(false) }
    var emergencyReason by remember { mutableStateOf("") }

    val s = SessionEngine.currentSession
    val target = s?.targetSeconds ?: 1
    val intensity = s?.intensity ?: Intensity.SPICY

    // 촬영 방향대로 화면 회전 잠금 — 가로 선택 시 세션 화면도 가로 (iOS 동일)
    val portraitSession by CameraRecorder.portraitSession.collectAsStateWithLifecycle()
    val activity = context as? android.app.Activity
    DisposableEffect(portraitSession) {
        activity?.requestedOrientation = if (portraitSession)
            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        else android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        onDispose {
            activity?.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
    }
    var muted by remember { mutableStateOf(AlarmScheduler.sessionMuted) }

    // 공용 조각 — 프리뷰 카드(가용 높이에 맞춰 축소, 버튼 간섭 없음)와 버튼 행
    val previewCard: @Composable (Float) -> Unit = { aspect ->
        Box(
            Modifier.fillMaxHeight()
                .aspectRatio(aspect, matchHeightConstraintsFirst = true)
                .clip(TL.cornerL).background(TL.surface),
        ) {
            AndroidView(
                factory = { ctx ->
                    androidx.camera.view.PreviewView(ctx).also { pv ->
                        CameraRecorder.previewUseCase.setSurfaceProvider(pv.surfaceProvider)
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(10.dp)
                    .background(TL.ink.copy(alpha = 0.55f), CircleShape)
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            ) {
                Box(Modifier.size(8.dp).background(TL.rec, CircleShape))
                Spacer(Modifier.width(6.dp))
                Text("REC", color = TL.paper, fontSize = 12.sp, fontWeight = FontWeight.Black)
            }
        }
    }
    val buttonsRow: @Composable () -> Unit = {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            SessionSquareButton(
                icon = Lucide.BellOff,
                label = if (muted) "차단 중" else "알림 허용",
                active = muted,
            ) {
                if (muted) {
                    // 차단 해제 — 앱 알림음 + 시스템 방해 금지 모두 원복
                    muted = false
                    AlarmScheduler.sessionMuted = false
                    AlarmScheduler.restoreDndIfNeeded(context)
                } else {
                    // 차단 켜기 — 권한 있으면 시스템 방해 금지까지, 없으면 권한 화면으로
                    muted = true
                    AlarmScheduler.sessionMuted = true
                    if (AlarmScheduler.hasDndAccess(context)) {
                        AlarmScheduler.setDnd(context, true)
                    } else {
                        AlarmScheduler.openDndAccessSettings(context)
                    }
                }
            }
            SessionSquareButton(icon = Lucide.Siren, label = "긴급중단", active = false) {
                if (intensity == Intensity.SPICY && phase == SessionEngine.Phase.Recording) {
                    SessionEngine.startBreak()
                } else {
                    showEmergency = true
                }
            }
        }
    }

    Box(Modifier.fillMaxSize().background(TL.ink)) {
        if (portraitSession) {
            // 세로 — 이름/다이얼/타이머/프리뷰/버튼 수직 배치 (iOS 1:1)
            Column(
                Modifier.fillMaxSize().padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.height(14.dp))
                Text(s?.activityName ?: "", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.height(16.dp))
                FocusDial(
                    remaining = ((target - recorded).toFloat() / target).coerceIn(0f, 1f),
                    totalMinutes = target / 60,
                    modifier = Modifier.size(280.dp),
                )
                Spacer(Modifier.height(12.dp))
                Text(TLFormat.hms((target - recorded).toLong().coerceAtLeast(0)),
                    color = TL.paper, fontSize = 48.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.height(12.dp))
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    previewCard(9f / 16f)
                }
                Spacer(Modifier.height(14.dp))
                buttonsRow()
                Spacer(Modifier.height(16.dp))
            }
        } else {
            // 가로 — 왼쪽 다이얼/타이머, 오른쪽 프리뷰/버튼 나란히
            Row(
                Modifier.fillMaxSize().padding(20.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(s?.activityName ?: "", color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
                    Spacer(Modifier.height(10.dp))
                    FocusDial(
                        remaining = ((target - recorded).toFloat() / target).coerceIn(0f, 1f),
                        totalMinutes = target / 60,
                        modifier = Modifier.size(190.dp),
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(TLFormat.hms((target - recorded).toLong().coerceAtLeast(0)),
                        color = TL.paper, fontSize = 38.sp, fontWeight = FontWeight.Black)
                }
                Spacer(Modifier.width(16.dp))
                Column(
                    Modifier.weight(1.2f).fillMaxHeight(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Box(Modifier.weight(1f).padding(vertical = 6.dp), contentAlignment = Alignment.Center) {
                        previewCard(16f / 9f)
                    }
                    buttonsRow()
                    Spacer(Modifier.height(6.dp))
                }
            }
        }

        // 자리비움 경고 배너 — n/3, 4번째는 배너 없이 즉시 처리됨
        if (absenceWarning) {
            Column(Modifier.fillMaxWidth().padding(top = 10.dp, start = 20.dp, end = 20.dp)) {
                Column(
                    Modifier.fillMaxWidth().background(TL.amber, TL.cornerM).padding(12.dp),
                ) {
                    Text("자리비움 감지 · ${minOf(episodes, AbsencePolicy.MAX_EPISODES)}/${AbsencePolicy.MAX_EPISODES}",
                        color = TL.ink, fontSize = 14.sp, fontWeight = FontWeight.Black)
                    Text(
                        when {
                            intensity == Intensity.INSANE && episodes >= AbsencePolicy.MAX_EPISODES ->
                                "마지막 경고 — 다음 자리비움은 알림 없이 즉시 실패합니다"
                            intensity == Intensity.INSANE ->
                                "2분 안에 돌아오세요 — 초과 시 즉시 실패 (경고는 ${AbsencePolicy.MAX_EPISODES}번까지)"
                            episodes >= AbsencePolicy.MAX_EPISODES ->
                                "마지막 경고 — 다음 자리비움은 알림 없이 자동 긴급 중단됩니다"
                            else ->
                                "2분 안에 돌아오세요 — 초과 시 자동 긴급 중단 (경고는 ${AbsencePolicy.MAX_EPISODES}번까지)"
                        },
                        color = TL.ink.copy(alpha = 0.85f), fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }

        // 통화 일시정지 오버레이
        if (phase == SessionEngine.Phase.PausedForCall) {
            Box(Modifier.fillMaxSize().background(TL.ink.copy(alpha = 0.88f)), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("📞", fontSize = 40.sp)
                    Text("통화 중 — 일시정지", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
                    Text("벌점 없이 멈춰 있어요. 통화가 끝나면 자동 재개됩니다.",
                        color = TL.muted, fontSize = 13.sp, textAlign = TextAlign.Center)
                }
            }
        }

        // 긴급 용무 브레이크 오버레이 — 재촬영 카운트다운
        (phase as? SessionEngine.Phase.PausedForBreak)?.let { p ->
            var left by remember(p.deadline) { mutableIntStateOf(0) }
            LaunchedEffect(p.deadline) {
                while (true) {
                    left = ((p.deadline - System.currentTimeMillis()) / 1000).toInt().coerceAtLeast(0)
                    delay(500)
                }
            }
            // iOS 브레이크 오버레이 1:1 — 앰버 링 카운트다운 + 하단 재촬영/포기 버튼
            Box(Modifier.fillMaxSize().background(TL.ink.copy(alpha = 0.96f))) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
                ) {
                    Spacer(Modifier.height(70.dp))
                    Text("촬영 일시중단", color = TL.amber, fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold, letterSpacing = 2.2.sp)
                    Spacer(Modifier.height(6.dp))
                    Text("긴급 용무 중", color = TL.paper, fontSize = 28.sp, fontWeight = FontWeight.Black)
                    Spacer(Modifier.height(36.dp))
                    // 두꺼운 앰버 링 + 중앙 카운트다운
                    Box(
                        Modifier.size(300.dp)
                            .border(14.dp, TL.amber, androidx.compose.foundation.shape.CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(TLFormat.hms(left.toLong()), color = TL.paper,
                                fontSize = 56.sp, fontWeight = FontWeight.Black)
                            Text("안에 재촬영을 시작하세요", color = TL.muted, fontSize = 13.sp)
                        }
                    }
                    Spacer(Modifier.height(32.dp))
                    Text("총 ${TimePolicy.RESUME_WINDOW_MINUTES}분 안에 재촬영을 시작하면 벌점이 없습니다.\n시간이 지나면 벌점과 함께 세션이 종료됩니다.",
                        color = TL.muted, fontSize = 14.sp, textAlign = TextAlign.Center, lineHeight = 21.sp)
                    Spacer(Modifier.height(12.dp))
                    Text("긴급 용무 시간은 리셋되지 않고, 계속 이어집니다",
                        color = TL.amber, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.weight(1f))
                    TLPrimaryButton("◉  지금 재촬영 시작") { SessionEngine.resumeFromBreak() }
                    Spacer(Modifier.height(10.dp))
                    TLGhostButton("세션 포기 — 벌점 받기", tint = TL.muted) { showEmergency = true }
                    Spacer(Modifier.height(28.dp))
                }
            }
        }
    }

    if (showEmergency) {
        ModalBottomSheet(onDismissRequest = { showEmergency = false }, containerColor = TL.surface) {
            Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp)) {
                Text("세션을 포기할까요?", color = TL.paper, fontSize = 19.sp, fontWeight = FontWeight.Black)
                Text("긴급 벌점이 부과되고 촬영분은 보존됩니다.", color = TL.muted, fontSize = 13.sp)
                Spacer(Modifier.height(14.dp))
                OutlinedTextField(emergencyReason, { emergencyReason = it }, modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("사유", color = TL.faint) },
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = TL.paper, unfocusedTextColor = TL.paper,
                        focusedBorderColor = TL.rec, unfocusedBorderColor = TL.hairline, cursorColor = TL.rec))
                Spacer(Modifier.height(14.dp))
                TLPrimaryButton("긴급 종료 확정", enabled = emergencyReason.isNotBlank()) {
                    showEmergency = false
                    SessionEngine.emergencyEnd(emergencyReason.trim())
                }
            }
        }
    }
}

// MARK: 결과 화면 — 저장/삭제 + 성공 팝 + 보너스 배지·파티클

@Composable
fun SessionResultScreen() {
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val s by SessionEngine.lastFinishedSession.collectAsStateWithLifecycle()
    val slotBonus by SessionEngine.lastSlotBonus.collectAsStateWithLifecycle()
    val unlockBonus by SessionEngine.lastUnlockBonus.collectAsStateWithLifecycle()
    val session = s ?: return
    val outcome = session.outcome ?: return
    var pop by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { pop = true }
    val scale by animateFloatAsState(if (pop) 1f else 0.45f, tween(500), label = "pop")

    var showPlayer by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(TL.ink)) {
        // 스크롤 영역 — 화면이 작아도 하단 버튼은 항상 보인다
        Column(
            Modifier.weight(1f).fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(28.dp))
            Box(contentAlignment = Alignment.Center) {
                Image(
                    painterResource(if (outcome.isSuccess) R.drawable.moti_smile else R.drawable.moti_angry),
                    null, Modifier.size(96.dp).scale(scale),
                )
                if (outcome.isSuccess && (slotBonus != null || unlockBonus != null)) ConfettiBurst()
            }
            Spacer(Modifier.height(12.dp))
            Text(if (outcome == SessionOutcome.EMERGENCY) "긴급 종료됨" else outcome.title,
                color = TL.paper, fontSize = 30.sp, fontWeight = FontWeight.Black)
            Text(session.activityName, color = TL.muted, fontSize = 15.sp)
            Spacer(Modifier.height(12.dp))
            Text("순수 촬영 ${TLFormat.hms(session.recordedSeconds.toLong())} / 목표 ${TLFormat.hms(session.targetSeconds.toLong())}",
                color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.height(12.dp))
            ScoreRules.points(outcome, session.intensity, session.targetSeconds / 60)?.let { (_, pts) ->
                Text(
                    if (pts >= 0) "+${pts}점 상점" else "${pts}점 벌점",
                    color = if (pts >= 0) TL.jade else TL.rec,
                    fontSize = 15.sp, fontWeight = FontWeight.Black,
                    modifier = Modifier.background(TL.surface, TL.cornerS)
                        .border(1.dp, TL.hairline, TL.cornerS)
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                )
            } ?: Text("벌점 없음", color = TL.amber, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)

            slotBonus?.let { (days, pts) ->
                Spacer(Modifier.height(10.dp))
                Text("🎉 연속 ${days}일 달성! 보너스 상점 +$pts", color = TL.ink,
                    fontSize = 13.sp, fontWeight = FontWeight.Black,
                    modifier = Modifier.background(TL.amber, CircleShape)
                        .padding(horizontal = 14.dp, vertical = 8.dp))
            }
            unlockBonus?.let { pts ->
                Spacer(Modifier.height(8.dp))
                Text("🔥 미친 매운맛 잠금 해제! 보너스 상점 +$pts", color = TL.paper,
                    fontSize = 13.sp, fontWeight = FontWeight.Black,
                    modifier = Modifier.background(TL.rec, CircleShape)
                        .padding(horizontal = 14.dp, vertical = 8.dp))
            }

            // 타임랩스 미리보기 카드 — 탭하면 인앱 재생 (iOS 1:1)
            session.videoFileName?.let {
                Spacer(Modifier.height(18.dp))
                TLCard(raised = true) {
                    TLEyebrow("타임랩스 미리보기")
                    val thumb = session.thumbnailFileName?.let { name ->
                        remember(name) {
                            runCatching {
                                android.graphics.BitmapFactory.decodeFile(
                                    File(CameraRecorder.sessionDir(context), name).absolutePath)
                            }.getOrNull()
                        }
                    }
                    Box(
                        Modifier.fillMaxWidth(0.55f).aspectRatio(3f / 4f)
                            .align(Alignment.CenterHorizontally)
                            .clip(TL.cornerM).background(TL.ink)
                            .clickable { showPlayer = true },
                    ) {
                        thumb?.let {
                            Image(it.asImageBitmap(), null, Modifier.fillMaxSize(),
                                contentScale = androidx.compose.ui.layout.ContentScale.Crop)
                        }
                        Box(Modifier.align(Alignment.Center)
                            .size(58.dp).background(Color.White, CircleShape),
                            contentAlignment = Alignment.Center) {
                            Text("▶", color = TL.ink, fontSize = 20.sp)
                        }
                        // 우측 상단 다운로드 버튼 — 갤러리 저장 (iOS 1:1)
                        // 저장 중에는 로딩 서클로 바뀌고 탭이 막혀 연타를 방지한다
                        Box(
                            Modifier.align(Alignment.TopEnd).padding(10.dp)
                                .size(44.dp)
                                .background(if (saved) TL.jade else Color.White, CircleShape)
                                .clickable(enabled = !saving && !saved) {
                                    session.videoFileName?.let { fileName ->
                                        saving = true
                                        scope.launch(Dispatchers.IO) {
                                            val ok = saveToGallery(context,
                                                File(CameraRecorder.sessionDir(context), fileName))
                                            withContext(Dispatchers.Main) {
                                                saving = false
                                                if (ok) saved = true
                                                android.widget.Toast.makeText(context,
                                                    if (ok) "갤러리에 저장했어요 (Movies/AngryMoti)"
                                                    else "저장에 실패했어요 — 다시 시도해주세요",
                                                    android.widget.Toast.LENGTH_SHORT).show()
                                            }
                                        }
                                    }
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            if (saving) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(19.dp),
                                    color = TL.ink, trackColor = Color.Transparent,
                                    strokeWidth = 2.4.dp,
                                    strokeCap = androidx.compose.ui.graphics.StrokeCap.Round)
                            } else {
                                androidx.compose.material3.Icon(
                                    if (saved) Lucide.Check else Lucide.ArrowDownToLine,
                                    "갤러리에 저장",
                                    tint = TL.ink,
                                    modifier = Modifier.size(21.dp))
                            }
                        }
                    }
                    Spacer(Modifier.height(10.dp))
                    Text("저장하지 않으면 닫을 때 삭제됩니다. 기록·점수는 유지됩니다.",
                        color = TL.faint, fontSize = 12.sp)
                }
            }
            Spacer(Modifier.height(16.dp))
        }

        // 하단 고정 버튼 — 저장은 미리보기 우측 상단 다운로드 버튼이 담당 (iOS 1:1)
        Column(Modifier.padding(horizontal = 24.dp)) {
            TLPrimaryButton("종료", tint = TL.amber) {
                CameraRecorder.deleteFiles(context, session.videoFileName, session.thumbnailFileName)
                AppState.dismissResult(context)
            }
            Spacer(Modifier.height(18.dp))
        }
    }

    // 인앱 타임랩스 재생 — 화면 탭하면 닫힘
    if (showPlayer) session.videoFileName?.let { fileName ->
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { showPlayer = false },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Box(
                Modifier.fillMaxSize().background(Color.Black)
                    .clickable { showPlayer = false },
                contentAlignment = Alignment.Center,
            ) {
                AndroidView(
                    factory = { ctx ->
                        android.widget.VideoView(ctx).apply {
                            setVideoPath(File(CameraRecorder.sessionDir(ctx), fileName).absolutePath)
                            setOnPreparedListener { mp -> mp.isLooping = true; start() }
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text("탭해서 닫기", color = Color.White.copy(alpha = 0.7f), fontSize = 13.sp,
                    modifier = Modifier.align(Alignment.TopCenter).padding(top = 48.dp))
            }
        }
    }
}

private fun saveToGallery(context: android.content.Context, file: File): Boolean {
    if (!file.exists()) return false
    return runCatching {
        val values = android.content.ContentValues().apply {
            put(android.provider.MediaStore.Video.Media.DISPLAY_NAME, "AngryMoti_${System.currentTimeMillis()}.mp4")
            put(android.provider.MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(android.provider.MediaStore.Video.Media.RELATIVE_PATH, "Movies/AngryMoti")
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
            ?: return false
        resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
            ?: return false
        true
    }.getOrElse { android.util.Log.e("AngryMoti", "saveToGallery failed", it); false }
}

// MARK: 콘페티 — 결정적 의사난수 30파티클 (iOS ConfettiBurst 대응)

@Composable
fun ConfettiBurst(count: Int = 30) {
    var fired by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { fired = true }
    val t by animateFloatAsState(if (fired) 1f else 0f, tween(1100), label = "confetti")
    val palette = listOf(TL.jade, TL.amber, TL.rec, TL.paper)

    Box(Modifier.size(220.dp)) {
        for (i in 0 until count) {
            fun rand(salt: Double) =
                kotlin.math.abs(kotlin.math.sin(i * 12.9898 + salt * 78.233)).mod(1.0)
            val angle = (i.toDouble() / count) * 2 * Math.PI + rand(1.0) * 0.5
            val distance = 70 + rand(2.0) * 90
            val size = (5 + rand(3.0) * 6).dp
            val color = palette[i % palette.size]
            Box(
                Modifier
                    .align(Alignment.Center)
                    .graphicsLayer {
                        translationX = (kotlin.math.cos(angle) * distance * t).toFloat() * density
                        translationY = ((kotlin.math.sin(angle) * distance + 18) * t).toFloat() * density
                        alpha = 1f - t
                        scaleX = 1f - 0.45f * t; scaleY = 1f - 0.45f * t
                    }
                    .size(size)
                    .background(color, CircleShape)
            )
        }
    }
}
