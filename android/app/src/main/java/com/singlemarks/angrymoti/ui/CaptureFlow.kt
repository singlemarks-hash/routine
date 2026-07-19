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
import androidx.compose.foundation.layout.height
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
import androidx.compose.ui.graphics.Color
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

@Composable
fun MountGuideScreen(pending: PendingSession) {
    val context = LocalContext.current
    var portrait by remember { mutableStateOf(true) }
    var checked by remember { mutableStateOf(false) }
    var countdown by remember { mutableStateOf<Int?>(null) }
    var waitingCamera by remember { mutableStateOf(false) }
    val frameCount by CameraRecorder.frameCount.collectAsStateWithLifecycle()

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

    Column(
        Modifier.fillMaxSize().background(TL.ink).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("거치 가이드", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black,
            modifier = Modifier.padding(top = 16.dp))
        Text("기기를 세워두고, 화면에 본인이 잘 보이는지 확인하세요",
            color = TL.muted, fontSize = 13.sp)
        Spacer(Modifier.height(14.dp))

        Box(
            Modifier.fillMaxWidth().aspectRatio(if (portrait) 3f / 4f else 4f / 3f)
                .clip(TL.cornerL).background(TL.surface),
            contentAlignment = Alignment.Center,
        ) {
            AndroidView(
                factory = { ctx ->
                    androidx.camera.view.PreviewView(ctx).also { pv ->
                        CameraRecorder.previewUseCase.setSurfaceProvider(pv.surfaceProvider)
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
            countdown?.let { c ->
                Box(Modifier.fillMaxSize().background(TL.ink.copy(alpha = 0.55f)),
                    contentAlignment = Alignment.Center) {
                    if (waitingCamera) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            CircularProgressIndicator(color = TL.rec)
                            Spacer(Modifier.height(10.dp))
                            Text("카메라 준비 중…", color = TL.paper, fontSize = 15.sp)
                        }
                    } else {
                        Text(if (c == 0) "시작!" else "$c", color = TL.paper,
                            fontSize = 72.sp, fontWeight = FontWeight.Black)
                    }
                }
            }
        }

        Spacer(Modifier.height(14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TagChip("📱 세로", portrait) { if (countdown == null) portrait = true }
            TagChip("📱 가로", !portrait) { if (countdown == null) portrait = false }
        }
        Spacer(Modifier.height(14.dp))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.clickable { if (countdown == null) checked = !checked }.padding(6.dp),
        ) {
            Text(if (checked) "☑" else "☐", color = if (checked) TL.jade else TL.muted, fontSize = 20.sp)
            Spacer(Modifier.padding(4.dp))
            Text("구도를 확인했어요", color = TL.paper, fontSize = 15.sp)
        }
        Spacer(Modifier.weight(1f))
        TLPrimaryButton(
            if (countdown != null) "곧 시작합니다…" else "촬영 시작",
            enabled = checked && countdown == null,
        ) { countdown = 3 }
        Spacer(Modifier.height(10.dp))
        Text("취소하기", color = if (countdown == null) TL.muted else TL.faint, fontSize = 14.sp,
            modifier = Modifier.clickable(enabled = countdown == null) {
                AppState.cancelMountGuide(pending)
            }.padding(8.dp))
        Spacer(Modifier.height(12.dp))
        if (frameCount > 0) { /* 첫 프레임 도착 — LaunchedEffect가 세션으로 전환 */ }
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

    Box(Modifier.fillMaxSize().background(TL.ink)) {
        Column(
            Modifier.fillMaxSize().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(20.dp))
            Text(s?.activityName ?: "", color = TL.paper, fontSize = 20.sp, fontWeight = FontWeight.Black)
            Text("${intensity.emoji} ${intensity.title}", color = TL.muted, fontSize = 13.sp)
            Spacer(Modifier.height(20.dp))

            // 시그니처 시계판 — 남은 시간만큼 빨간 부채꼴이 12시를 향해 줄어든다 (iOS FocusDial)
            FocusDial(
                remaining = ((target - recorded).toFloat() / target).coerceIn(0f, 1f),
                totalMinutes = target / 60,
                modifier = Modifier.size(240.dp),
            )
            Spacer(Modifier.height(14.dp))
            Text(TLFormat.hms((target - recorded).toLong().coerceAtLeast(0)),
                color = TL.paper, fontSize = 42.sp, fontWeight = FontWeight.Black)
            Text("남은 시간", color = TL.faint, fontSize = 12.sp, letterSpacing = 2.2.sp)
            Spacer(Modifier.height(16.dp))

            // 셀피 프리뷰 (공유 Preview 유스케이스 재부착 — 재연결 없음)
            Box(
                Modifier.fillMaxWidth(0.6f).aspectRatio(3f / 4f).clip(TL.cornerM).background(TL.surface),
            ) {
                AndroidView(
                    factory = { ctx ->
                        androidx.camera.view.PreviewView(ctx).also { pv ->
                            CameraRecorder.previewUseCase.setSurfaceProvider(pv.surfaceProvider)
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
                )
            }
            Spacer(Modifier.weight(1f))

            if (intensity == Intensity.SPICY) {
                val exhausted = budget < 1
                TLPrimaryButton(
                    if (exhausted) "긴급 소진" else "긴급 용무 (남은 예산 ${TLFormat.hms(budget)})",
                    enabled = !exhausted && phase == SessionEngine.Phase.Recording,
                    tint = TL.amber,
                ) { SessionEngine.startBreak() }
                Spacer(Modifier.height(10.dp))
            }
            Text("긴급 종료 (벌점)", color = TL.muted, fontSize = 14.sp,
                modifier = Modifier.clickable { showEmergency = true }.padding(8.dp))
            Spacer(Modifier.height(16.dp))
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
            Box(Modifier.fillMaxSize().background(TL.ink.copy(alpha = 0.92f)), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(28.dp)) {
                    Text("긴급 용무 중", color = TL.amber, fontSize = 22.sp, fontWeight = FontWeight.Black)
                    Spacer(Modifier.height(8.dp))
                    Text(TLFormat.hms(left.toLong()), color = TL.paper, fontSize = 52.sp, fontWeight = FontWeight.Black)
                    Spacer(Modifier.height(8.dp))
                    Text("총 ${TimePolicy.RESUME_WINDOW_MINUTES}분 예산 안에 재촬영을 시작하면 벌점이 없습니다.\n시간은 리셋되지 않고 누적 차감돼요. 0이 되면 실패로 종료됩니다.",
                        color = TL.muted, fontSize = 13.sp, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(24.dp))
                    TLPrimaryButton("지금 재촬영 시작", tint = TL.jade) { SessionEngine.resumeFromBreak() }
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

    Column(
        Modifier.fillMaxSize().background(TL.ink).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(48.dp))
        Box(contentAlignment = Alignment.Center) {
            Image(
                painterResource(if (outcome.isSuccess) R.drawable.moti_smile else R.drawable.moti_angry),
                null, Modifier.size(96.dp).scale(scale),
            )
            if (outcome.isSuccess && (slotBonus != null || unlockBonus != null)) ConfettiBurst()
        }
        Spacer(Modifier.height(14.dp))
        Text(if (outcome == SessionOutcome.EMERGENCY) "긴급 종료됨" else outcome.title,
            color = TL.paper, fontSize = 30.sp, fontWeight = FontWeight.Black)
        Text(session.activityName, color = TL.muted, fontSize = 15.sp)
        Spacer(Modifier.height(10.dp))
        Text("순수 촬영 ${TLFormat.hms(session.recordedSeconds.toLong())} / 목표 ${TLFormat.hms(session.targetSeconds.toLong())}",
            color = TL.paper, fontSize = 19.sp, fontWeight = FontWeight.Black)
        Spacer(Modifier.height(10.dp))
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

        Spacer(Modifier.height(18.dp))
        // 타임랩스 미리보기 카드 (iOS 1:1 — 썸네일 + 캡션)
        session.videoFileName?.let {
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
                    Modifier.fillMaxWidth(0.62f).aspectRatio(3f / 4f)
                        .align(Alignment.CenterHorizontally)
                        .clip(TL.cornerM).background(TL.ink),
                    contentAlignment = Alignment.Center,
                ) {
                    thumb?.let {
                        Image(it.asImageBitmap(), null, Modifier.fillMaxSize(),
                            contentScale = androidx.compose.ui.layout.ContentScale.Crop)
                    }
                    Box(Modifier.size(64.dp).background(Color.White, CircleShape),
                        contentAlignment = Alignment.Center) {
                        Text("▶", color = TL.ink, fontSize = 22.sp)
                    }
                }
                Spacer(Modifier.height(10.dp))
                Text("저장하지 않으면 닫을 때 삭제됩니다. 기록·점수는 유지됩니다.",
                    color = TL.faint, fontSize = 12.sp)
            }
        }
        Spacer(Modifier.weight(1f))

        session.videoFileName?.let { fileName ->
            TLPrimaryButton("갤러리에 저장", tint = TL.jade) {
                scope.launch(Dispatchers.IO) {
                    saveToGallery(context, File(CameraRecorder.sessionDir(context), fileName))
                    withContext(Dispatchers.Main) { AppState.dismissResult(context) }
                }
            }
            Spacer(Modifier.height(10.dp))
        }
        TLPrimaryButton("종료", tint = TL.amber) {
            CameraRecorder.deleteFiles(context, session.videoFileName, session.thumbnailFileName)
            AppState.dismissResult(context)
        }
        Spacer(Modifier.height(20.dp))
    }
}

private fun saveToGallery(context: android.content.Context, file: File) {
    if (!file.exists()) return
    val values = android.content.ContentValues().apply {
        put(android.provider.MediaStore.Video.Media.DISPLAY_NAME, "AngryMoti_${System.currentTimeMillis()}.mp4")
        put(android.provider.MediaStore.Video.Media.MIME_TYPE, "video/mp4")
        put(android.provider.MediaStore.Video.Media.RELATIVE_PATH, "Movies/AngryMoti")
    }
    val resolver = context.contentResolver
    val uri = resolver.insert(android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values) ?: return
    resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
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
