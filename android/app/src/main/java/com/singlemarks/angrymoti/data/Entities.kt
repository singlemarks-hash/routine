package com.singlemarks.angrymoti.data

import androidx.room.Entity
import androidx.room.PrimaryKey
import com.singlemarks.angrymoti.models.Intensity
import com.singlemarks.angrymoti.models.ScoreEventType
import com.singlemarks.angrymoti.models.SessionOutcome
import java.util.Calendar
import java.util.UUID

// iOS SwiftData 모델과 1:1. 모든 엔티티는 ownerUserID로 계정별 격리 (게스트 = "guest").

@Entity(tableName = "reservations",
    indices = [androidx.room.Index("ownerUserID"), androidx.room.Index("groupId")])
data class Reservation(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val ownerUserID: String = "guest",
    val name: String,
    val tag: String,
    /** 하루 중 시작 시각(자정 기준 분) */
    val startMinute: Int,
    val durationMinutes: Int,
    /** 반복 요일 CSV (1=일...7=토, Calendar.DAY_OF_WEEK). 비면 일회성 */
    val repeatWeekdaysCsv: String = "",
    /** 일회성 예약 날짜(자정 epoch millis). 반복이면 null */
    val oneOffDayStart: Long? = null,
    val createdAt: Long = System.currentTimeMillis(),
    val isActive: Boolean = true,
    /** 노쇼 책임 기준 시각 — 편집으로 시간을 옮기면 그 순간으로 갱신. null = createdAt.
     *  (createdAt을 직접 바꾸면 '생성 전 잘못 찍힌 노쇼 복구'가 과거의 정당한 노쇼까지 지운다) */
    val accountableFrom: Long? = null,
    /** 그룹 챌린지 방 ID — 그룹 예약이면 non-null (createdAt = 방 시작일) */
    val groupId: String? = null,
    /** 반복 종료 시각(epoch millis) — 그룹 예약의 대회 종료일. null = 무기한 */
    val endAt: Long? = null,
    /** 그룹 방의 강도 — 개인 전역 강도 대신 이 값으로 판정 */
    val intensityOverrideRaw: String? = null,
    /** 마지막 수정 시각 — 크로스 기기 병합에서 최신 판정 기준. null = createdAt */
    val updatedAt: Long? = null,
) {
    /** 이 시각 이전 발생분은 노쇼 책임이 없다 */
    val accountabilityStart: Long get() = accountableFrom ?: createdAt
    val intensityOverride: Intensity? get() = intensityOverrideRaw?.let { Intensity.from(it) }
    val repeatWeekdays: List<Int>
        get() = repeatWeekdaysCsv.split(",").filter { it.isNotBlank() }.map { it.toInt() }
    val isRepeating get() = repeatWeekdays.isNotEmpty()

    /** 주어진 날짜(자정 millis)에 발생하는 예약이면 그 날의 시작 시각 반환 */
    fun occurrenceOn(dayStart: Long): Long? {
        if (isRepeating) {
            val cal = Calendar.getInstance().apply { timeInMillis = dayStart }
            if (cal.get(Calendar.DAY_OF_WEEK) !in repeatWeekdays) return null
        } else {
            if (oneOffDayStart != dayStart) return null
        }
        val fire = dayStart + startMinute * 60_000L
        // 시작일(createdAt) 이전 날짜엔 발생 없음. 그룹=방 시작일, 개인 기간 반복=고른 시작일이
        // createdAt이 된다. 일반 예약은 생성일 이전 날짜가 없으므로 무해.
        val startDay = Calendar.getInstance().apply {
            timeInMillis = createdAt
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        if (dayStart < startDay) return null
        // 종료일 이후 발생 없음
        if (endAt != null && fire > endAt) return null
        return fire
    }

    /** 다음 발생 시각 (now 이후).
     *  탐색 범위가 좁으면(예전 28일) 한참 뒤 시작하는 예약을 못 찾아, '첫 발생 1건은
     *  반드시 알람을 건다'는 약속이 깨진다. 필요한 최대 범위 = 시작일 상한 1개월 +
     *  그룹 최대 기간 3개월 ≈ 130일. 여유를 둬 180일 (iOS와 동일). */
    fun nextOccurrence(now: Long = System.currentTimeMillis()): Long? {
        val cal = Calendar.getInstance().apply {
            timeInMillis = now
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        repeat(180) {
            occurrenceOn(cal.timeInMillis)?.let { if (it > now) return it }
            cal.add(Calendar.DAY_OF_MONTH, 1)
        }
        return null
    }

    /** 앞으로 울릴 발생이 남아 있는가 — 슬롯 점유 판정 전용.
     *  끝난 활동은 오늘 일정에 계속 보이더라도 자리는 이미 돌려준 상태다 (iOS와 동일). */
    fun hasRemainingOccurrence(now: Long = System.currentTimeMillis()): Boolean {
        val end = endAt ?: return true   // 무기한 — 스캔 없이 항상 점유
        fun dayStart(t: Long): Long = Calendar.getInstance().apply {
            timeInMillis = t
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        if (dayStart(now) > dayStart(end)) return false
        return nextOccurrence(now) != null
    }

    /** 같은 날 시간 구간 겹침 판정.
     *  주의: 자정을 넘기는 활동은 이 함수만으로 판정할 수 없다 — ScheduleConflict를 쓸 것. */
    fun overlaps(otherStartMinute: Int, otherDuration: Int): Boolean {
        val aEnd = startMinute + durationMinutes
        val bEnd = otherStartMinute + otherDuration
        return startMinute < bEnd && otherStartMinute < aEnd
    }

    /** 이 예약이 실제로 발생하는 날짜 범위(자정 millis). second = null이면 무기한.
     *  레거시 일회성(요일 없음 + 날짜 마커)은 그 하루만이다 — createdAt은 '만든 시각'이라
     *  실제 발생일과 다를 수 있어 그대로 범위 시작으로 쓰면 안 된다. */
    fun activeDayRange(): Pair<Long, Long?> {
        fun dayStart(t: Long): Long = Calendar.getInstance().apply {
            timeInMillis = t
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        if (!isRepeating && oneOffDayStart != null) return oneOffDayStart to oneOffDayStart
        return dayStart(createdAt) to endAt?.let { dayStart(it) }
    }

    /** 이 예약이 점유하는 요일이 무엇인가 (레거시 일회성은 그 날짜의 요일) */
    fun occupiedWeekdays(): Set<Int> {
        if (isRepeating) return repeatWeekdays.toSet()
        return oneOffDayStart?.let {
            setOf(Calendar.getInstance().apply { timeInMillis = it }.get(Calendar.DAY_OF_WEEK))
        } ?: emptySet()
    }
}

@Entity(tableName = "sessions",
    indices = [androidx.room.Index("ownerUserID"), androidx.room.Index("reservationID")])
data class FocusSession(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val ownerUserID: String = "guest",
    val activityName: String,
    val tag: String,
    val intensityRaw: String,
    val scheduledAt: Long? = null,
    val startedAt: Long? = null,
    val endedAt: Long? = null,
    val targetSeconds: Int,
    val recordedSeconds: Int = 0,
    val outcomeRaw: String? = null,
    val emergencyReason: String? = null,
    val videoFileName: String? = null,
    val thumbnailFileName: String? = null,
    val reservationID: String? = null,
) {
    val intensity get() = Intensity.from(intensityRaw)
    val outcome get() = SessionOutcome.from(outcomeRaw)
    val anchorAt get() = startedAt ?: scheduledAt ?: System.currentTimeMillis()
}

@Entity(tableName = "score_events",
    indices = [androidx.room.Index("ownerUserID"), androidx.room.Index("sessionID")])
data class ScoreEvent(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val ownerUserID: String = "guest",
    val typeRaw: String,
    val points: Int,
    val sessionID: String? = null,
    val intensityRaw: String,
    val timestamp: Long = System.currentTimeMillis(),
    val note: String? = null,
) {
    val type get() = ScoreEventType.from(typeRaw)
    val intensity get() = Intensity.from(intensityRaw)
}
