package com.singlemarks.angrymoti.models

import com.singlemarks.angrymoti.data.FocusSession
import java.util.Calendar

/**
 * '그날의 성취 아이콘' 판정 — 홈 연속달성 스트립과 기록 캘린더가 같은 규칙 하나를 쓴다.
 * 화면마다 따로 계산하면 같은 날이 홈과 캘린더에서 다르게 보인다. 규칙은 여기 한 곳에만 둔다.
 * iOS DayOutcomeIcon.swift와 1:1 — 판정을 바꿀 땐 반드시 양쪽을 함께 수정한다.
 */
enum class DayOutcome {
    SUCCESS,        // 판정 대상 기록이 전부 성공
    HALF,           // 성공·실패 혼재 (과거 날짜에만)
    FAIL,           // 전부 실패 (노쇼·이탈)
    NOT_STARTED;    // 아직 시작 안 함(오늘) / 아직 오지 않은 날(미래)

    companion object {
        private const val ONE_DAY = 86_400_000L

        fun startOfDay(t: Long): Long = Calendar.getInstance().apply {
            timeInMillis = t
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis

        /**
         * 하루 판정. 반환 null = 판정 대상 기록이 없는 과거 날
         * (캘린더는 아이콘을 그리지 않고, 홈 스트립은 NOT_STARTED로 대체한다).
         *
         * - 판정 단위는 세션 낱개가 아니라 '발생(예약별 그날 1회, 즉시 시작은 세션별)'의
         *   **최종 결과**다. 긴급 중단 후 재촬영해 완주하면 그 발생은 성공이지, 성공·실패
         *   혼재가 아니다 — 일정 탭·홈 카드의 결과 점과 같은 기준이라 세 화면이 늘 일치한다.
         * - 성공이 아닌 모든 최종 결과(노쇼·이탈·긴급 종료·안전 종료)는 실패로 본다 —
         *   일정 탭 표시등과 동일한 2색 정책. 안전 종료(무효)는 벌점화만 안 될 뿐
         *   완주하지 못한 사실은 같다.
         * - 오늘은 하루가 끝나지 않았으므로 낙관 판정: 발생 1개라도 성공으로 끝났으면 일단
         *   SUCCESS, 자정이 지나 과거가 되면 과거 규칙(전부/혼재/전부실패)으로 확정된다.
         *   자정을 넘겨 진행한 세션은 anchorAt(발생일 귀속)을 따르므로 — 밤 11시에 시작해
         *   새벽에 완주해도 시작한 그날의 SUCCESS로 남는다 (연속달성 정책과 동일).
         */
        fun judge(
            daySessions: List<FocusSession>, day: Long,
            now: Long = System.currentTimeMillis(),
        ): DayOutcome? {
            val today = startOfDay(now)
            val target = startOfDay(day)
            if (target > today) return NOT_STARTED          // 아직 오지 않은 날

            val finals = finalOutcomes(daySessions)

            // 성공 / 실패 — 성공이 아니면 전부 실패 (2색 정책, 일정 탭 표시등과 동일)
            val hasSuccess = finals.any { it.isSuccess }
            val hasFailure = finals.any { !it.isSuccess }

            if (target == today) {
                if (hasSuccess) return SUCCESS              // 발생 1개라도 성공 — 일단 성공
                if (hasFailure) return FAIL
                return NOT_STARTED                          // 아직 아무것도 시작 안 함
            }

            // 과거 날
            if (!hasSuccess && !hasFailure) return null
            if (hasSuccess && hasFailure) return HALF
            return if (hasSuccess) SUCCESS else FAIL
        }

        /**
         * 그날의 '발생별 최종 결과' 목록.
         * 같은 예약의 기록이 여럿이면(긴급 중단 후 재촬영) 가장 나중 것만 남긴다 —
         * 즉시 시작(예약 없음)은 세션 하나가 곧 발생 하나다.
         */
        fun finalOutcomes(daySessions: List<FocusSession>): List<SessionOutcome> {
            val finished = daySessions.filter { it.outcome != null }
            return finished.groupBy { it.reservationID ?: it.id }
                .values.mapNotNull { records ->
                    records.maxByOrNull { it.endedAt ?: it.anchorAt }?.outcome
                }
        }

        /** 그날 성공으로 끝낸 발생 수 — 연속달성 '평균 일정'의 분자. */
        fun successCount(daySessions: List<FocusSession>): Int =
            finalOutcomes(daySessions).count { it.isSuccess }
    }
}
