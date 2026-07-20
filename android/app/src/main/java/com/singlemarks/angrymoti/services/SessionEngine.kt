package com.singlemarks.angrymoti.services

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.StatFs
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.data.FocusSession
import com.singlemarks.angrymoti.data.Prefs
import com.singlemarks.angrymoti.data.Reservation
import com.singlemarks.angrymoti.data.ScoreEvent
import com.singlemarks.angrymoti.models.AbsencePolicy
import com.singlemarks.angrymoti.models.Intensity
import com.singlemarks.angrymoti.models.ScoreEventType
import com.singlemarks.angrymoti.models.ScoreRules
import com.singlemarks.angrymoti.models.SessionOutcome
import com.singlemarks.angrymoti.models.SlotPolicy
import com.singlemarks.angrymoti.models.TimePolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 세션 상태 머신 — iOS SessionEngine과 정책 1:1.
 * 완주 판정: '순수 촬영 시간'(틱 1초)이 목표 도달 시 자동 종료. 통화·중단 중엔 틱이 멈춘다.
 */
object SessionEngine {
    sealed class Phase {
        data object Idle : Phase()
        data object Recording : Phase()
        data class PausedForBreak(val deadline: Long) : Phase()
        data object PausedForCall : Phase()
        data class Finished(val outcome: SessionOutcome) : Phase()
    }

    val phase = MutableStateFlow<Phase>(Phase.Idle)
    val recordedSeconds = MutableStateFlow(0)
    val breakBudgetRemaining = MutableStateFlow(TimePolicy.RESUME_WINDOW_SECONDS)
    val absenceWarning = MutableStateFlow(false)
    val absenceEpisodeCount = MutableStateFlow(0)
    val oneMinuteWarningFired = MutableStateFlow(false)
    val lastFinishedSession = MutableStateFlow<FocusSession?>(null)
    /** (연속일, 보너스) — 결과 화면 파티클 */
    val lastSlotBonus = MutableStateFlow<Pair<Int, Int>?>(null)
    val lastUnlockBonus = MutableStateFlow<Int?>(null)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var tickJob: Job? = null
    private var session: FocusSession? = null
    private var absencePenaltyApplied = false
    private var isFinalizing = false
    private var safetyCounter = 0
    private var breakWarnPosted = false

    @Volatile private var isCallActive = false
    private var telephonyCallback: Any? = null

    private lateinit var appContext: Context
    fun init(context: Context) { appContext = context.applicationContext }

    val currentSession: FocusSession? get() = session

    // MARK: 시작

    fun start(activityName: String, tag: String, intensity: Intensity,
              scheduledAt: Long?, targetSeconds: Int, reservationId: String?,
              portrait: Boolean, isPro: Boolean) {
        AlarmScheduler.sessionMuted = true   // 촬영 시작과 함께 알림차단 기본 활성화 (iOS 동일)
        val owner = AccountStore.currentUserID
        val s = FocusSession(
            ownerUserID = owner, activityName = activityName, tag = tag,
            intensityRaw = intensity.raw, scheduledAt = scheduledAt,
            startedAt = System.currentTimeMillis(), targetSeconds = targetSeconds,
            reservationID = reservationId,
        )
        scope.launch(Dispatchers.IO) { AppDb.get(appContext).sessions().upsert(s) }

        CameraRecorder.startRecording(appContext, s.id, portrait, targetSeconds.toDouble(), watermark = !isPro)

        session = s
        recordedSeconds.value = 0
        oneMinuteWarningFired.value = false
        absenceWarning.value = false
        absencePenaltyApplied = false
        absenceEpisodeCount.value = 0
        breakBudgetRemaining.value = TimePolicy.RESUME_WINDOW_SECONDS
        isCallActive = false
        isFinalizing = false
        safetyCounter = 0
        breakWarnPosted = false
        phase.value = Phase.Recording

        Prefs.activeSessionId = s.id
        Prefs.breakDeadline = 0
        Prefs.callActive = false

        startCallObserver()
        startTick()
        SessionService.start(appContext)
    }

    // MARK: 틱 (1초)

    private fun startTick() {
        tickJob?.cancel()
        tickJob = scope.launch {
            while (isActive) {
                delay(1000)
                onTick()
            }
        }
    }

    private fun onTick() {
        val s = session ?: return
        if (isFinalizing) return

        val p = phase.value
        if (p is Phase.PausedForBreak) {
            val remain = p.deadline - System.currentTimeMillis()
            if (!breakWarnPosted && remain in 1..60_000) {
                breakWarnPosted = true
                AlarmScheduler.postStatus(appContext, 2001, "재촬영 1분 전",
                    "1분 안에 재촬영을 시작하지 않으면 세션이 실패로 기록됩니다.")
            }
            if (remain <= 0) failBreakExpired(s)
            return
        }
        if (p != Phase.Recording) return

        recordedSeconds.value += 1

        // 자리비움 — 경고는 3번까지, 4번째는 경고 없이 즉시. 경고 후 2분 연속 부재도 동일 처리.
        val absent = CameraRecorder.absentSeconds.value
        if (absent >= AbsencePolicy.WARN_SECONDS) {
            if (!absenceWarning.value && !absencePenaltyApplied) {
                absenceEpisodeCount.value += 1
                if (absenceEpisodeCount.value > AbsencePolicy.MAX_EPISODES) {
                    absencePenaltyApplied = true
                    handleAbsenceEvent(s, "자리비움 ${AbsencePolicy.MAX_EPISODES}회 초과 — 즉시 실패")
                    return
                }
                absenceWarning.value = true
                AlarmScheduler.playChime(appContext)
            }
            if (absent >= AbsencePolicy.PENALTY_SECONDS && !absencePenaltyApplied) {
                absencePenaltyApplied = true
                handleAbsenceEvent(s, "자리비움 ${AbsencePolicy.PENALTY_SECONDS / 60}분 — 즉시 실패")
                return
            }
        } else if (absenceWarning.value || absencePenaltyApplied) {
            absenceWarning.value = false
            absencePenaltyApplied = false
        }

        // 종료 1분 전 예고
        val remaining = s.targetSeconds - recordedSeconds.value
        if (!oneMinuteWarningFired.value && remaining in 1..60) {
            oneMinuteWarningFired.value = true
            AlarmScheduler.playChime(appContext)
        }
        // 완주
        if (recordedSeconds.value >= s.targetSeconds) {
            finishCompleted(s)
            return
        }
        // 30초마다 안전 점검
        safetyCounter += 1
        if (safetyCounter % 30 == 0) checkSafety()
    }

    // MARK: 완주

    private fun finishCompleted(s: FocusSession) {
        if (isFinalizing) return
        isFinalizing = true
        scope.launch(Dispatchers.IO) {
            val result = CameraRecorder.stopRecording(appContext)
            finalize(applyRecording(s, result), SessionOutcome.COMPLETED, null)
        }
    }

    // MARK: 긴급 용무 중단 — 세션당 10분 누적 예산

    fun startBreak() {
        val s = session ?: return
        if (phase.value != Phase.Recording || s.intensity != Intensity.SPICY) return
        val budget = breakBudgetRemaining.value
        if (budget < 1) { failBreakExpired(s); return }
        val deadline = System.currentTimeMillis() + budget * 1000
        CameraRecorder.pause()
        breakWarnPosted = false
        phase.value = Phase.PausedForBreak(deadline)
        Prefs.breakDeadline = deadline
        AlarmScheduler.postStatus(appContext, 2000, "긴급 용무 중단",
            "${TimePolicy.RESUME_WINDOW_MINUTES}분 예산 안에 돌아와 재촬영을 시작하면 벌점이 없습니다.")
    }

    fun resumeFromBreak() {
        val p = phase.value as? Phase.PausedForBreak ?: return
        val s = session ?: return
        if (isFinalizing) return
        if (System.currentTimeMillis() >= p.deadline) { failBreakExpired(s); return }
        breakBudgetRemaining.value = ((p.deadline - System.currentTimeMillis()) / 1000).coerceAtLeast(0)
        CameraRecorder.resume()
        absenceWarning.value = false
        absencePenaltyApplied = false
        phase.value = Phase.Recording
        Prefs.breakDeadline = 0
    }

    private fun failBreakExpired(s: FocusSession) {
        if (isFinalizing) return
        isFinalizing = true
        scope.launch(Dispatchers.IO) {
            val result = CameraRecorder.stopPreservingFootage(appContext)
            AlarmScheduler.postStatus(appContext, 2002, "세션 실패",
                "${TimePolicy.RESUME_WINDOW_MINUTES}분 안에 재촬영을 시작하지 않아 실패로 기록되었습니다.")
            finalize(applyRecording(s, result), SessionOutcome.EXIT_FAILED,
                "${TimePolicy.RESUME_WINDOW_MINUTES}분 내 재촬영 없음")
        }
    }

    // MARK: 부재 확정 — 매운맛: 자동 긴급 중단 / 미친 매운맛: 즉시 실패 (부재 자체엔 벌점 없음)

    private fun handleAbsenceEvent(s: FocusSession, insaneNote: String) {
        if (s.intensity == Intensity.INSANE) {
            if (isFinalizing) return
            isFinalizing = true
            scope.launch(Dispatchers.IO) {
                val result = CameraRecorder.stopPreservingFootage(appContext)
                finalize(applyRecording(s, result), SessionOutcome.EXIT_FAILED, insaneNote)
            }
            return
        }
        AlarmScheduler.playChime(appContext)
        absenceWarning.value = false
        startBreak()
    }

    // MARK: 이탈 이벤트 (백그라운드/화면 잠금) — 통화 중이면 무시

    fun handleExitEvent() {
        val s = session ?: return
        if (isFinalizing || isCallActive) return
        when (s.intensity) {
            Intensity.SPICY -> if (phase.value == Phase.Recording) startBreak()
            Intensity.INSANE -> {
                if (phase.value != Phase.Recording) return
                isFinalizing = true
                scope.launch(Dispatchers.IO) {
                    val result = CameraRecorder.stopPreservingFootage(appContext)
                    finalize(applyRecording(s, result), SessionOutcome.EXIT_FAILED, "이탈 즉시 실패")
                }
            }
        }
    }

    fun handleReturnEvent() {
        val s = session ?: return
        val p = phase.value
        if (p is Phase.PausedForBreak && System.currentTimeMillis() >= p.deadline) failBreakExpired(s)
    }

    // MARK: 긴급 종료 (세션 포기 — 벌점)

    fun emergencyEnd(reason: String?) {
        val s = session ?: return
        if (isFinalizing) return
        val p = phase.value
        if (p != Phase.Recording && p !is Phase.PausedForBreak && p != Phase.PausedForCall) return
        isFinalizing = true
        scope.launch(Dispatchers.IO) {
            val result = CameraRecorder.stopPreservingFootage(appContext)
            val updated = applyRecording(s, result).copy(emergencyReason = reason)
            finalize(updated, SessionOutcome.EMERGENCY, reason)
        }
    }

    // MARK: 안전 종료 (배터리 ≤5% 미충전 / 저장공간 <500MB / 카메라 실패)

    private fun checkSafety() {
        val bm = appContext.getSystemService(BatteryManager::class.java)
        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val charging = bm.isCharging
        if (level in 1..5 && !charging) { safetyEnd("배터리 부족"); return }
        val stat = StatFs(appContext.filesDir.absolutePath)
        if (stat.availableBytes < 500_000_000L) safetyEnd("저장 공간 부족")
    }

    fun safetyEnd(note: String) {
        val s = session ?: return
        if (isFinalizing) return
        isFinalizing = true
        scope.launch(Dispatchers.IO) {
            val result = CameraRecorder.stopPreservingFootage(appContext)
            finalize(applyRecording(s, result), SessionOutcome.SAFETY_ENDED, note)
        }
    }

    // MARK: 통화 — 벌점 없는 일시정지 / 자동 재개

    private fun startCallObserver() {
        if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.READ_PHONE_STATE)
            != PackageManager.PERMISSION_GRANTED) return
        val tm = appContext.getSystemService(TelephonyManager::class.java)
        if (Build.VERSION.SDK_INT >= 31) {
            val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) { onCallState(state) }
            }
            telephonyCallback = cb
            tm.registerTelephonyCallback(ContextCompat.getMainExecutor(appContext), cb)
        } else {
            @Suppress("DEPRECATION")
            tm.listen(object : PhoneStateListener() {
                @Deprecated("Deprecated in Java")
                override fun onCallStateChanged(state: Int, phoneNumber: String?) { onCallState(state) }
            }, PhoneStateListener.LISTEN_CALL_STATE)
        }
    }

    private fun onCallState(state: Int) {
        val active = state != TelephonyManager.CALL_STATE_IDLE
        if (active == isCallActive) return
        isCallActive = active
        Prefs.callActive = active
        if (session == null || isFinalizing) return
        if (active) {
            if (phase.value == Phase.Recording) {
                CameraRecorder.pause()
                phase.value = Phase.PausedForCall
            }
        } else {
            if (phase.value == Phase.PausedForCall) {
                CameraRecorder.resume()
                phase.value = Phase.Recording
            }
        }
    }

    // MARK: 확정

    private fun applyRecording(s: FocusSession, result: CameraRecorder.RecordingResult?): FocusSession =
        if (result != null) s.copy(
            videoFileName = result.videoFileName,
            thumbnailFileName = result.thumbnailFileName,
            recordedSeconds = result.recordedSeconds,
        ) else s.copy(recordedSeconds = recordedSeconds.value)

    private suspend fun finalize(s0: FocusSession, outcome: SessionOutcome, note: String?) {
        val db = AppDb.get(appContext)
        val s = s0.copy(outcomeRaw = outcome.raw, endedAt = System.currentTimeMillis())
        db.sessions().upsert(s)

        ScoreRules.points(outcome, s.intensity, s.targetSeconds / 60)?.let { (type, points) ->
            val e = ScoreEvent(ownerUserID = s.ownerUserID, typeRaw = type.raw, points = points,
                sessionID = s.id, intensityRaw = s.intensityRaw, note = note)
            db.scores().insert(e)
            AccountStore.mirror(e)
        }

        lastSlotBonus.value = null
        lastUnlockBonus.value = null
        if (outcome == SessionOutcome.COMPLETED) {
            awardSlotBonusIfTierCrossed(s)
            awardUnlockBonusIfJustUnlocked(s)
        }

        withContext(Dispatchers.Main) {
            lastFinishedSession.value = s
            phase.value = Phase.Finished(outcome)
            cleanupRuntime()
        }
    }

    /** 연속 달성일이 슬롯 확장 단계를 '이번에' 넘었으면 +5 (같은 연속 구간 중복 지급 방지) */
    private suspend fun awardSlotBonusIfTierCrossed(s: FocusSession) {
        val db = AppDb.get(appContext)
        val all = db.sessions().all(s.ownerUserID)
        val finished = all.filter { it.outcome != null }
            .map { Triple(it.anchorAt, it.outcome!!.isSuccess, it.outcome!!.isFailure) }
        val streak = SlotPolicy.currentStreak(finished)

        var awarded = Prefs.slotBonusAwardedTier(s.ownerUserID)
        if (streak < awarded) awarded = 0
        var total = 0; var crossedDays = 0
        for ((days, _) in SlotPolicy.tiers) {
            if (days in (awarded + 1)..streak) {
                val e = ScoreEvent(ownerUserID = s.ownerUserID, typeRaw = ScoreEventType.SLOT_BONUS.raw,
                    points = 5, sessionID = s.id, intensityRaw = s.intensityRaw,
                    note = "연속 ${days}일 달성 — 활동 슬롯 확장 보너스")
                db.scores().insert(e); AccountStore.mirror(e)
                total += 5; crossedDays = days; awarded = days
            }
        }
        Prefs.setSlotBonusAwardedTier(s.ownerUserID, awarded)
        if (total > 0) lastSlotBonus.value = crossedDays to total
    }

    /** 매운맛 완주 3회째 — 미친 매운맛 잠금 해제 보너스 +5 (계정당 평생 1회) */
    private suspend fun awardUnlockBonusIfJustUnlocked(s: FocusSession) {
        if (s.intensity != Intensity.SPICY) return
        if (Prefs.unlockBonusAwarded(s.ownerUserID)) return
        val db = AppDb.get(appContext)
        if (db.sessions().spicyCompletions(s.ownerUserID) < 3) return
        val e = ScoreEvent(ownerUserID = s.ownerUserID, typeRaw = ScoreEventType.UNLOCK_BONUS.raw,
            points = 5, sessionID = s.id, intensityRaw = s.intensityRaw,
            note = "매운맛 완주 3회 — 미친 매운맛 잠금 해제 보너스")
        db.scores().insert(e); AccountStore.mirror(e)
        Prefs.setUnlockBonusAwarded(s.ownerUserID)
        lastUnlockBonus.value = 5
    }

    private fun cleanupRuntime() {
        AlarmScheduler.sessionMuted = false
        tickJob?.cancel(); tickJob = null
        telephonyCallback = null
        isCallActive = false
        isFinalizing = false
        Prefs.activeSessionId = null
        Prefs.breakDeadline = 0
        Prefs.callActive = false
        session = null
        SessionService.stop(appContext)
        CameraRecorder.releaseCamera(appContext)
    }

    fun reset() {
        phase.value = Phase.Idle
        recordedSeconds.value = 0
        lastFinishedSession.value = null
    }

    // MARK: 노쇼 스위퍼 — 예약 '생성 이후' 발생분만 대상 + 과거 버그 기록 복구

    suspend fun sweepNoShows() {
        val db = AppDb.get(appContext)
        val owner = AccountStore.currentUserID
        val reservations = db.reservations().active(owner)
        val intensity = Intensity.from(Prefs.intensityRaw)
        val now = System.currentTimeMillis()
        val grace = TimePolicy.START_WINDOW_SECONDS * 1000

        val byId = reservations.associateBy { it.id }
        val existing = mutableSetOf<String>()
        for (s in db.sessions().all(owner)) {
            val rid = s.reservationID ?: continue
            val sched = s.scheduledAt ?: continue
            val r = byId[rid]
            if (s.outcome == SessionOutcome.NO_SHOW && r != null && sched < r.createdAt) {
                for (e in db.scores().bySession(s.id)) db.scores().delete(e)
                CameraRecorder.deleteFiles(appContext, s.videoFileName, s.thumbnailFileName)
                db.sessions().delete(s)
                continue
            }
            existing.add("$rid-$sched")
        }

        val cal = java.util.Calendar.getInstance().apply {
            set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
            set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
        }
        val today = cal.timeInMillis
        for (r in reservations) {
            for (dayStart in listOf(today - 86_400_000L, today)) {
                val fire = r.occurrenceOn(dayStart) ?: continue
                if (fire < r.accountabilityStart) continue          // 생성(또는 마지막 편집) 전 발생분은 책임 없음
                if (fire + grace >= now) continue                   // 10분 창이 아직 안 끝남
                if (fire <= now - 86_400_000L * 2) continue
                val key = "${r.id}-$fire"
                if (key in existing) continue

                val noShow = FocusSession(
                    ownerUserID = r.ownerUserID, activityName = r.name, tag = r.tag,
                    intensityRaw = intensity.raw, scheduledAt = fire,
                    endedAt = fire + grace, targetSeconds = r.durationMinutes * 60,
                    outcomeRaw = SessionOutcome.NO_SHOW.raw, reservationID = r.id,
                )
                db.sessions().upsert(noShow)
                ScoreRules.points(SessionOutcome.NO_SHOW, intensity, r.durationMinutes)?.let { (type, pts) ->
                    val e = ScoreEvent(ownerUserID = r.ownerUserID, typeRaw = type.raw, points = pts,
                        sessionID = noShow.id, intensityRaw = intensity.raw,
                        note = "${TimePolicy.START_WINDOW_MINUTES}분 내 미시작")
                    db.scores().insert(e); AccountStore.mirror(e)
                }
                existing.add(key)
            }
        }
    }

    // MARK: 고아 세션 복구 (킬/크래시)

    suspend fun recoverOrphanIfNeeded() {
        val id = Prefs.activeSessionId ?: return
        val db = AppDb.get(appContext)
        val orphan = db.sessions().byId(id)
        if (orphan == null || orphan.outcome != null) {
            Prefs.activeSessionId = null; return
        }
        val wasOnBreak = Prefs.breakDeadline != 0L
        val wasInCall = Prefs.callActive
        val outcome = if (wasOnBreak && !wasInCall) SessionOutcome.EXIT_FAILED else SessionOutcome.SAFETY_ENDED
        val s = orphan.copy(outcomeRaw = outcome.raw, endedAt = System.currentTimeMillis())
        db.sessions().upsert(s)
        ScoreRules.points(outcome, s.intensity, s.targetSeconds / 60)?.let { (type, pts) ->
            val e = ScoreEvent(ownerUserID = s.ownerUserID, typeRaw = type.raw, points = pts,
                sessionID = s.id, intensityRaw = s.intensityRaw,
                note = if (outcome == SessionOutcome.EXIT_FAILED) "이탈 후 앱 종료" else "비정상 종료 복구")
            db.scores().insert(e); AccountStore.mirror(e)
        }
        Prefs.activeSessionId = null
        Prefs.breakDeadline = 0
        Prefs.callActive = false
    }
}
