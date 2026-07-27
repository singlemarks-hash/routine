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
    /** 캘린더 색 판정에서 '실패'(빨강)로 치는가. 긴급 종료도 사용자가 스스로 그만둔
     * 실패라 빨강이다 — 노랑(중립)은 기기 사정으로 무효 처리된 안전 종료뿐이다. (iOS 1:1) */
    val isFailure get() = this == EXIT_FAILED || this == NO_SHOW || this == EMERGENCY

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
            // 일정취소·긴급종료는 이탈 실패와 동일 벌점 — iOS와 값이 다르면 크로스 기기 원장이 어긋난다
            SessionOutcome.EMERGENCY -> ScoreEventType.EMERGENCY to -10 * m
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
    // 방 닉네임 최대 글자수. 한글 기준 8자면 넉넉하지만 영문은 한 단어도 안 들어간다.
    // 랭킹 한 줄은 이름에 한 줄 제한이 걸려 있어 길어져도 말줄임으로 접힌다.
    const val NICKNAME_MAX_LENGTH = 15
    const val RESULT_RETENTION_DAYS = 30      // 종료 후 결과 보존 기간

    /** 방 종료 판정에 더하는 정산 유예(분) = 시작 창 + 재촬영 창 + 여유 5분.
     *  마지막 발생이 늦게 시작해 재촬영까지 갔을 때, 진행 중인 세션을 '종료된 방'으로
     *  오판하지 않기 위한 버퍼다. */
    val SETTLE_GRACE_MINUTES get() = TimePolicy.START_WINDOW_MINUTES + TimePolicy.RESUME_WINDOW_MINUTES + 5
}

// MARK: 예약 정책 (iOS ReservationPolicy와 1:1)

object ReservationPolicy {
    /** 시작일은 오늘부터 최대 1개월 이내로만 잡을 수 있다.
     *  무제한이면 알람 안전망(첫 발생 1건 보장)의 탐색 범위를 정할 수 없다. */
    const val MAX_START_LEAD_MONTHS = 1

    /** 시작일로 고를 수 있는 마지막 날의 자정(epoch millis). */
    fun maxStartDayMillis(from: Calendar = Calendar.getInstance()): Long {
        val c = from.clone() as Calendar
        c.add(Calendar.MONTH, MAX_START_LEAD_MONTHS)
        c.set(Calendar.HOUR_OF_DAY, 0); c.set(Calendar.MINUTE, 0)
        c.set(Calendar.SECOND, 0); c.set(Calendar.MILLISECOND, 0)
        return c.timeInMillis
    }
}

// MARK: 일정 충돌 판정 (iOS ScheduleConflict와 1:1)
// 개인 예약 편집과 그룹 방 생성·참여가 같은 규칙을 쓰도록 한곳에 모은다.
//
// 예전에는 '요일이 겹치고 시각이 겹치면 충돌'로만 봤다. 그 결과:
//  - 이미 끝난 활동(6월 종료)이 8월 활동 생성을 막았다 — 기간을 안 봤기 때문
//  - 서로 다른 날짜의 하루짜리끼리 충돌 판정됐다 — 둘 다 요일 전체로 저장되므로
//  - 자정을 넘기는 활동(23시 시작 8시간)이 다음날 새벽 활동과 안 겹친다고 판정됐다

object ScheduleConflict {

    private fun weekdayOf(dayStart: Long): Int =
        Calendar.getInstance().apply { timeInMillis = dayStart }.get(Calendar.DAY_OF_WEEK)

    fun addDays(dayStart: Long, days: Int): Long =
        Calendar.getInstance().apply {
            timeInMillis = dayStart
            add(Calendar.DAY_OF_MONTH, days)
        }.timeInMillis

    /** 특정 날짜에 이 일정이 점유하는 분 구간들.
     *  그날 시작하는 구간과, 전날 시작해 자정을 넘어 이어진 구간을 함께 본다.
     *  (활동 길이 상한이 하루보다 짧아 넘침은 최대 하루다) */
    private fun intervals(
        day: Long, lo: Long, hi: Long?, weekdays: Set<Int>,
        startMinute: Int, durationMinutes: Int,
    ): List<Pair<Int, Int>> {
        fun occurs(d: Long): Boolean {
            if (d < lo) return false
            if (hi != null && d > hi) return false
            return weekdayOf(d) in weekdays
        }
        val result = mutableListOf<Pair<Int, Int>>()
        val end = startMinute + durationMinutes
        if (occurs(day)) result += startMinute to minOf(end, 1440)
        if (end > 1440 && occurs(addDays(day, -1))) result += 0 to (end - 1440)   // 전날에서 넘어온 꼬리
        return result
    }

    /** 두 일정이 실제로 부딪히는가. 범위(lo/hi)는 자정 epoch millis, hi = null이면 무기한.
     *
     *  요일·시각만 비교하면 두 종류의 오답이 난다.
     *   - 오탐: 기간이 딱 하루만 겹치는데 그 하루가 둘 다 발생하지 않는 요일인 경우
     *   - 미탐: 자정을 넘긴 꼬리가 상대의 기간 안에 들어가는 경우
     *  그래서 겹치는 기간의 '실제 날짜'를 훑어 그날의 점유 구간을 직접 비교한다.
     *  주간 패턴은 7일이면 한 바퀴 돌고 넘침은 하루뿐이라 8일만 보면 충분하다. */
    fun conflicts(
        aLo: Long, aHi: Long?, aWeekdays: Set<Int>, aStart: Int, aDuration: Int,
        bLo: Long, bHi: Long?, bWeekdays: Set<Int>, bStart: Int, bDuration: Int,
    ): Boolean {
        val lo = maxOf(aLo, bLo)
        val hi: Long? = when {
            aHi != null && bHi != null -> minOf(aHi, bHi)
            aHi != null -> aHi
            else -> bHi
        }
        // 넘침 꼬리가 하루 뒤까지 갈 수 있으므로 마지막 날 다음날까지 본다.
        val limit = hi?.let { addDays(it, 1) }
        if (limit != null && limit < lo) return false   // 하루 여유를 줘도 안 겹침

        for (offset in 0 until 8) {
            val day = addDays(lo, offset)
            if (limit != null && day > limit) break
            val aIntervals = intervals(day, aLo, aHi, aWeekdays, aStart, aDuration)
            if (aIntervals.isEmpty()) continue
            val bIntervals = intervals(day, bLo, bHi, bWeekdays, bStart, bDuration)
            for (x in aIntervals) for (y in bIntervals) {
                if (x.first < y.second && y.first < x.second) return true
            }
        }
        return false
    }
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

    /** 오늘(기록 없으면 어제)부터 거꾸로 — 연속 달성일. 정의는 streakDetail과 동일. */
    fun currentStreak(sessions: List<com.singlemarks.angrymoti.data.FocusSession>): Int =
        streakDetail(sessions).first

    /**
     * 현재 연속달성의 (일수, 그 기간의 성공 일정 수).
     *
     * 판정은 화면의 성취 아이콘(DayOutcome)과 같은 규칙 하나를 쓴다 —
     * **하루에 하나라도 성공했으면 달성**이다. 일부 실패가 섞인 날(노란불)도 연속을
     * 끊지 않고, 그날의 모든 일정이 실패로 끝난 날(빨간불)에만 끊긴다.
     * 성공 수는 기록탭 '평균 일정'(연속달성 동안 하루 평균 몇 개를 소화했나)의 분자다.
     * iOS SlotPolicy.streakDetail과 1:1.
     */
    fun streakDetail(sessions: List<com.singlemarks.angrymoti.data.FocusSession>): Pair<Int, Int> {
        var count = 0
        var successes = 0
        var day = DayOutcome.startOfDay(System.currentTimeMillis())
        var isToday = true
        while (true) {
            val dayEnd = ScheduleConflict.addDays(day, 1)
            val daySessions = sessions.filter { it.anchorAt in day until dayEnd }
            val icon = DayOutcome.judge(daySessions, day)
            if (icon == DayOutcome.SUCCESS || icon == DayOutcome.HALF) {
                count += 1
                successes += DayOutcome.successCount(daySessions)
            } else if (count == 0 && icon == DayOutcome.NOT_STARTED && isToday) {
                // 오늘은 아직 기록이 없을 뿐 — 어제부터 이어서 센다
            } else {
                break   // 빨간불(전부 실패) 또는 기록 없는 과거 날에서 연속이 끊긴다
            }
            day = ScheduleConflict.addDays(day, -1)
            isToday = false
        }
        return count to successes
    }

    /**
     * 역대 최장 연속달성 — '하나라도 성공한 날'이 달력상 연속으로 이어진 최대 길이.
     * currentStreak과 같은 날짜 판정(성공 하나면 달성)을 쓰되 전체 이력을 훑는다 (기록탭 '최고기록').
     */
    fun bestStreak(sessions: List<com.singlemarks.angrymoti.data.FocusSession>): Int {
        val finished = sessions.filter { it.outcome != null }
        if (finished.isEmpty()) return 0

        // 날짜별로 묶어 '발생별 최종 결과'에 성공이 있는 날만 추린다
        val qualifying = finished.groupBy { DayOutcome.startOfDay(it.anchorAt) }
            .filterValues { DayOutcome.successCount(it) > 0 }
            .keys.sorted()

        var best = 0
        var run = 0
        var prevDay: Long? = null
        for (day in qualifying) {
            run = if (prevDay != null && ScheduleConflict.addDays(prevDay!!, 1) == day) run + 1 else 1
            if (run > best) best = run
            prevDay = day
        }
        // 현재 진행 중인 스트릭이 더 길 수는 없지만(부분집합), 정의가 어긋나지 않게 보정
        return maxOf(best, currentStreak(sessions))
    }
}

// MARK: 태그 프리셋

object ActivityTag {
    val presets = listOf("공부", "독서", "운동", "작업", "연주", "글쓰기")

    /** 태그 입력 한도 — 일정 목록의 태그 칩이 반드시 한 줄로 끝나게 하는 '폭' 예산.
     * 글자 수로 재면 한글 6자와 영문 6자의 폭이 두 배 차이라 영문만 지나치게 손해를 본다.
     * 전각(한글 등) 2 · 반각(영문·숫자) 1로 세어 한글 6자 = 영문 12자 = 12로 맞춘다. (iOS 1:1) */
    const val TAG_WIDTH_BUDGET = 12

    /** 활동명 최대 글자 수. 목록에서는 어차피 한 줄로 말줄임되므로 폭이 아닌 글자 수로 센다 —
     * 여기서 막는 목적은 화면 붕괴가 아니라 비상식적인 길이의 입력 자체를 잘라내는 것이다. (iOS 1:1) */
    const val NAME_MAX_LENGTH = 23

    /** 폭 예산에 맞춰 자른 문자열 — 예산을 넘기는 글자부터 버린다. (iOS truncatedToTagWidth 1:1) */
    fun truncatedToTagWidth(text: String): String {
        var width = 0
        val sb = StringBuilder()
        for (ch in text) {
            width += if (ch.code <= 0x7F) 1 else 2
            if (width > TAG_WIDTH_BUDGET) break
            sb.append(ch)
        }
        return sb.toString()
    }
}

// MARK: 자리비움 정책 (SessionEngine과 배너가 공유)

object AbsencePolicy {
    const val WARN_SECONDS = 30       // 경고 배너 + 카운트 +1
    const val PENALTY_SECONDS = 120   // 2분 확정 → 자동 긴급 중단 / 즉시 실패
    const val MAX_EPISODES = 3        // 경고는 3번까지 — 4번째는 경고 없이 즉시 처리
}
