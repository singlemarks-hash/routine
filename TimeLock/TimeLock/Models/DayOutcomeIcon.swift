//
//  DayOutcomeIcon.swift
//  TimeLock
//
//  '그날의 성취 아이콘' 판정 — 홈 연속달성 스트립과 기록 캘린더가 같은 규칙 하나를 쓴다.
//  화면마다 따로 계산하면 같은 날이 홈과 캘린더에서 다르게 보인다(반복 표기에서 실제로
//  났던 사고 유형). 규칙은 여기 한 곳에만 둔다.
//

import Foundation

enum DayOutcomeIcon: String {
    case success        // 판정 대상 기록이 전부 성공
    case half           // 성공·실패 혼재 (과거 날짜에만)
    case fail           // 전부 실패 (노쇼·이탈)
    case notStarted     // 아직 시작 안 함(오늘) / 아직 오지 않은 날(미래)

    /// Assets.xcassets의 imageset 이름
    var assetName: String {
        switch self {
        case .success: return "success"
        case .half: return "half"
        case .fail: return "fail"
        case .notStarted: return "not_started"
        }
    }

    /// 하루 판정. 반환 nil = 판정 대상 기록이 없는 과거 날
    /// (캘린더는 아이콘을 그리지 않고, 홈 스트립은 notStarted로 대체한다).
    ///
    /// - 판정 단위는 세션 낱개가 아니라 '발생(예약별 그날 1회, 즉시 시작은 세션별)'의
    ///   **최종 결과**다. 긴급 중단 후 재촬영해 완주하면 그 발생은 성공이지, 성공·실패
    ///   혼재가 아니다 — 일정 탭·홈 카드의 결과 점과 같은 기준이라 세 화면이 늘 일치한다.
    /// - 긴급 종료(일정 취소·세션 포기)는 실패로 본다 — 일정 탭이 빨간불을 켜는 것과 동일.
    ///   안전 종료(배터리·기기 사정)만 중립으로 판정에서 제외한다.
    /// - 오늘은 하루가 끝나지 않았으므로 낙관 판정: 발생 1개라도 성공으로 끝났으면 일단
    ///   success, 자정이 지나 과거가 되면 과거 규칙(전부/혼재/전부실패)으로 확정된다.
    ///   자정을 넘겨 진행한 세션은 anchorDate(발생일 귀속)를 따르므로 — 밤 11시에 시작해
    ///   새벽에 완주해도 시작한 그날의 success로 남는다 (연속달성 정책과 동일).
    static func judge(daySessions: [FocusSession], day: Date,
                      calendar: Calendar = .current, now: Date = .now) -> DayOutcomeIcon? {
        let today = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: day)
        if target > today { return .notStarted }        // 아직 오지 않은 날

        // 발생별 최종 결과 — 같은 예약의 기록이 여럿이면(긴급 중단 후 재촬영) 가장 나중 것.
        // 즉시 시작(예약 없음)은 세션 하나가 곧 발생 하나다.
        let finished = daySessions.filter { $0.outcome != nil }
        let byOccurrence = Dictionary(grouping: finished) {
            $0.reservationID?.uuidString ?? $0.id.uuidString
        }
        let finals = byOccurrence.values.compactMap { records in
            records.max { ($0.endedAt ?? $0.anchorDate) < ($1.endedAt ?? $1.anchorDate) }?.outcome
        }

        // 성공 / 실패(노쇼·이탈·긴급 종료) — 안전 종료(중립)만 제외
        let hasSuccess = finals.contains { $0.isSuccess }
        let hasFailure = finals.contains { $0.isFailure || $0 == .emergency }

        if target == today {
            if hasSuccess { return .success }           // 발생 1개라도 성공 — 일단 성공
            if hasFailure { return .fail }
            return .notStarted                          // 아직 아무것도 시작 안 함
        }

        // 과거 날
        guard hasSuccess || hasFailure else { return nil }
        if hasSuccess && hasFailure { return .half }
        return hasSuccess ? .success : .fail
    }
}
