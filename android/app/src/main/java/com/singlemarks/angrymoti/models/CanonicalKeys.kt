package com.singlemarks.angrymoti.models

// 저장 데이터의 언어 중립 정본 키 (docs/영어화-설계도.md D3) — iOS CanonicalKeys.swift와 1:1.
//
// 태그·취소 사유·벌점 note를 한글 문구 대신 소문자 키/토큰으로 저장한다.
//  - 쓰기: 항상 키로 쓴다 (이 파일의 상수·빌더만 사용).
//  - 읽기: 키·레거시 한글 둘 다 해석한다. 과거 기록은 영원히 한글이므로
//    레거시 → 키 역매핑은 영구 유지한다 (삭제 금지).
//  - 표시: label()이 로케일 문구로 푼다. 지금은 한국어 원문(바이트 동일),
//    Phase 3에서 strings.xml 참조로 전환된다.
//
// ⚠️ 키 문자열은 Firestore·iOS와 공유되는 유선 포맷이다 — 한 글자도 바꾸지 말 것.

/** 태그 7종 */
object CanonicalTag {
    /** 예약 편집·즉시 시작의 선택지 (그룹 제외 — 그룹 예약은 시스템이 만든다) */
    val presets = listOf("study", "reading", "workout", "work", "music", "writing")
    const val GROUP = "group"

    /** 레거시 한글 → 키. '악기'는 '연주'로 개명된 옛 이름 — 같은 키로 흡수한다. */
    private val legacy = mapOf(
        "공부" to "study", "독서" to "reading", "운동" to "workout",
        "작업" to "work", "연주" to "music", "악기" to "music",
        "글쓰기" to "writing", "그룹" to "group",
    )

    /** 저장값 → 정본 키. 프리셋도 레거시도 아니면(직접 입력 태그) 원문 그대로. */
    fun canonical(raw: String): String = legacy[raw] ?: raw

    /** 저장값 → 표시 문구. 커스텀 태그는 사용자가 쓴 원문 그대로 보여준다. */
    fun label(raw: String): String = when (canonical(raw)) {
        "study" -> "공부"
        "reading" -> "독서"
        "workout" -> "운동"
        "work" -> "작업"
        "music" -> "연주"
        "writing" -> "글쓰기"
        "group" -> "그룹"
        else -> raw
    }
}

/** 일정 취소 사유 (프리셋 3 + 긴급 지속, 자유 입력은 원문 저장) */
object CancelReason {
    /** 취소 시트의 프리셋 순서 그대로 */
    val presets = listOf("reason.urgent", "reason.sick", "reason.rest")
    /** 긴급 용무 재촬영 창에서 '일정 취소'를 고른 경우 */
    const val EMERGENCY_ONGOING = "reason.emergency_ongoing"

    private val legacy = mapOf(
        "급한 일이 생겼어요" to "reason.urgent",
        "몸이 좋지 않아요" to "reason.sick",
        "오늘은 쉬고싶어요" to "reason.rest",
        "긴급 용무 지속" to "reason.emergency_ongoing",
    )

    fun canonical(raw: String): String = legacy[raw] ?: raw

    fun label(raw: String): String = when (canonical(raw)) {
        "reason.urgent" -> "급한 일이 생겼어요"
        "reason.sick" -> "몸이 좋지 않아요"
        "reason.rest" -> "오늘은 쉬고싶어요"
        "reason.emergency_ongoing" -> "긴급 용무 지속"
        else -> raw   // 자유 입력 사유
    }
}

/** 벌점/보너스 note 토큰 (`note.코드` 또는 `note.코드|인자`) */
object ScoreNote {
    // 인자 없는 토큰
    const val CAMERA_START_FAILED = "note.camera_start_failed"      // 카메라 시작 실패
    const val RECORDING_INCOMPLETE = "note.recording_incomplete"    // 영상 손상/부족
    const val RECORDING_STALLED = "note.recording_stalled"          // 촬영이 정상 진행되지 않음
    const val EXIT_IMMEDIATE = "note.exit_immediate"                // 미친 매운맛 이탈 즉시 실패
    const val APP_KILLED = "note.app_killed"                        // 촬영 중 앱 종료

    // 인자 있는 토큰 빌더
    fun noResume(minutes: Int) = "note.no_resume|$minutes"
    fun noShowWindow(minutes: Int) = "note.noshow_window|$minutes"
    fun slotBonus(days: Int) = "note.slot_bonus|$days"
    fun absenceOver(count: Int) = "note.absence_over|$count"
    fun absenceMinutes(minutes: Int) = "note.absence_minutes|$minutes"
    fun groupGiveup(roomName: String) = "note.group_giveup|$roomName"

    /**
     * 레거시 한글 note → 토큰. 매칭 안 되면(자유 입력 긴급 사유 등) 원문 그대로.
     * 취소 사유 프리셋도 note 칸에 실려 있으므로 함께 해석한다.
     */
    fun canonical(raw: String): String {
        when (raw) {
            "카메라 시작 실패" -> return CAMERA_START_FAILED
            "촬영 불완전 — 영상 손상/부족" -> return RECORDING_INCOMPLETE
            "촬영이 정상 진행되지 않음" -> return RECORDING_STALLED
            "이탈 즉시 실패" -> return EXIT_IMMEDIATE
            "촬영 중 앱 종료 (배터리·강제 종료 등)" -> return APP_KILLED
        }
        argument(raw, "", "분 내 재촬영 없음")?.let { return noResume(it) }
        argument(raw, "", "분 내 미시작")?.let { return noShowWindow(it) }
        argument(raw, "연속 ", "일 달성 — 활동 슬롯 확장 보너스")?.let { return slotBonus(it) }
        argument(raw, "자리비움 ", "회 초과 — 즉시 실패")?.let { return absenceOver(it) }
        argument(raw, "자리비움 ", "분 — 즉시 실패")?.let { return absenceMinutes(it) }
        if (raw.startsWith("그룹 '") && raw.endsWith("' 중도 포기")) {
            return groupGiveup(raw.removePrefix("그룹 '").removeSuffix("' 중도 포기"))
        }
        return CancelReason.canonical(raw)
    }

    /** 저장값(토큰·레거시 한글·자유 입력) → 표시 문구. */
    fun label(raw: String): String {
        if (!raw.startsWith("note.")) return CancelReason.label(raw)
        val body = raw.removePrefix("note.")
        val code = body.substringBefore('|')
        val arg = if ('|' in body) body.substringAfter('|') else ""
        return when (code) {
            "camera_start_failed" -> "카메라 시작 실패"
            "recording_incomplete" -> "촬영 불완전 — 영상 손상/부족"
            "recording_stalled" -> "촬영이 정상 진행되지 않음"
            "exit_immediate" -> "이탈 즉시 실패"
            "app_killed" -> "촬영 중 앱 종료 (배터리·강제 종료 등)"
            "no_resume" -> "${arg}분 내 재촬영 없음"
            "noshow_window" -> "${arg}분 내 미시작"
            "slot_bonus" -> "연속 ${arg}일 달성 — 활동 슬롯 확장 보너스"
            "absence_over" -> "자리비움 ${arg}회 초과 — 즉시 실패"
            "absence_minutes" -> "자리비움 ${arg}분 — 즉시 실패"
            "group_giveup" -> "그룹 '${arg}' 중도 포기"
            else -> raw   // 미래 토큰 — 원문 노출이 크래시보다 낫다
        }
    }

    /** "prefixNsuffix" 꼴에서 N을 뽑는다. 전체가 정확히 그 꼴일 때만. */
    private fun argument(raw: String, prefix: String, suffix: String): Int? {
        if (!raw.startsWith(prefix) || !raw.endsWith(suffix)) return null
        if (raw.length <= prefix.length + suffix.length) return null
        val mid = raw.substring(prefix.length, raw.length - suffix.length)
        if (mid.isEmpty() || !mid.all { it.isDigit() }) return null
        return mid.toIntOrNull()
    }
}
