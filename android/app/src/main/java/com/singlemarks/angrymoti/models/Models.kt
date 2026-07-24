package com.singlemarks.angrymoti.models

import java.util.Calendar

// iOS Models.swift와 1:1 대응 — 정책 수치를 바꿀 땐 반드시 양쪽 + README를 함께 수정한다.

// MARK: 시간 정책

object TimePolicy {
    /** 알람 후 촬영을 시작해야 하는 창(초). 넘기면 노쇼 탈락. */
    const val START_WINDOW_SECONDS = 600L
    /** 긴급 용무 중단 후 재촬영 창(초) = 세션당 누적 예산. */
    const val RESUME_WINDOW_SECONDS = 600L
    val START_WINDOW_MINUTES get() = (START_WINDOW_SECONDS / 60).toInt()
    val RESUME_WINDOW_MINUTES get() = (RESUME_WINDOW_SECONDS / 60).toInt()

    val durationOptionsMinutes = listOf(10, 15, 25, 30, 45, 60, 90, 120, 150, 180, 240, 300, 360, 480)

    /** 기본 예약 시작 시각: 현재 + 2시간을 '시' 단위로 내림 (9:39→11:00, 9:00→11:00, 8:59→10:00).
     *  iOS의 dateComponents([.hour]) 방식과 결과 동일 — 분을 버려 정각으로 맞춘다. */
    fun defaultStartMinute(now: Calendar = Calendar.getInstance()): Int {
        // 지금+2시간의 '시'만 취하고 분은 버린다(내림). iOS 기준으로 통일. 예: 9:39 → 11:00.
        val plus2h = (now.clone() as Calendar).apply { add(Calendar.HOUR_OF_DAY, 2) }
        return plus2h.get(Calendar.HOUR_OF_DAY) * 60
    }
}

// MARK: 강도

enum class Intensity(val raw: String) {
    SPICY("spicy"), INSANE("insane");

    val title get() = if (this == SPICY) "매운맛" else "미친 매운맛"
    val subtitle get() = if (this == SPICY)
        "긴급 용무로 중단해도 10분 안에 재촬영하면 벌점 없음."
    else
        "유예도 사유도 없다. 이탈 즉시 실패. 상점 2배, 벌점 2배."
    val emoji get() = if (this == SPICY) "🌶️" else "🔥"

    companion object {
        fun from(raw: String?) = entries.firstOrNull { it.raw == raw } ?: SPICY
    }
}

// MARK: 세션 결과

enum class SessionOutcome(val raw: String) {
    COMPLETED("completed"),     // 완주
    EXIT_FAILED("exitFailed"),  // 이탈 실패 (재촬영 창 초과·자리비움 확정 포함)
    NO_SHOW("noShow"),          // 10분 미시작 탈락
    EMERGENCY("emergency"),     // 긴급 종료 (세션 포기)
    SAFETY_ENDED("safetyEnded");// 안전 종료 (배터리/저장공간/크래시) — 벌점 없음, 캘린더 중립

    val title get() = when (this) {
        COMPLETED -> "완주"; EXIT_FAILED -> "이탈 실패"; NO_SHOW -> "노쇼 탈락"
        EMERGENCY -> "긴급 종료"; SAFETY_ENDED -> "안전 종료"
    }
    val isSuccess get() = this == COMPLETED
    val isFailure get() = this == EXIT_FAILED || this == NO_SHOW

    companion object {
        fun from(raw: String?) = entries.firstOrNull { it.raw == raw }
    }
}

// MARK: 점수 이벤트 타입

enum class ScoreEventType(val raw: String) {
    COMPLETE("complete"), EXIT_FAIL("exitFail"), NO_SHOW("noShow"), EMERGENCY("emergency"),
    UNLOCK_BONUS("unlockBonus"), ABSENCE("absence"), PENALTY_RESET("penaltyReset"), SLOT_BONUS("slotBonus"),
    GROUP_QUIT("groupQuit");

    val title get() = when (this) {
        COMPLETE -> "완주 상점"; EXIT_FAIL -> "이탈 벌점"; NO_SHOW -> "노쇼 벌점"
        EMERGENCY -> "긴급 종료"; UNLOCK_BONUS -> "잠금 해제 보너스"; ABSENCE -> "자리비움 벌점"
        PENALTY_RESET -> "멤버십 벌점 리셋"; SLOT_BONUS -> "슬롯 확장 보너스"
        GROUP_QUIT -> "그룹 중도 포기"
    }

    companion object {
        fun from(raw: String?) = entries.firstOrNull { it.raw == raw } ?: COMPLETE
    }
}

// MARK: 점수 규칙

object ScoreRules {
    /** 완주 상점은 활동 길이에 따라 커진다: 10분~1시간 +10 · 1시간30분~3시간 +20 · 4시간~8시간 +30 */
    fun completionBase(forMinutes: Int): Int = when {
        forMinutes < 90 -> 10
        forMinutes < 240 -> 20
        else -> 30
    }

    /** 미친 매운맛은 상점도 2배, 벌점도 2배. */
    fun points(outcome: SessionOutcome, intensity: Intensity, durationMinutes: Int): Pair<ScoreEventType, Int>? {
        val m = if (intensity == Intensity.INSANE) 2 else 1
        return when (outcome) {
            SessionOutcome.COMPLETED -> ScoreEventType.COMPLETE to completionBase(durationMinutes) * m
            SessionOutcome.EXIT_FAILED -> ScoreEventType.EXIT_FAIL to -10 * m
            SessionOutcome.NO_SHOW -> ScoreEventType.NO_SHOW to -15 * m
            SessionOutcome.EMERGENCY -> ScoreEventType.EMERGENCY to -5 * m
            SessionOutcome.SAFETY_ENDED -> null
        }
    }

    /** 그룹 챌린지 중도 포기 벌점 (그룹 점수 + 개인 누적 동일 반영) */
    const val GROUP_QUIT_PENALTY = -50
}

// MARK: 그룹 챌린지 정책 (iOS GroupPolicy와 1:1)

object GroupPolicy {
    const val MAX_MEMBERS = 30
    const val MIN_MEMBERS_TO_START = 2
    const val MAX_DURATION_DAYS = 92          // 최대 3개월
    const val MIN_START_LEAD_MINUTES = 60     // 시작은 지금부터 최소 1시간 뒤
    const val JOIN_CUTOFF_MINUTES = 11        // 시작 11분 전까지만 참여 (10분 전 알람을 받을 수 있게)
    const val CODE_LENGTH = 5
    const val NICKNAME_MAX_LENGTH = 8         // 방 닉네임 최대 글자수 (랭킹 한 줄 유지)
    const val RESULT_RETENTION_DAYS = 30      // 종료 후 결과 보존 기간
}

// MARK: 활동 슬롯 정책 — 슬롯은 언제나 '현재 연속 달성일'이 정한다

object SlotPolicy {
    const val BASE_SLOTS = 2
    const val MEMBER_FLOOR_SLOTS = 10

    /** (필요 연속일, 최대 활동 수). slots null = 무제한 */
    val tiers: List<Pair<Int, Int?>> = listOf(3 to 3, 5 to 4, 7 to 5, 10 to 10, 30 to null)

    /** 허용 슬롯 수 (null = 무제한). 멤버십은 최소 10개 보장. */
    fun allowedSlots(streak: Int, isMember: Boolean = false): Int? {
        var allowed: Int? = BASE_SLOTS
        for ((days, slots) in tiers) if (streak >= days) allowed = slots
        val ladder = allowed ?: return null
        return if (isMember) maxOf(MEMBER_FLOOR_SLOTS, ladder) else ladder
    }

    fun nextTier(afterStreak: Int): Pair<Int, Int?>? = tiers.firstOrNull { it.first > afterStreak }

    /**
     * 연속 달성일: 오늘(기록 없으면 어제)부터 거꾸로, '실패 없이 완주한 날'을 연속 카운트.
     * @param finished (anchorEpochMillis, isSuccess, isFailure) 목록 — 결과 확정된 세션만
     */
    fun currentStreak(finished: List<Triple<Long, Boolean, Boolean>>): Int {
        val cal = Calendar.getInstance()
        fun startOfDay(c: Calendar): Long {
            val d = c.clone() as Calendar
            d.set(Calendar.HOUR_OF_DAY, 0); d.set(Calendar.MINUTE, 0)
            d.set(Calendar.SECOND, 0); d.set(Calendar.MILLISECOND, 0)
            return d.timeInMillis
        }
        var dayStart = startOfDay(cal)
        var count = 0
        val oneDay = 86_400_000L
        var isToday = true
        while (true) {
            val dayEnd = dayStart + oneDay
            val daySessions = finished.filter { it.first in dayStart until dayEnd }
            val success = daySessions.any { it.second }
            val failure = daySessions.any { it.third }
            if (success && !failure) {
                count += 1
            } else if (count == 0 && daySessions.isEmpty() && isToday) {
                // 오늘 아직 기록 없음 → 어제부터 계산
            } else break
            dayStart -= oneDay
            isToday = false
        }
        return count
    }
}

// MARK: 태그 프리셋

object ActivityTag {
    val presets = listOf("공부", "독서", "운동", "작업", "연주", "글쓰기")
}

// MARK: 자리비움 정책 (SessionEngine과 배너가 공유)

object AbsencePolicy {
    const val WARN_SECONDS = 30       // 경고 배너 + 카운트 +1
    const val PENALTY_SECONDS = 120   // 2분 확정 → 자동 긴급 중단 / 즉시 실패
    const val MAX_EPISODES = 3        // 경고는 3번까지 — 4번째는 경고 없이 즉시 처리
}
