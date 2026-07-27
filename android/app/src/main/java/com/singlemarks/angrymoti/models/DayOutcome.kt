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
    HALF,           // 성공·실패 혼재
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
         * - 단 하나의 예외: 그날 최종 결과가 **전부 안전 종료(무효)**면 HALF(노란 체크)를 쓴다.
         *   전부가 기기 사정으로 무효가 된 날에 빨간 X를 찍으면 사용자 잘못이 아닌 것을
         *   실패로 기록하는 셈이다. 극히 드문 상황이라 별도 아이콘 없이 HALF를 승계한다.
         * - 오늘은 하루가 끝나지 않았으므로 **아직 실패가 없을 때만** 낙관 판정한다:
         *   성공만 있으면 SUCCESS로 두고, 남은 발생이 실패로 끝나면 그때 HALF로 내려간다.
         *   반대로 성공·실패가 이미 하나씩 확정된 날은 낙관할 여지가 없다 — 무엇이 더
         *   와도 혼재를 벗어나지 못하는 흡수 상태라, 오늘도 곧바로 HALF로 확정한다.
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

            // 전부 안전 종료(무효)인 날 — 사용자 잘못이 아니므로 빨간 X 대신 노란 체크(HALF).
            // 오늘이어도 같다: 이후 성공/실패가 확정되면 아래 일반 규칙이 다시 판정한다.
            if (finals.isNotEmpty() && finals.all { it == SessionOutcome.SAFETY_ENDED }) return HALF

            // 성공 / 실패 — 성공이 아니면 전부 실패 (2색 정책, 일정 탭 표시등과 동일)
            val hasSuccess = finals.any { it.isSuccess }
            val hasFailure = finals.any { !it.isSuccess }

            if (target == today) {
                // 혼재는 '흡수 상태'다 — 성공과 실패가 이미 하나씩 확정된 뒤에는 남은 발생이
                // 무엇으로 끝나든 결과가 혼재를 벗어나지 못한다. 그래서 낙관 판정의 대상이
                // 아니다. (성공만 있는 날을 SUCCESS로 두는 것이 낙관 판정의 전부다 — 뒤에
                // 실패가 붙으면 그때 HALF로 내려간다.)
                if (hasSuccess && hasFailure) return HALF
                if (hasSuccess) return SUCCESS              // 아직 실패 없음 — 일단 성공
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
                    // 동률(같은 endedAt) 때 세션 ID 사전순 — 플랫폼·실행마다 다른 쪽을 고르면
                    // 같은 데이터가 두 기기에서 다른 아이콘이 된다 (iOS와 동일 규칙)
                    records.maxWithOrNull(
                        compareBy({ it.endedAt ?: it.anchorAt }, { it.id })
                    )?.outcome
                }
        }

        /** 그날 성공으로 끝낸 발생 수 — 연속달성 '평균 일정'의 분자. */
        fun successCount(daySessions: List<FocusSession>): Int =
            finalOutcomes(daySessions).count { it.isSuccess }
    }
}
