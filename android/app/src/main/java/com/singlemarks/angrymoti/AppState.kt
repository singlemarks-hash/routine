package com.singlemarks.angrymoti

import android.content.Context
import com.singlemarks.angrymoti.data.AppDb
import com.singlemarks.angrymoti.data.Prefs
import com.singlemarks.angrymoti.data.Reservation
import com.singlemarks.angrymoti.models.Intensity
import com.singlemarks.angrymoti.services.AccountStore
import com.singlemarks.angrymoti.services.SubscriptionManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.util.Calendar

/** 촬영 준비 정보 — 알람/즉시 시작 공용 */
data class PendingSession(
    val activityName: String,
    val tag: String,
    val targetSeconds: Int,
    val reservationId: String? = null,
    val scheduledAt: Long? = null,
    /** 그룹 예약의 방 강도 — null이면 전역 강도 사용 */
    val intensityOverrideRaw: String? = null,
)

sealed class Route {
    data object None : Route()
    data class Alarm(val reservationId: String, val fireAt: Long) : Route()
    data class MountGuide(val pending: PendingSession) : Route()
    data object Session : Route()
    data object Result : Route()
}

/** 전역 앱 상태 — iOS AppState 대응 (route 상태 머신 + 강도 규칙) */
object AppState {
    val route = MutableStateFlow<Route>(Route.None)
    val onboarded = MutableStateFlow(false)   // init()에서 Prefs 반영
    val intensity = MutableStateFlow(Intensity.SPICY)
    val spicyCompletions = MutableStateFlow(0)

    fun bootstrap() {
        onboarded.value = Prefs.onboarded
        reloadForAccount()
    }

    /** 계정 전환(로그인·로그아웃·게스트) 시 그 계정의 강도·하향예약을 다시 불러온다 (#19 — 강도 계정별) */
    fun reloadForAccount() {
        intensity.value = Intensity.from(Prefs.intensityRaw(AccountStore.currentUserID))
        applyPendingDowngradeIfDue()
    }

    fun completeOnboarding() {
        Prefs.onboarded = true
        onboarded.value = true
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** 미친 매운맛 잠금 해제: 매운맛 완주 3회 — 멤버십은 조건 없이 즉시 */
    val insaneUnlocked: Boolean
        get() = spicyCompletions.value >= 3 || SubscriptionManager.isPro.value

    /** 상향은 즉시, 하향은 다음날 0시 적용 (당일 회피 방지) */
    fun requestIntensityChange(target: Intensity) {
        val owner = AccountStore.currentUserID
        if (target == Intensity.INSANE) {
            if (!insaneUnlocked) return
            Prefs.setIntensityRaw(owner, target.raw)
            Prefs.setPendingDowngradeAt(owner, 0)
            intensity.value = target
        } else {
            if (intensity.value == Intensity.SPICY) return
            val midnight = Calendar.getInstance().apply {
                add(Calendar.DAY_OF_MONTH, 1)
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
            }.timeInMillis
            Prefs.setPendingDowngradeAt(owner, midnight)
        }
    }

    val pendingDowngrade: Boolean
        get() = Prefs.pendingDowngradeAt(AccountStore.currentUserID) > System.currentTimeMillis()

    fun applyPendingDowngradeIfDue() {
        val owner = AccountStore.currentUserID
        val at = Prefs.pendingDowngradeAt(owner)
        if (at in 1..System.currentTimeMillis()) {
            Prefs.setIntensityRaw(owner, Intensity.SPICY.raw)
            Prefs.setPendingDowngradeAt(owner, 0)
            intensity.value = Intensity.SPICY
        }
    }

    fun refreshSpicyCompletions(context: Context) {
        scope.launch(Dispatchers.IO) {
            spicyCompletions.value = AppDb.get(context).sessions()
                .spicyCompletions(AccountStore.currentUserID)
        }
    }

    // MARK: 촬영 플로우 라우팅 (iOS와 동일한 상태 전이)

    /** 알람에서 '촬영 준비' — 알람음 끄고 거치 가이드로 */
    fun beginRecording(context: Context, pending: PendingSession) {
        com.singlemarks.angrymoti.services.AlarmScheduler.stopAlarmSound()
        com.singlemarks.angrymoti.services.AlarmScheduler.cancelAlarmNotification(context)
        route.value = Route.MountGuide(pending)
    }

    /** 거치 가이드 카운트다운 시작과 동시에 호출 — 녹화를 미리 켠다 */
    fun startArmedRecording(pending: PendingSession, portrait: Boolean) {
        // 그룹 예약은 방의 강도로 판정 (iOS와 동일)
        val effective = pending.intensityOverrideRaw?.let { Intensity.from(it) } ?: intensity.value
        com.singlemarks.angrymoti.services.SessionEngine.start(
            activityName = pending.activityName, tag = pending.tag,
            intensity = effective, scheduledAt = pending.scheduledAt,
            targetSeconds = pending.targetSeconds, reservationId = pending.reservationId,
            portrait = portrait, isPro = SubscriptionManager.isPro.value,
        )
    }

    fun enterSessionIfRecording() {
        if (route.value !is Route.Result) route.value = Route.Session
    }

    /** 거치 가이드에서 취소 — 예약 알람이면 알람으로, 즉시 시작이면 홈으로 */
    fun cancelMountGuide(pending: PendingSession) {
        route.value = if (pending.reservationId != null && pending.scheduledAt != null)
            Route.Alarm(pending.reservationId, pending.scheduledAt)
        else Route.None
    }

    fun sessionFinished() { route.value = Route.Result }
    fun dismissResult(context: Context) {
        com.singlemarks.angrymoti.services.SessionEngine.reset()
        refreshSpicyCompletions(context)
        route.value = Route.None
    }

    /** 알람에서 '일정 취소' — 긴급 벌점과 함께 세션 기록 */
    fun cancelSchedule(context: Context, reservation: Reservation, fireAt: Long, reason: String) {
        com.singlemarks.angrymoti.services.AlarmScheduler.stopAlarmSound()
        com.singlemarks.angrymoti.services.AlarmScheduler.cancelAlarmNotification(context)
        scope.launch(Dispatchers.IO) {
            val db = AppDb.get(context)
            // 그룹 예약은 방의 강도로 판정
            val effective = reservation.intensityOverride ?: intensity.value
            val s = com.singlemarks.angrymoti.data.FocusSession(
                ownerUserID = AccountStore.currentUserID,
                activityName = reservation.name, tag = reservation.tag,
                intensityRaw = effective.raw, scheduledAt = fireAt,
                endedAt = System.currentTimeMillis(),
                targetSeconds = reservation.durationMinutes * 60,
                outcomeRaw = com.singlemarks.angrymoti.models.SessionOutcome.EMERGENCY.raw,
                emergencyReason = reason, reservationID = reservation.id,
            )
            db.sessions().upsert(s)
            com.singlemarks.angrymoti.models.ScoreRules.points(
                com.singlemarks.angrymoti.models.SessionOutcome.EMERGENCY,
                effective, reservation.durationMinutes
            )?.let { (type, pts) ->
                val e = com.singlemarks.angrymoti.data.ScoreEvent(
                    ownerUserID = AccountStore.currentUserID, typeRaw = type.raw,
                    points = pts, sessionID = s.id, intensityRaw = effective.raw, note = reason)
                db.scores().insert(e); AccountStore.mirror(e)
                com.singlemarks.angrymoti.services.GroupStore.reportScore(reservation, pts)
            }
        }
        route.value = Route.None
    }
}
