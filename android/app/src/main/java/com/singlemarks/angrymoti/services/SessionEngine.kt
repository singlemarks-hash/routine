package com.singlemarks.angrymoti.services

import android.content.Context
import android.content.Intent
import android.os.BatteryManager
import android.os.StatFs
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

    private lateinit var appContext: Context
    fun init(context: Context) { appContext = context.applicationContext }

    val currentSession: FocusSession? get() = session

    // MARK: 시작

    fun start(activityName: String, tag: String, intensity: Intensity,
              scheduledAt: Long?, targetSeconds: Int, reservationId: String?,
              portrait: Boolean, isPro: Boolean) {
        // 재진입 방지 — 이미 진행 중인 세션이 있으면 무시한다 (iOS guard phase==.idle 통일).
        // 겹치는 알람·이중 탭으로 새 start()가 진행 중 세션을 결과 없이 덮어써 유실되던 결함 차단.
        val current = phase.value
        if (current != Phase.Idle && current !is Phase.Finished) return
        AlarmScheduler.sessionMuted = true   // 촬영 시작과 함께 알림차단 기본 활성화 (iOS 동일)
        if (AlarmScheduler.hasDndAccess(appContext)) AlarmScheduler.setDnd(appContext, true)   // 권한 있으면 시스템 방해 금지도 자동 ON
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
        isFinalizing = false
        safetyCounter = 0
        breakWarnPosted = false
        phase.value = Phase.Recording

        Prefs.activeSessionId = s.id
        Prefs.breakDeadline = 0

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
            if (!breakWarnPosted && remain in 1..120_000) {   // 마감 2분 전 (iOS 통일)
                breakWarnPosted = true
                AlarmScheduler.postStatus(appContext, 2001, "재촬영까지 2분",
                    "2분 안에 재촬영을 시작하지 않으면 세션이 실패로 기록됩니다.")
            }
            if (remain <= 0) failBreakExpired(s)
            return
        }
        if (p != Phase.Recording) return

        // 촬영 신호 점검 — 프레임이 끊기면(카메라 미개시·인터럽션·저장 실패) 벽시계로 헛돌지 않도록
        // 안전 종료한다. 실제 촬영 없이 완주(만점)로 오인하는 것을 원천 차단 (벌점 없음, 촬영분 보존).
        if (CameraRecorder.isCaptureStalled()) { safetyEnd("촬영 신호 끊김"); return }

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
            if (result == null) {
                // 목표 시간에 도달했지만 촬영된 영상이 없다 — 카메라 실패.
                // 완주(만점)로 처리하지 않고 안전 종료로 기록한다 (앱의 유일한 약속 방어).
                android.util.Log.e("AngryMoti", "완주 시점 영상 없음 — 안전 종료로 강등")
                finalize(applyRecording(s, null), SessionOutcome.SAFETY_ENDED, "촬영 실패 — 영상 없음")
            } else {
                finalize(applyRecording(s, result), SessionOutcome.COMPLETED, null)
            }
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

    // MARK: 이탈 이벤트 (백그라운드/화면 잠금)
    // 통화도 '앵그리모드 미사용'이므로 예외 두지 않는다 — 전화가 오면 앱이 백그라운드로 내려가
    // 이 경로를 타고 매운맛은 긴급용무(수동 재개), 미친맛은 즉시 실패로 처리된다.

    fun handleExitEvent() {
        val s = session ?: return
        if (isFinalizing) return
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
        if (p != Phase.Recording && p !is Phase.PausedForBreak) return
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
        if (level in 0..5 && !charging) { safetyEnd("배터리 부족"); return }   // 0% 포함 (iOS 0~5% 통일, -1=미상 제외)
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
        AccountStore.mirrorSession(s)   // 세션 요약 클라우드 미러 (기기 변경 시 진척 보존)

        ScoreRules.points(outcome, s.intensity, s.targetSeconds / 60)?.let { (type, points) ->
            val e = ScoreEvent(ownerUserID = s.ownerUserID, typeRaw = type.raw, points = points,
                sessionID = s.id, intensityRaw = s.intensityRaw, note = note)
            db.scores().insert(e)
            AccountStore.mirror(e)
            // 그룹 예약이면 서버 그룹 점수에도 합산
            s.reservationID?.let { rid ->
                GroupStore.reportScore(db.reservations().byId(rid), points)
            }
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
        if (total > 0) {
            lastSlotBonus.value = crossedDays to total
            AccountStore.mirrorSlotBonusTier(s.ownerUserID, awarded)   // 기기 변경 시 중복 지급 방지
        }
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
        AccountStore.mirrorUnlockBonusAwarded(s.ownerUserID)   // 기기 변경 시 중복 지급 방지
        lastUnlockBonus.value = 5
    }

    private fun cleanupRuntime() {
        AlarmScheduler.sessionMuted = false
        AlarmScheduler.restoreDndIfNeeded(appContext)   // 세션이 켰던 방해 금지 자동 해제
        tickJob?.cancel(); tickJob = null
        isFinalizing = false
        Prefs.activeSessionId = null
        Prefs.breakDeadline = 0
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
            // 그룹 예약은 방의 강도로 판정 (개인 전역 강도와 무관)
            val effIntensity = r.intensityOverride ?: intensity
            val days: List<Long> = if (r.groupId != null) {
                // 그룹: 시작일부터 전 구간 스윕 (최대 92일) — 앱을 오래 안 열어도 전부 집계
                val spanDays = (((today - r.accountabilityStart) / 86_400_000L) + 1)
                    .coerceIn(1, com.singlemarks.angrymoti.models.GroupPolicy.MAX_DURATION_DAYS.toLong())
                (0 until spanDays).map { today - it * 86_400_000L }
            } else listOf(today - 86_400_000L, today)
            for (dayStart in days) {
                val fire = r.occurrenceOn(dayStart) ?: continue
                if (fire < r.accountabilityStart) continue          // 생성(또는 마지막 편집) 전 발생분은 책임 없음
                if (fire + grace >= now) continue                   // 10분 창이 아직 안 끝남
                if (r.groupId == null && fire <= now - 86_400_000L * 2) continue   // 개인은 2일 이내만
                val key = "${r.id}-$fire"
                if (key in existing) continue

                val noShow = FocusSession(
                    ownerUserID = r.ownerUserID, activityName = r.name, tag = r.tag,
                    intensityRaw = effIntensity.raw, scheduledAt = fire,
                    endedAt = fire + grace, targetSeconds = r.durationMinutes * 60,
                    outcomeRaw = SessionOutcome.NO_SHOW.raw, reservationID = r.id,
                )
                db.sessions().upsert(noShow)
                AccountStore.mirrorSession(noShow)   // 노쇼 요약도 클라우드 미러
                ScoreRules.points(SessionOutcome.NO_SHOW, effIntensity, r.durationMinutes)?.let { (type, pts) ->
                    // 결정적 ID — 예약 동기화로 두 기기가 같은 노쇼를 각자 스윕해도
                    // 클라우드 문서가 하나로 합쳐져 이중 벌점이 되지 않는다 (iOS와 동일 해시)
                    val eventId = deterministicId("noshow|${r.id.lowercase()}|${fire / 1000}")
                    val e = ScoreEvent(id = eventId,
                        ownerUserID = r.ownerUserID, typeRaw = type.raw, points = pts,
                        sessionID = noShow.id, intensityRaw = effIntensity.raw,
                        note = "${TimePolicy.START_WINDOW_MINUTES}분 내 미시작")
                    db.scores().insert(e); AccountStore.mirror(e)
                    GroupStore.reportScore(r, pts)   // 그룹 예약이면 그룹 점수에도 반영
                }
                existing.add(key)
            }
        }
    }

    /** 문자열 키 → 결정적 UUID 문자열 (MD5, iOS와 동일 알고리즘·표기).
     *  같은 노쇼(예약+발생시각)는 어느 기기에서 스윕해도 같은 이벤트 ID를 갖는다. */
    private fun deterministicId(key: String): String {
        val hex = java.security.MessageDigest.getInstance("MD5")
            .digest(key.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}" +
            "-${hex.substring(16, 20)}-${hex.substring(20, 32)}"
    }

    // MARK: 고아 세션 복구 (킬/크래시)

    suspend fun recoverOrphanIfNeeded() {
        val id = Prefs.activeSessionId ?: return
        val db = AppDb.get(appContext)
        val orphan = db.sessions().byId(id)
        if (orphan == null || orphan.outcome != null) {
            Prefs.activeSessionId = null; return
        }
        // 계정 스코프 — 다른 계정의 미완료 세션은 지금 로그인한 계정으로 마감/노출하지 않는다.
        // (해당 계정이 다시 로그인하면 그때 복구. 남의 녹화·기록이 새 계정에 새는 것을 차단)
        if (orphan.ownerUserID != AccountStore.currentUserID) return
        // 통화도 긴급용무와 동일하게 breakDeadline을 세우므로 wasOnBreak가 통화 중단까지 포함한다.
        // '앵그리모드 미사용 중 앱 종료'는 이탈 실패로 마감(철저히 10분 원칙).
        val wasOnBreak = Prefs.breakDeadline != 0L
        val outcome = when {
            wasOnBreak -> SessionOutcome.EXIT_FAILED                     // 중단·통화 창 도중 종료
            orphan.intensity == Intensity.INSANE -> SessionOutcome.EXIT_FAILED  // 미친맛: 무단 종료도 이탈 실패 (봐주지 않음)
            else -> SessionOutcome.SAFETY_ENDED                         // 매운맛 크래시 — 관대하게 무벌점
        }
        val s = orphan.copy(outcomeRaw = outcome.raw, endedAt = System.currentTimeMillis())
        db.sessions().upsert(s)
        AccountStore.mirrorSession(s)   // 복구된 세션 요약도 클라우드 미러
        ScoreRules.points(outcome, s.intensity, s.targetSeconds / 60)?.let { (type, pts) ->
            val e = ScoreEvent(ownerUserID = s.ownerUserID, typeRaw = type.raw, points = pts,
                sessionID = s.id, intensityRaw = s.intensityRaw,
                note = if (outcome == SessionOutcome.EXIT_FAILED) "이탈 후 앱 종료" else "비정상 종료 복구")
            db.scores().insert(e); AccountStore.mirror(e)
            s.reservationID?.let { rid -> GroupStore.reportScore(db.reservations().byId(rid), pts) }
        }
        // 크래시로 남은 파셜 영상은 재생 불가(moov 미기록)하고 어떤 세션도 참조하지 않는다 —
        // 디스크만 차지하므로 정리한다.
        CameraRecorder.deleteFiles(appContext, "${orphan.id}.mp4", "${orphan.id}.jpg")
        Prefs.activeSessionId = null
        Prefs.breakDeadline = 0
    }
}
