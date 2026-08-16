package com.singlemarks.angrymoti.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.displayCutoutPadding
import androidx.compose.foundation.layout.statusBarsPadding
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
import androidx.compose.runtime.key
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
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalConfiguration
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
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.models.AbsencePolicy
import com.singlemarks.angrymoti.models.CancelReason
import com.singlemarks.angrymoti.models.CanonicalTag
import com.singlemarks.angrymoti.models.Intensity
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.SessionOutcome
import com.singlemarks.angrymoti.models.TimePolicy
import com.singlemarks.angrymoti.services.AlarmScheduler
import com.singlemarks.angrymoti.services.CameraRecorder
import com.singlemarks.angrymoti.services.Permissions
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
    // 뒤로가기로 알람 화면을 이탈하지 못하게 — 알람 해제는 촬영 시작뿐이다 (iOS 1:1)
    androidx.activity.compose.BackHandler { }
    val db = remember { AppDb.get(context) }
    var reservation by remember { mutableStateOf<com.singlemarks.angrymoti.data.Reservation?>(null) }
    var showCancel by remember { mutableStateOf(false) }
    // 취소 사유 — 프리셋 선택 + '기타'일 때만 직접 입력 (iOS CancelReasonSheet 1:1)
    var selectedReason by remember { mutableStateOf<String?>(null) }
    var customReason by remember { mutableStateOf("") }
    var remaining by remember { mutableIntStateOf(TimePolicy.START_WINDOW_SECONDS.toInt()) }

    LaunchedEffect(reservationId) {
        withContext(Dispatchers.IO) { reservation = db.reservations().byId(reservationId) }
        // 예약을 못 찾으면(삭제·비활성) 검은 화면에서 벨소리만 나는 상태가 된다 —
        // 소리·알림을 정리하고 조용히 홈으로 돌려보낸다.
        val r0 = reservation
        if (r0 == null || !r0.isActive) {
            AlarmScheduler.stopAlarmSound(context)
            AlarmScheduler.cancelAlarmNotification(context, reservationId)
            AppState.route.value = com.singlemarks.angrymoti.Route.None
            return@LaunchedEffect
        }
        while (true) {
            val left = (fireAt + TimePolicy.START_WINDOW_SECONDS * 1000 - System.currentTimeMillis()) / 1000
            remaining = left.toInt().coerceAtLeast(0)
            if (left <= 0) {
                // 10분 창 종료 — 노쇼는 스위퍼가 기록. 알람만 정리하고 홈으로.
                AlarmScheduler.stopAlarmSound(context)
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
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.alarm_time_title), color = TL.rec, fontSize = 34.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(10.dp))
        Text(r.name, color = TL.paper, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Text("${TLFormat.durationLabel(r.durationMinutes)} · ${CanonicalTag.label(r.tag)}", color = TL.muted, fontSize = 15.sp)
        Spacer(Modifier.height(30.dp))
        Text(TLFormat.hms(remaining.toLong()), color = TL.amber, fontSize = 44.sp, fontWeight = FontWeight.Black)
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.no_show_if_not_started), color = TL.muted, fontSize = 13.sp)
        Spacer(Modifier.weight(1f))
        TLPrimaryButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.get_ready_short)) {
            AppState.beginRecording(context, PendingSession(
                activityName = r.name, tag = r.tag, targetSeconds = r.durationMinutes * 60,
                reservationId = r.id, scheduledAt = fireAt,
                intensityOverrideRaw = r.intensityOverrideRaw,
            ))
        }
        Spacer(Modifier.height(12.dp))
        // 벌점 액수는 시트 안에서 사유와 함께 안내한다 — 여기서도 적으면 같은 숫자가
        // 두 번 나온다 (iOS는 진입 버튼에 숫자를 두지 않는다).
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.cancel_schedule), color = TL.muted, fontSize = 14.sp,
            modifier = Modifier.clickable {
                // 취소를 고민하는 동안에는 알람을 멈춘다 — 시트 위에서 계속 울리면
                // 사유를 입력할 수 없다. '돌아가기'(시트 닫기)면 다시 울린다 (iOS 1:1).
                AlarmScheduler.stopAlarmSound(context)
                // 사유 선택은 매번 새로 — iOS는 시트를 열 때마다 @State가 초기화된다.
                selectedReason = null
                customReason = ""
                showCancel = true
            }.padding(8.dp))
        Spacer(Modifier.height(24.dp))
    }

    if (showCancel) {
        // 취소를 접고 돌아왔으니 알람 재개 (시작 창이 아직 남아 있는 동안만)
        val resume = {
            showCancel = false
            if (fireAt + TimePolicy.START_WINDOW_SECONDS * 1000 > System.currentTimeMillis()) {
                AlarmScheduler.startAlarmSound(context)
            }
        }
        ModalBottomSheet(onDismissRequest = resume, containerColor = TL.ink) {
            // 확정 가능한 최종 사유 — '기타'는 직접 입력이 있어야 확정된다 (iOS finalReason 1:1)
            val finalReason: String? = selectedReason?.let { sel ->
                if (sel == CANCEL_REASON_ETC) customReason.trim().ifBlank { null } else sel
            }
            Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 20.dp)) {
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.select_cancel_reason), color = TL.paper, fontSize = 20.sp,
                    fontWeight = FontWeight.Black)

                Spacer(Modifier.height(16.dp))
                CANCEL_REASON_PRESETS.forEach { preset ->
                    CancelReasonRow(preset, selectedReason == preset) { selectedReason = preset }
                    Spacer(Modifier.height(8.dp))
                }
                if (selectedReason == CANCEL_REASON_ETC) {
                    OutlinedTextField(customReason, { customReason = it },
                        modifier = Modifier.fillMaxWidth(), singleLine = true,
                        placeholder = { Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.enter_reason), color = TL.faint) },
                        shape = TL.cornerM,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedContainerColor = TL.surface, unfocusedContainerColor = TL.surface,
                            focusedTextColor = TL.paper, unfocusedTextColor = TL.paper,
                            focusedBorderColor = TL.amber.copy(alpha = 0.6f),
                            unfocusedBorderColor = TL.amber.copy(alpha = 0.6f),
                            cursorColor = TL.rec))
                }

                Spacer(Modifier.height(16.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    androidx.compose.material3.Icon(AppIcon.Siren, null, tint = TL.rec,
                        modifier = Modifier.size(15.dp))
                    Spacer(Modifier.width(6.dp))
                    // 안내 점수는 실제 부과 경로(cancelSchedule)와 같은 '활동별 강도'로 계산한다 —
                    // 전역 강도로 계산하면 미친맛 활동에서 안내와 실제가 어긋난다 (iOS 1:1).
                    val penalty = ScoreRules.points(SessionOutcome.EMERGENCY,
                        r.intensityOverride ?: AppState.intensity.value, r.durationMinutes)?.second ?: -10
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.cancel_penalty_note, penalty),
                        color = TL.rec, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }

                Spacer(Modifier.height(24.dp))
                TLPrimaryButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.confirm_penalty_cancel), enabled = finalReason != null) {
                    finalReason?.let { AppState.cancelSchedule(context, r, fireAt, it) }
                }
                Spacer(Modifier.height(10.dp))
                TLGhostButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.go_back_resume_alarm), tint = TL.muted) { resume() }
            }
        }
    }
}

// 취소 사유 프리셋 — iOS AlarmView.CancelReasonSheet와 문구·순서 동일
// 게터인 이유: 상수로 캡처하면 로케일 전환 후 비교(센티널)와 표시가 서로 다른 언어 값이 된다
private val CANCEL_REASON_ETC: String get() = com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.other_etc)
// 정본 코드로 저장 — 표시 문구는 CancelReason.label() ('기타'는 UI 전용 항목)
private val CANCEL_REASON_PRESETS: List<String> get() = CancelReason.presets + CANCEL_REASON_ETC

/** 취소 사유 한 줄 — 선택 시 채워진 체크 원 + 밝은 서피스 (iOS reasonRow 1:1) */
@Composable
private fun CancelReasonRow(reason: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth()
            .background(if (selected) TL.raised else TL.surface, TL.cornerM)
            .clickable(onClick = onClick)
            .padding(13.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        androidx.compose.material3.Icon(
            if (selected) AppIcon.CheckCircle else AppIcon.CircleEmpty, null,
            tint = if (selected) TL.rec else TL.faint, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(12.dp))
        Text(CancelReason.label(reason), color = TL.paper, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)   // 정본 코드 → 표시 문구 ('기타'는 그대로)
    }
}

// MARK: 거치 가이드 — 방향 선택·프리뷰·3-2-1 카운트다운 (녹화는 카운트다운과 병렬 시작)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MountGuideScreen(pending: PendingSession) {
    val context = LocalContext.current
    // 뒤로가기 차단 — 취소는 화면의 '취소하기' 버튼(정리 파이프라인 포함)으로만 (iOS 1:1)
    androidx.activity.compose.BackHandler { }
    var portrait by remember { mutableStateOf(true) }
    var check1 by remember { mutableStateOf(false) }   // 거치대에 폰 고정
    var check2 by remember { mutableStateOf(false) }   // 구도 안에 내가 보임
    // rememberSaveable — 카운트다운 중 다크모드 전환 등으로 재생성되면 remember는 null로
    // 초기화되어 enterSessionIfRecording()을 부를 주체가 사라진다: 녹화는 도는데 거치
    // 가이드 화면에 영영 멈춘다. 복원하면 LaunchedEffect(countdown)가 이어서 진행한다.
    var countdown by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf<Int?>(null) }
    var waitingCamera by remember { mutableStateOf(false) }
    // 시작 창 카운트다운 — 구도 화면에도 마감이 있어야 한다. 예전엔 여기 들어오면 시간
    // 제한이 사라져 늦게 시작해도 벌점이 없었다 (iOS와 동일 로직).
    // rememberSaveable — 다크모드 전환 등으로 Activity가 재생성돼도 '이미 시작했다'는
    // 사실을 잃지 않는다. 잃으면 녹화 중인데 마감 처리로 홈에 튕긴다 (iOS 사고 유형).
    var started by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    var nowTick by remember { mutableStateOf(System.currentTimeMillis()) }
    // 카메라 권한 지연 요청 — 온보딩에서 건너뛴 사용자는 여기가 유일한 구제 지점이다.
    // 두 번 거부해 시스템 창이 더는 안 뜨는 상태(BLOCKED)면 설정으로 보내야 한다.
    var showCameraBlocked by remember { mutableStateOf(false) }
    val cameraPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            CameraRecorder.startPreview(context)
        } else {
            val act = context as? android.app.Activity
            // 방금 거부(한 번째)는 조용히 둔다 — 다음 시도에서 창이 한 번 더 뜬다.
            if (act != null && Permissions.isBlocked(act, Permissions.CAMERA)) {
                showCameraBlocked = true
            }
        }
    }
    val requestCamera: () -> Unit = {
        val act = context as? android.app.Activity
        if (act != null && Permissions.isBlocked(act, Permissions.CAMERA)) {
            showCameraBlocked = true
        } else {
            Permissions.markAsked(Permissions.CAMERA)
            cameraPermissionLauncher.launch(Permissions.CAMERA)
        }
    }
    // 남은 초 — 예약이 아닌 '지금 바로 시작'은 마감이 없다(null)
    val remainingSeconds: Int? = pending.scheduledAt?.let { sched ->
        (((sched + TimePolicy.START_WINDOW_SECONDS * 1000 - nowTick) + 999) / 1000)
            .coerceAtLeast(0).toInt()
    }
    LaunchedEffect(pending.scheduledAt) {
        if (pending.scheduledAt == null) return@LaunchedEffect
        while (true) {
            delay(1000)
            nowTick = System.currentTimeMillis()
            // 이중 방어(started + countdown == null) — 촬영으로 넘어간 뒤에는 마감 처리 금지.
            // 하나에만 의존했다가 녹화 시작 후 홈으로 튕기던 사고가 iOS에서 실제로 있었다.
            val remaining = (pending.scheduledAt + TimePolicy.START_WINDOW_SECONDS * 1000 -
                System.currentTimeMillis())
            if (!started && countdown == null && remaining <= 0) {
                AlarmScheduler.stopAlarmSound(context)
                AlarmScheduler.cancelAlarmNotification(context)
                AppState.route.value = com.singlemarks.angrymoti.Route.None   // 노쇼는 스위퍼가 기록한다
                break
            }
        }
    }

    LaunchedEffect(Unit) {
        // 촬영 진입 시 잠금이 남아 있으면 카메라가 안 열린다 — 여기서 한 번 더 해제 요청
        val activityForKeyguard = context as? android.app.Activity
        val km = context.getSystemService(android.app.KeyguardManager::class.java)
        if (activityForKeyguard != null && km?.isKeyguardLocked == true) {
            km.requestDismissKeyguard(activityForKeyguard, object :
                android.app.KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() {
                    CameraRecorder.retryPreviewIfNeeded(context)   // 잠금 풀린 뒤 카메라 재바인딩
                }
            })
        }
        // 권한이 없으면 startPreview는 조용히 실패해 프리뷰가 검은 화면으로 남는다.
        // 화면에 들어온 시점에 먼저 권한을 해결하고 그 결과로 프리뷰를 켠다 (iOS 1:1).
        if (Permissions.cameraGranted(context)) CameraRecorder.startPreview(context)
        else requestCamera()
    }

    // 가로 선택 시 화면도 가로로 잠가 iOS 분할 레이아웃과 동일하게 (세로면 세로 잠금)
    val activity = context as? android.app.Activity
    DisposableEffect(portrait) {
        activity?.requestedOrientation = if (portrait)
            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        else android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        // 취소하고 화면을 뜨면 세로로 복귀 — 촬영으로 이어지면 SessionScreen이 즉시 다시 잠근다
        onDispose { activity?.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
    }

    // 실제 디스플레이 회전이 바뀔 때마다(가로 잠금이 실제로 적용된 뒤 포함) 녹화 프레임 회전을 맞춘다.
    // 이 값이 없으면 가로로 찍어도 프레임이 세로로 세워져 결과물이 90도 돌아간다.
    val configuration = LocalConfiguration.current
    LaunchedEffect(configuration.orientation, portrait) {
        val rotation = activity?.let { act ->
            if (android.os.Build.VERSION.SDK_INT >= 30) act.display?.rotation
            else @Suppress("DEPRECATION") act.windowManager.defaultDisplay.rotation
        } ?: android.view.Surface.ROTATION_0
        CameraRecorder.setAnalysisRotation(rotation)
    }

    LaunchedEffect(countdown) {
        if (countdown == 3) {
            // 녹화 직전, 지금 화면 회전을 프레임 회전 기준으로 확정 (가로 결과물이 세로로 돌아가는 것 방지)
            val rotation = activity?.let { act ->
                if (android.os.Build.VERSION.SDK_INT >= 30) act.display?.rotation
                else @Suppress("DEPRECATION") act.windowManager.defaultDisplay.rotation
            } ?: android.view.Surface.ROTATION_0
            CameraRecorder.setAnalysisRotation(rotation)
            started = true   // 마감 처리 중단 — 이미 시작했다
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

    // 공용 조각 — 세로/가로 레이아웃이 함께 쓴다
    val previewView: @Composable (Modifier) -> Unit = { mod ->
        AndroidView(
            factory = { ctx ->
                androidx.camera.view.PreviewView(ctx).also { pv ->
                    CameraRecorder.previewUseCase.setSurfaceProvider(pv.surfaceProvider)
                }
            },
            modifier = mod,
        )
    }
    // 점선 구도 가이드 — 실제 촬영은 '전체 화면'이므로 프레임도 화면의 ~80%를 차지하도록 크게
    // 그린다(작은 중앙 박스 ✕). 영상 비율(세로 9:16 / 가로 16:9)에 맞춰 잘림 없이 중앙 배치하고,
    // 전체 화면 위에 겹쳐 얹는다. 얇은 점선이라 세로에선 컨트롤 위(앞), 가로에선 패널 뒤로 둔다.
    val dashedGuideOverlay: @Composable () -> Unit = {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val ratio = if (portrait) 9f / 16f else 16f / 9f   // 가로/세로
            val byWidthW = maxWidth * 0.8f
            val byWidthH = byWidthW / ratio
            val maxH = maxHeight * 0.88f
            val fitsWidth = byWidthH <= maxH
            val fw = if (fitsWidth) byWidthW else maxH * ratio
            val fh = if (fitsWidth) byWidthH else maxH
            Box(
                Modifier.align(Alignment.Center).size(fw, fh).drawBehind {
                    drawRoundRect(
                        color = Color.White.copy(alpha = 0.5f),
                        style = Stroke(
                            width = 2.dp.toPx(),
                            pathEffect = PathEffect.dashPathEffect(floatArrayOf(20f, 16f)),
                        ),
                        cornerRadius = CornerRadius(24.dp.toPx()),
                    )
                },
            )   // 안내 문구는 세로=아이콘 아래, 가로=좌상단으로 각 레이아웃이 직접 배치한다.
        }
    }
    val orientationRow: @Composable () -> Unit = {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.background(TL.ink.copy(alpha = 0.55f), CircleShape).padding(5.dp)) {
                listOf(true to androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.portrait), false to androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.landscape)).forEach { (isPortrait, label) ->
                    val selected = portrait == isPortrait
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .background(if (selected) TL.paper else Color.Transparent, CircleShape)
                            .clickable { if (countdown == null) portrait = isPortrait }
                            .padding(horizontal = 20.dp, vertical = 11.dp),
                    ) {
                        androidx.compose.material3.Icon(
                            if (isPortrait) AppIcon.Smartphone else AppIcon.Tablet, null,
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
                androidx.compose.material3.Icon(AppIcon.SwitchCamera, androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.switch_camera),
                    tint = TL.paper, modifier = Modifier.size(20.dp))
            }
        }
    }
    // compact = 가로용 축소 타이포 (한 화면에 담기 위한 리밸런싱)
    val header: @Composable (Boolean) -> Unit = { compact ->
        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.setup_guide), color = TL.amber, fontSize = if (compact) 12.sp else 13.sp,
            fontWeight = FontWeight.SemiBold, letterSpacing = 2.2.sp)
        Spacer(Modifier.height(4.dp))
        Text(pending.activityName, color = TL.paper,
            fontSize = if (compact) 20.sp else 24.sp, fontWeight = FontWeight.Black)
        if (remainingSeconds != null) {
            Spacer(Modifier.height(4.dp))
            // 남은 시간은 경고 문구 안에서 흐른다. 큰 타이머를 줄로 따로 세우면 헤더가
            // 한 줄 늘어 아래 요소가 밀리고 가로에서 버튼이 화면 밖으로 나간다 (iOS 사고 이력).
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.noshow_countdown, remainingSeconds / 60, remainingSeconds % 60),
                color = TL.rec, fontSize = if (compact) 12.sp else 14.sp, fontWeight = FontWeight.Bold)
        }
    }
    // 카메라 권한이 없으면 카운트다운을 시작하지 않는다 — 그대로 진행하면 15초 무반응
    // 뒤에야 무효 처리된다 (iOS는 시작 시점에 throw → 즉시 안전 종료와 같은 취지).
    val startCountdown: () -> Unit = start@{
        if (!Permissions.cameraGranted(context)) {
            // 토스트만 띄우고 끝내면 사용자가 스스로 설정을 뒤져야 했다. 여기서 바로
            // 시스템 창을 띄우거나(미결정), 설정으로 안내한다(영구 거부).
            requestCamera()
            return@start
        }
        countdown = 3
    }
    val checklistAndStart: @Composable () -> Unit = {
        MountCheckRow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.mounted_check), check1) { if (countdown == null) check1 = !check1 }
        Spacer(Modifier.height(10.dp))
        MountCheckRow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.visible_check), check2) { if (countdown == null) check2 = !check2 }
        Spacer(Modifier.height(14.dp))
        TLPrimaryButton(
            if (countdown != null) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.starting_shortly) else "◉  " + androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.start_recording),
            enabled = check1 && check2 && countdown == null,
        ) { startCountdown() }
        Spacer(Modifier.height(10.dp))
        // 반투명 흰 배경 캡슐 — 전체 화면 프리뷰 위에서도 잘 보이게
        Box(
            Modifier.fillMaxWidth()
                .background(Color.White.copy(alpha = 0.14f), TL.cornerM)
                .clickable(enabled = countdown == null) { AppState.cancelMountGuide(pending) }
                .padding(vertical = 13.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.cancel_action),
                color = if (countdown == null) TL.paper else TL.faint,
                fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        }
    }

    Box(Modifier.fillMaxSize().background(TL.ink)) {
        if (portrait) {
            // 세로 — 가로와 동일하게: 전체 화면 프리뷰 + 점선 프레임(맨 뒤) 위로 컨트롤이 덮는다.
            //  프레임이 헤더·체크·버튼 위를 가로지르지 않아 화면이 깔끔하다 (iOS 1:1).
            previewView(Modifier.fillMaxSize())
            dashedGuideOverlay()
            Column(
                // statusBarsPadding — 헤더(거치 가이드·활동명)가 펀치홀·상태바와 겹치지 않게
                Modifier.fillMaxSize().statusBarsPadding().padding(horizontal = 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.height(18.dp))
                header(false)
                Spacer(Modifier.height(16.dp))
                orientationRow()
                // 안내 문구 — 방향·전환 아이콘 바로 아래, 가운데 정렬(Column 중앙). 프레임과 넉넉히 떨어져 간섭 없음.
                // 배경 캡슐 없이 반투명 글씨만 — 프리뷰 위에 자연스럽게 얹힌다.
                Spacer(Modifier.height(16.dp))
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.position_in_frame),
                    color = Color.White.copy(alpha = 0.75f),
                    fontSize = 12.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))   // 가운데는 점선 프레임(별도 레이어)이 차지한다
                checklistAndStart()
                Spacer(Modifier.height(14.dp))
            }
        } else {
            // 가로 — 전체 화면 프리뷰 + 80% 점선 프레임(패널 뒤) 위로, 우측 '반투명' 컨트롤 패널.
            //  패널이 반투명이라 내 전신이 화면 어디까지 들어오는지 프레임과 함께 확인된다 (오버레이 느낌).
            previewView(Modifier.fillMaxSize())
            dashedGuideOverlay()
            Row(Modifier.fillMaxSize()) {
                // 좌: 프리뷰 영역 — 상단 중앙에 안내 문구 (우측 패널과 간섭 없음)
                Box(Modifier.weight(1f).fillMaxHeight()) {
                    // 배경 캡슐 없이 반투명 글씨만 — 프리뷰 위에 자연스럽게 (세로와 동일)
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.position_in_frame),
                        color = Color.White.copy(alpha = 0.75f),
                        fontSize = 12.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .padding(top = 44.dp))
                }
                // 우측 컨트롤 — 스크롤 없이 한 화면에 담기도록 타이포·간격을 축소하고,
                // 촬영/취소를 한 줄로 배치해 세로 여백을 확보한다. SpaceBetween으로 여백감 유지.
                Column(
                    Modifier.width(360.dp).fillMaxHeight()
                        .background(TL.ink.copy(alpha = 0.55f))
                        .displayCutoutPadding()   // 가로 컷아웃·둥근 모서리로 버튼이 잘리지 않게
                        .padding(horizontal = 22.dp, vertical = 18.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.SpaceBetween,
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) { header(true) }
                    orientationRow()
                    Column(Modifier.fillMaxWidth()) {
                        MountCheckRow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.mounted_check), check1, compact = true) {
                            if (countdown == null) check1 = !check1
                        }
                        Spacer(Modifier.height(8.dp))
                        MountCheckRow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.visible_check), check2, compact = true) {
                            if (countdown == null) check2 = !check2
                        }
                    }
                    // 취소 · 촬영 시작 나란히 (iOS 가로 하단 액션 바)
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            Modifier.weight(1f)
                                .background(Color.White.copy(alpha = 0.14f), TL.cornerM)
                                .clickable(enabled = countdown == null) { AppState.cancelMountGuide(pending) }
                                .padding(vertical = 15.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.cancel_action), color = if (countdown == null) TL.paper else TL.faint,
                                fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                        }
                        Box(Modifier.weight(1.4f)) {
                            TLPrimaryButton(
                                if (countdown != null) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.starting_shortly) else "◉  " + androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.start_recording),
                                enabled = check1 && check2 && countdown == null,
                            ) { startCountdown() }
                        }
                    }
                }
            }
        }

        // 3-2-1 카운트다운 오버레이
        countdown?.let { c ->
            Box(Modifier.fillMaxSize().background(TL.ink.copy(alpha = 0.62f)),
                contentAlignment = Alignment.Center) {
                if (waitingCamera) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator(color = TL.rec)
                        Spacer(Modifier.height(10.dp))
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.preparing_camera), color = TL.paper, fontSize = 15.sp)
                    }
                } else {
                    Text(if (c == 0) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.go_label) else "$c", color = TL.paper,
                        fontSize = 84.sp, fontWeight = FontWeight.Black)
                }
            }
        }

        // 카메라가 영구 거부된 상태 — 시스템 창이 뜨지 않으므로 설정으로 보내는 수밖에 없다.
        // 촬영이 아예 불가능한 상황이라 '닫기'는 거치 가이드를 정리하고 나간다.
        if (showCameraBlocked) {
            TLSettingsDialog(
                title = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.camera_access_needed),
                message = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.camera_perm_message),
                dismissLabel = androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.close),
                onConfirm = {
                    showCameraBlocked = false
                    Permissions.openAppSettings(context)
                },
                onDismiss = {
                    showCameraBlocked = false
                    AppState.cancelMountGuide(pending)
                },
            )
        }
    }
}

/** 거치 가이드 체크리스트 행 — 원형 라디오 + 라벨 (iOS 1:1). compact = 가로용 축소. */
@Composable
private fun MountCheckRow(label: String, checked: Boolean, compact: Boolean = false, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
            .background(TL.ink.copy(alpha = 0.6f), TL.cornerM)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = if (compact) 11.dp else 15.dp),
    ) {
        Box(
            Modifier.size(if (compact) 22.dp else 24.dp)
                .background(if (checked) TL.jade else Color.Transparent, CircleShape)
                .border(2.dp, if (checked) TL.jade else TL.muted, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (checked) {
                androidx.compose.material3.Icon(AppIcon.Check, null,
                    tint = TL.ink, modifier = Modifier.size(if (compact) 14.dp else 15.dp))
            }
        }
        Spacer(Modifier.width(12.dp))
        Text(label, color = TL.paper, fontSize = if (compact) 14.sp else 16.sp, fontWeight = FontWeight.Bold)
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
        modifier = Modifier.size(77.dp)   // iOS 64×64의 1.2배 — 안드로이드는 화면 여백이 넉넉해 키움
            .background(if (active) TL.paper else TL.raised, TL.cornerM)
            .clickable(onClick = onClick),
    ) {
        androidx.compose.material3.Icon(icon, null,
            tint = if (active) TL.ink else TL.paper, modifier = Modifier.size(23.dp))
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
    // 뒤로가기 차단 — 세션 이탈은 긴급중단/포기 경로로만. 제스처로 배경에 빠지면
    // 이탈 판정으로 이어질 수 있다 (iOS interactiveDismissDisabled 1:1)
    androidx.activity.compose.BackHandler { }
    val phase by SessionEngine.phase.collectAsStateWithLifecycle()
    val breakNote by SessionEngine.breakNote.collectAsStateWithLifecycle()
    val recorded by SessionEngine.recordedSeconds.collectAsStateWithLifecycle()
    val budget by SessionEngine.breakBudgetRemaining.collectAsStateWithLifecycle()
    val absenceWarning by SessionEngine.absenceWarning.collectAsStateWithLifecycle()
    val episodes by SessionEngine.absenceEpisodeCount.collectAsStateWithLifecycle()
    val oneMinuteWarning by SessionEngine.oneMinuteWarningFired.collectAsStateWithLifecycle()
    var showEmergency by remember { mutableStateOf(false) }
    var showQuitConfirm by remember { mutableStateOf(false) }   // 브레이크 세션 포기 재확인

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
                icon = AppIcon.BellOff,
                label = if (muted) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.muted) else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.alerts_on),
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
            // 매운맛 긴급 예산(10분)을 다 쓰면 버튼을 잠근다 — 엔진이 어차피 막더라도
            // UI가 눌리는 척하면 거짓말이다 (iOS '긴급 소진' 비활성 1:1)
            val budgetExhausted = intensity == Intensity.SPICY && budget <= 0L
            SessionSquareButton(icon = AppIcon.Siren,
                label = if (budgetExhausted) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.emergency_used_up) else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.emergency_break_short), active = false) {
                if (budgetExhausted) return@SessionSquareButton
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
                // iOS SessionView 세로 비율 1:1 — 제목22 / 다이얼230 / 타이머36 / 프리뷰9:16 / 버튼64.
                // 프리뷰는 남는 공간을 채워(9:16 유지) 어떤 화면에서도 버튼까지 한 화면에 들어온다.
                Spacer(Modifier.height(14.dp))
                Text(s?.activityName ?: "", color = TL.paper, fontSize = 22.sp, fontWeight = FontWeight.Black)
                if (oneMinuteWarning) {
                    Spacer(Modifier.height(4.dp))
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.auto_end_1min), color = TL.jade, fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold)
                }
                Spacer(Modifier.weight(1f))
                FocusDial(
                    remaining = ((target - recorded).toFloat() / target).coerceIn(0f, 1f),
                    totalMinutes = target / 60,
                    // 종료 1분 전부터 부채꼴이 빨강→초록 (iOS 동일)
                    tint = if (target - recorded <= 60) TL.jade else TL.rec,
                    modifier = Modifier.size(230.dp),
                )
                Spacer(Modifier.height(14.dp))
                Text(TLFormat.hms((target - recorded).toLong().coerceAtLeast(0)),
                    color = TL.paper, fontSize = 36.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.weight(1f))
                // weight 4 — 프리뷰가 화면 1/3 이상을 차지하도록 유연 공간의 몫을 키움
                Box(Modifier.weight(4f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    previewCard(9f / 16f)
                }
                Spacer(Modifier.weight(1f))
                buttonsRow()
                Spacer(Modifier.height(20.dp))
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
                        tint = if (target - recorded <= 60) TL.jade else TL.rec,   // 1분 전 초록 (iOS 동일)
                        // 가로는 좌측 절반이 통째로 다이얼 몫이라 여백이 넉넉하다 — 190은 작아 보임
                        modifier = Modifier.size(240.dp),
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(TLFormat.hms((target - recorded).toLong().coerceAtLeast(0)),
                        color = TL.paper, fontSize = 30.sp, fontWeight = FontWeight.Black)
                }
                Spacer(Modifier.width(16.dp))
                Column(
                    Modifier.weight(1.2f).fillMaxHeight().padding(vertical = 6.dp),
                    horizontalAlignment = Alignment.Start,   // 프리뷰·버튼 모두 왼쪽 기준 정렬
                ) {
                    // 프리뷰를 80%로 축소(20%↓)해 아래 버튼과 간격을 확보하고, 프레임 왼쪽에 맞춘다
                    Box(
                        Modifier.weight(1f).fillMaxWidth(),
                        contentAlignment = Alignment.CenterStart,
                    ) {
                        Box(Modifier.fillMaxHeight(0.8f)) { previewCard(16f / 9f) }
                    }
                    Spacer(Modifier.height(12.dp))
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
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.absence_detected, minOf(episodes, AbsencePolicy.MAX_EPISODES), AbsencePolicy.MAX_EPISODES),
                        color = TL.ink, fontSize = 14.sp, fontWeight = FontWeight.Black)
                    Text(
                        when {
                            intensity == Intensity.INSANE && episodes >= AbsencePolicy.MAX_EPISODES ->
                                androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.absence_final_insane)
                            intensity == Intensity.INSANE ->
                                androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.absence_warn_insane, AbsencePolicy.MAX_EPISODES)
                            episodes >= AbsencePolicy.MAX_EPISODES ->
                                androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.absence_final_spicy)
                            else ->
                                androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.absence_warn_spicy, AbsencePolicy.MAX_EPISODES)
                        },
                        color = TL.ink.copy(alpha = 0.85f), fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }

        // 긴급 용무 브레이크 오버레이 — 재촬영 카운트다운 (통화도 백그라운드 이탈로 이 화면에 진입)
        (phase as? SessionEngine.Phase.PausedForBreak)?.let { p ->
            var left by remember(p.deadline) { mutableIntStateOf(0) }
            LaunchedEffect(p.deadline) {
                while (true) {
                    left = ((p.deadline - System.currentTimeMillis()) / 1000).toInt().coerceAtLeast(0)
                    delay(500)
                }
            }
            // iOS 브레이크 오버레이 1:1 — 앰버 링 카운트다운 + 재촬영/포기 버튼
            val fraction = (left.toFloat() / TimePolicy.RESUME_WINDOW_SECONDS).coerceIn(0f, 1f)
            val ringColor = if (left <= 60) TL.rec else TL.amber
            // 링(정원 유지) — 세로/가로 공용 조각. 크기와 타이머 폰트를 방향별로 받는다.
            val breakRing: @Composable (androidx.compose.ui.unit.Dp, androidx.compose.ui.unit.TextUnit) -> Unit = { sz, timerFont ->
                Box(
                    Modifier.size(sz).drawBehind {
                        val stroke = 14.dp.toPx()
                        // 최소 변 기준 정사각형 안 중앙에 그려 어떤 비율에서도 정원 유지
                        val d = minOf(size.width, size.height)
                        val arcSize = androidx.compose.ui.geometry.Size(d - stroke, d - stroke)
                        val topLeft = androidx.compose.ui.geometry.Offset(
                            (size.width - d) / 2f + stroke / 2f,
                            (size.height - d) / 2f + stroke / 2f)
                        drawArc(color = TL.raised, startAngle = 0f, sweepAngle = 360f,
                            useCenter = false, topLeft = topLeft, size = arcSize,
                            style = Stroke(width = stroke, cap = StrokeCap.Round))
                        drawArc(color = ringColor, startAngle = -90f, sweepAngle = 360f * fraction,
                            useCenter = false, topLeft = topLeft, size = arcSize,
                            style = Stroke(width = stroke, cap = StrokeCap.Round))
                    },
                    contentAlignment = Alignment.Center,
                ) {
                    // 링 안쪽 여유 — 스트로크(14)+간격을 확보해 글씨가 링에 닿지 않게
                    Column(horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(horizontal = 34.dp)) {
                        Text(TLFormat.hms(left.toLong()), color = TL.paper,
                            fontSize = timerFont, fontWeight = FontWeight.Black, maxLines = 1)
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.to_resume_recording), color = TL.muted, fontSize = 12.sp,
                            maxLines = 1, textAlign = TextAlign.Center)
                    }
                }
            }
            val resumeButton: @Composable () -> Unit = {
                TLPrimaryButton("◉  " + androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.resume_recording_now)) { SessionEngine.resumeFromBreak() }
            }
            // 실수로 종료되는 것 방지 — 재확인 다이얼로그 후에만 세션 포기
            val quitButton: @Composable () -> Unit = {
                TLGhostButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.give_up_penalty), tint = TL.muted) {
                    showQuitConfirm = true
                }
            }

            Box(Modifier.fillMaxSize().background(TL.ink.copy(alpha = 0.96f))) {
                if (portraitSession) {
                    // 세로 — 위에서 아래로 수직 배치 (스크롤 없이 한 화면)
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                        modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
                    ) {
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.recording_paused), color = TL.amber, fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold, letterSpacing = 2.2.sp)
                        Spacer(Modifier.height(6.dp))
                        Text(if (breakNote == null) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.on_emergency_break) else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.recording_interrupted),
                            color = TL.paper, fontSize = 28.sp, fontWeight = FontWeight.Black)
                        breakNote?.let {
                            Spacer(Modifier.height(10.dp))
                            Text(it, color = TL.amber, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                                textAlign = TextAlign.Center, lineHeight = 21.sp)
                        }
                        Spacer(Modifier.height(36.dp))
                        breakRing(300.dp, 56.sp)
                        Spacer(Modifier.height(32.dp))
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.resume_total_note, TimePolicy.RESUME_WINDOW_MINUTES),
                            color = TL.muted, fontSize = 14.sp, textAlign = TextAlign.Center, lineHeight = 21.sp)
                        Spacer(Modifier.height(12.dp))
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.emergency_time_continues),
                            color = TL.amber, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                        Spacer(Modifier.height(36.dp))
                        resumeButton()
                        Spacer(Modifier.height(10.dp))
                        quitButton()
                    }
                } else {
                    // 가로 — 좌측 링 / 우측 설명+버튼 두 칸 배치로 한 화면에 담는다
                    Row(
                        Modifier.fillMaxSize().padding(horizontal = 32.dp, vertical = 18.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(28.dp),
                    ) {
                        Column(
                            Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            // 가로는 링이 주인공 — 제목을 줄이고 링을 키운다
                            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.recording_paused), color = TL.amber, fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold, letterSpacing = 2.2.sp)
                            Spacer(Modifier.height(4.dp))
                            Text(if (breakNote == null) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.on_emergency_break) else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.recording_interrupted),
                                color = TL.paper, fontSize = 17.sp, fontWeight = FontWeight.Black)
                            breakNote?.let {
                                Spacer(Modifier.height(6.dp))
                                Text(it, color = TL.amber, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                                    textAlign = TextAlign.Center, lineHeight = 17.sp)
                            }
                            Spacer(Modifier.height(12.dp))
                            breakRing(230.dp, 44.sp)
                        }
                        Column(
                            Modifier.weight(1f), verticalArrangement = Arrangement.Center,
                        ) {
                            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.resume_total_note_inline, TimePolicy.RESUME_WINDOW_MINUTES),
                                color = TL.muted, fontSize = 13.sp, lineHeight = 20.sp)
                            Spacer(Modifier.height(10.dp))
                            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.emergency_time_continues),
                                color = TL.amber, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                            Spacer(Modifier.height(20.dp))
                            resumeButton()
                            Spacer(Modifier.height(10.dp))
                            quitButton()
                        }
                    }
                }
            }
        }
    }

    // 미친 매운맛 긴급 종료 — iOS insaneEmergencySheet 1:1 (사유 입력 없이 즉시 종료/계속 진행).
    // 향후 '사유 선택 옵션'을 넣을 때 emergencyEnd(reason)에 값을 실어 보내면 그대로 기록된다.
    if (showEmergency) {
        ModalBottomSheet(onDismissRequest = { showEmergency = false }, containerColor = TL.ink) {
            Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp)) {
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.emergency_end), color = TL.paper, fontSize = 19.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.height(10.dp))
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.insane_emergency_note),
                    color = TL.muted, fontSize = 14.sp, lineHeight = 20.sp)
                Spacer(Modifier.height(18.dp))
                TLPrimaryButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.emergency_end)) {
                    showEmergency = false
                    SessionEngine.emergencyEnd(null)
                }
                Spacer(Modifier.height(10.dp))
                TLGhostButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.keep_going), tint = TL.muted) { showEmergency = false }
            }
        }
    }

    // 브레이크 세션 포기 재확인 — 실수로 종료되는 것 방지
    if (showQuitConfirm) {
        ModalBottomSheet(onDismissRequest = { showQuitConfirm = false }, containerColor = TL.ink) {
            Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp)) {
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.give_up_session_q), color = TL.paper, fontSize = 19.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.height(10.dp))
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.give_up_warning),
                    color = TL.muted, fontSize = 14.sp, lineHeight = 20.sp)
                Spacer(Modifier.height(18.dp))
                TLPrimaryButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.give_up_penalty)) {
                    showQuitConfirm = false
                    SessionEngine.emergencyEnd(CancelReason.EMERGENCY_ONGOING)
                }
                Spacer(Modifier.height(10.dp))
                TLGhostButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.keep_going), tint = TL.muted) { showQuitConfirm = false }
            }
        }
    }
}

// MARK: 결과 화면 — 저장/삭제 + 성공 팝 + 보너스 배지·파티클

@Composable
fun SessionResultScreen() {
    val context = LocalContext.current
    // 뒤로가기 차단 — '종료' 버튼의 저장/삭제 파이프라인을 건너뛰지 못하게 (iOS 1:1)
    androidx.activity.compose.BackHandler { }
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
    // 재생성돼도 '이미 저장했다'는 사실을 잃지 않게 — 잃으면 중복 저장 유도
    var saved by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
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
            Text(if (outcome == SessionOutcome.EMERGENCY) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.ended_by_emergency) else outcome.title,
                color = TL.paper, fontSize = 30.sp, fontWeight = FontWeight.Black)
            Text(session.activityName, color = TL.muted, fontSize = 15.sp)
            Spacer(Modifier.height(12.dp))
            Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.recorded_target, TLFormat.hms(session.recordedSeconds.toLong()), TLFormat.hms(session.targetSeconds.toLong())),
                color = TL.paper, fontSize = 18.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.height(12.dp))
            ScoreRules.points(outcome, session.intensity, session.targetSeconds / 60)?.let { (_, pts) ->
                // iOS 1:1 — 테두리 없는 서피스 캡슐 + '적립' 문구, 벌점이면 누적 회수 병기
                Row(verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        if (pts >= 0) androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.pts_earned, pts) else androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.pts_penalty, pts),
                        color = if (pts >= 0) TL.jade else TL.rec,
                        fontSize = 14.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.background(TL.surface, CircleShape)
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                    )
                    if (pts < 0) {
                        val events by AppDb.get(context).scores()
                            .allFlow(AccountStore.currentUserID)
                            .collectAsStateWithLifecycle(initialValue = emptyList())
                        Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.penalty_count, events.count { it.points < 0 }), color = TL.rec,
                            fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            } ?: Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.no_penalty), color = TL.amber, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)

            slotBonus?.let { (days, pts) ->
                Spacer(Modifier.height(10.dp))
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.slot_bonus_msg, days, pts), color = TL.ink,
                    fontSize = 13.sp, fontWeight = FontWeight.Black,
                    modifier = Modifier.background(TL.amber, CircleShape)
                        .padding(horizontal = 14.dp, vertical = 8.dp))
            }
            unlockBonus?.let { pts ->
                Spacer(Modifier.height(8.dp))
                Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.unlock_bonus_msg, pts), color = TL.paper,
                    fontSize = 13.sp, fontWeight = FontWeight.Black,
                    modifier = Modifier.background(TL.rec, CircleShape)
                        .padding(horizontal = 14.dp, vertical = 8.dp))
            }

            // 타임랩스 미리보기 카드 — 탭하면 인앱 재생 (iOS 1:1)
            session.videoFileName?.let {
                Spacer(Modifier.height(18.dp))
                TLCard(raised = true) {
                    TLEyebrow(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.timelapse_preview))
                    // IO 스레드에서 디코드 — 컴포지션 중 파일 디코드는 프레임 드랍을 만든다
                    val thumb = session.thumbnailFileName?.let { name ->
                        androidx.compose.runtime.produceState<android.graphics.Bitmap?>(null, name) {
                            value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                                runCatching {
                                    android.graphics.BitmapFactory.decodeFile(
                                        File(CameraRecorder.sessionDir(context), name).absolutePath)
                                }.getOrNull()
                            }
                        }.value
                    }
                    // 결과물 비율을 실제 촬영 프레임(썸네일)에서 그대로 가져와 프레임을 피팅한다 —
                    // 가로 촬영이면 16:9 가로 프레임, 세로면 9:16 세로 프레임. (썸네일 없을 때만 9:16 기본)
                    val previewAspect = thumb?.let {
                        it.width.toFloat() / it.height.coerceAtLeast(1)
                    } ?: (9f / 16f)
                    val previewLandscape = previewAspect >= 1f
                    Box(
                        Modifier.fillMaxWidth(if (previewLandscape) 0.92f else 0.55f)
                            .aspectRatio(previewAspect)
                            .align(Alignment.CenterHorizontally)
                            .clip(TL.cornerM).background(TL.ink)
                            .clickable(enabled = !showPlayer) { showPlayer = true },
                    ) {
                        if (showPlayer) {
                            // 프레임 안에서 1회 재생 — 끝나면 재생 버튼으로 복귀 (iOS TimelapsePreview 1:1)
                            key(session.videoFileName) {
                                AndroidView(
                                    factory = { ctx ->
                                        android.widget.VideoView(ctx).apply {
                                            setVideoPath(File(CameraRecorder.sessionDir(ctx),
                                                session.videoFileName!!).absolutePath)
                                            setOnPreparedListener { mp -> mp.isLooping = false; start() }
                                            setOnCompletionListener { showPlayer = false }
                                        }
                                    },
                                    modifier = Modifier.fillMaxSize(),
                                )
                            }
                        } else {
                            thumb?.let {
                                Image(it.asImageBitmap(), null, Modifier.fillMaxSize(),
                                    contentScale = androidx.compose.ui.layout.ContentScale.Crop)
                            }
                            Box(Modifier.align(Alignment.Center)
                                .size(58.dp).background(Color.White, CircleShape),
                                contentAlignment = Alignment.Center) {
                                Text("▶", color = TL.ink, fontSize = 20.sp)
                            }
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
                                                    if (ok) com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.saved_to_gallery)
                                                    else com.singlemarks.angrymoti.L10n.str(com.singlemarks.angrymoti.R.string.save_failed),
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
                                    if (saved) AppIcon.Check else AppIcon.ArrowDownToLine,
                                    androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.save_to_gallery),
                                    tint = TL.ink,
                                    modifier = Modifier.size(21.dp))
                            }
                        }
                    }
                    Spacer(Modifier.height(10.dp))
                    Text(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.unsaved_delete_note),
                        color = TL.faint, fontSize = 12.sp)
                }
            }
            Spacer(Modifier.height(16.dp))
        }

        // 하단 고정 버튼 — 저장은 미리보기 우측 상단 다운로드 버튼이 담당 (iOS 1:1)
        Column(Modifier.padding(horizontal = 24.dp)) {
            TLPrimaryButton(androidx.compose.ui.res.stringResource(com.singlemarks.angrymoti.R.string.done_label), tint = TL.amber) {
                // 영상만 지운다 — 썸네일은 캘린더 '이 날의 기록'이 계속 쓰므로 보존한다.
                // 화면 문구 "기록·점수는 유지됩니다"와도 이쪽이 맞다 (iOS 1:1).
                // DB의 videoFileName도 비워 죽은 파일명이 남지 않게 한다.
                scope.launch(Dispatchers.IO) {
                    CameraRecorder.deleteFiles(context, session.videoFileName, null)
                    if (session.videoFileName != null) {
                        val db = com.singlemarks.angrymoti.data.AppDb.get(context)
                        db.sessions().byId(session.id)?.let {
                            db.sessions().upsert(it.copy(videoFileName = null))
                        }
                    }
                    withContext(Dispatchers.Main) { AppState.dismissResult(context) }
                }
            }
            Spacer(Modifier.height(18.dp))
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
