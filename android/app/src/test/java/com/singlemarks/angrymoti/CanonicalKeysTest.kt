package com.singlemarks.angrymoti

import com.singlemarks.angrymoti.models.CancelReason
import com.singlemarks.angrymoti.models.CanonicalTag
import com.singlemarks.angrymoti.models.ScoreNote
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * G3 매핑 왕복 테스트 (docs/영어화-설계도.md §2).
 *
 * 세 가지를 못박는다:
 *  1) 키 → 표시 문구가 현행 한국어와 바이트 동일 (ko 회귀 0 원칙)
 *  2) 레거시 한글 → 키 역매핑이 실데이터 문구를 전부 해석
 *  3) canonical()은 멱등 — 키를 다시 넣어도 그대로 (스윕 재실행 무해의 근거)
 */
class CanonicalKeysTest {

    // ── 태그 ──

    @Test fun `태그 - 레거시 한글이 키로, 키가 원래 문구로 왕복`() {
        val pairs = mapOf(
            "공부" to "study", "독서" to "reading", "운동" to "workout",
            "작업" to "work", "연주" to "music", "글쓰기" to "writing", "그룹" to "group",
        )
        pairs.forEach { (ko, key) ->
            assertEquals(key, CanonicalTag.canonical(ko))
            assertEquals(ko, CanonicalTag.label(key))
            assertEquals(key, CanonicalTag.canonical(key))   // 멱등
        }
    }

    @Test fun `태그 - 개명 전 '악기'는 연주로 흡수, 커스텀은 원문 유지`() {
        assertEquals("music", CanonicalTag.canonical("악기"))
        assertEquals("연주", CanonicalTag.label("악기"))
        assertEquals("영어회화", CanonicalTag.canonical("영어회화"))
        assertEquals("영어회화", CanonicalTag.label("영어회화"))
    }

    // ── 취소 사유 ──

    @Test fun `사유 - 프리셋 4종 왕복 + 자유 입력 원문 유지`() {
        val pairs = mapOf(
            "급한 일이 생겼어요" to "reason.urgent",
            "몸이 좋지 않아요" to "reason.sick",
            "오늘은 쉬고싶어요" to "reason.rest",
            "긴급 용무 지속" to "reason.emergency_ongoing",
        )
        pairs.forEach { (ko, code) ->
            assertEquals(code, CancelReason.canonical(ko))
            assertEquals(ko, CancelReason.label(code))
            assertEquals(code, CancelReason.canonical(code))   // 멱등
        }
        assertEquals("병원 예약", CancelReason.canonical("병원 예약"))
        assertEquals("병원 예약", CancelReason.label("병원 예약"))
    }

    // ── 벌점 note (11종) ──

    @Test fun `note - 토큰 11종 각각 표시 문구가 현행 한국어와 바이트 동일`() {
        val cases = mapOf(
            ScoreNote.CAMERA_START_FAILED to "카메라 시작 실패",
            ScoreNote.RECORDING_INCOMPLETE to "촬영 불완전 — 영상 손상/부족",
            ScoreNote.RECORDING_STALLED to "촬영이 정상 진행되지 않음",
            ScoreNote.EXIT_IMMEDIATE to "이탈 즉시 실패",
            ScoreNote.APP_KILLED to "촬영 중 앱 종료 (배터리·강제 종료 등)",
            ScoreNote.noResume(10) to "10분 내 재촬영 없음",
            ScoreNote.noShowWindow(15) to "15분 내 미시작",
            ScoreNote.slotBonus(7) to "연속 7일 달성 — 활동 슬롯 확장 보너스",
            ScoreNote.absenceOver(3) to "자리비움 3회 초과 — 즉시 실패",
            ScoreNote.absenceMinutes(2) to "자리비움 2분 — 즉시 실패",
            ScoreNote.groupGiveup("아침 스터디") to "그룹 '아침 스터디' 중도 포기",
        )
        cases.forEach { (token, ko) ->
            assertEquals(ko, ScoreNote.label(token))
            // 레거시 문구를 다시 넣으면 같은 토큰으로 — 왕복 폐합
            assertEquals(token, ScoreNote.canonical(ko))
            assertEquals(token, ScoreNote.canonical(token))   // 멱등
        }
    }

    @Test fun `note - 취소 사유가 note 칸에 실려도 해석, 미지의 문구는 원문 폴백`() {
        assertEquals("reason.urgent", ScoreNote.canonical("급한 일이 생겼어요"))
        assertEquals("급한 일이 생겼어요", ScoreNote.label("reason.urgent"))
        // 자유 입력·변형 문구는 건드리지 않는다 (R2 안전 폴백)
        assertEquals("갑자기 정전", ScoreNote.canonical("갑자기 정전"))
        assertEquals("갑자기 정전", ScoreNote.label("갑자기 정전"))
        // 미래 토큰은 크래시 대신 원문 노출
        assertEquals("note.future_thing|3", ScoreNote.label("note.future_thing|3"))
    }

    @Test fun `note - 방 이름에 숫자·따옴표류 문자가 있어도 왕복`() {
        val token = ScoreNote.groupGiveup("새벽 5시 30분 팀")
        assertEquals("그룹 '새벽 5시 30분 팀' 중도 포기", ScoreNote.label(token))
        assertEquals(token, ScoreNote.canonical("그룹 '새벽 5시 30분 팀' 중도 포기"))
    }
}
