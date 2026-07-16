//
//  Models.swift
//  TimeLock
//
//  도메인 모델: 예약(다짐), 세션(수행 기록), 점수 원장(트랜잭션).
//  규칙 변경 시 재계산이 가능하도록 원장은 원본 이벤트를 그대로 보존한다.
//

import Foundation
import SwiftData
import UIKit

// MARK: - 세션 촬영 방향 (구도 단계에서 선택 → 촬영 내내 고정)

enum SessionOrientation: String, Codable, CaseIterable {
    case portrait   // 세로 거치
    case landscape  // 가로 거치

    var title: String { self == .portrait ? "세로" : "가로" }
    var icon: String { self == .portrait ? "iphone" : "iphone.landscape" }

    /// 세션 화면을 이 방향으로 '잠그는' 인터페이스 마스크.
    /// 단일 방향만 허용하므로 촬영 중 기기를 돌려도 UI가 요동치지 않는다.
    var interfaceMask: UIInterfaceOrientationMask {
        self == .portrait ? .portrait : .landscapeRight
    }
}

// MARK: - 시간 정책 (알람 창 · 재촬영 창)

enum TimePolicy {
    /// 알람 후 촬영을 시작해야 하는 창. 넘기면 노쇼 탈락.
    static let startWindowSeconds: TimeInterval = 600
    static var startWindowMinutes: Int { Int(startWindowSeconds) / 60 }
    /// 긴급 용무로 촬영을 중단한 뒤 재촬영을 시작해야 하는 창. 넘기면 벌점.
    static let resumeWindowSeconds: TimeInterval = 600
    static var resumeWindowMinutes: Int { Int(resumeWindowSeconds) / 60 }

    /// 활동 시간 선택 옵션(분). 예약·즉시 시작이 공용으로 사용해 서로 어긋나지 않게 한다.
    static let durationOptionsMinutes = [10, 15, 25, 30, 45, 60, 90, 120, 150, 180, 240, 300, 360, 480]
}

// MARK: - 활동 슬롯 정책 (원띵 원칙)
//
// 슬롯은 언제나 '현재 연속 달성일'이 정한다 — 연속이 오르내리면 한도가 자동으로 따라간다.
// 연속이 끊겨 한도가 내려가도 이미 만든 예약은 유지되고, 새 활동 추가만 제한된다.

enum SlotPolicy {
    static let baseSlots = 2

    /// 연속 달성일 단계표: (필요 연속일, 최대 활동 수). slots nil = 무제한.
    static let tiers: [(days: Int, slots: Int?)] = [
        (3, 3), (5, 4), (7, 5), (10, 10), (30, nil)
    ]

    /// 멤버십 회원은 연속일과 무관하게 최소 10개 보장 (연속 30일 무제한은 동일 적용)
    static let memberFloorSlots = 10

    /// 현재 연속 달성일로 허용되는 최대 활동 수 (nil = 무제한)
    static func allowedSlots(forStreak streak: Int, isMember: Bool = false) -> Int? {
        var allowed: Int? = baseSlots
        for tier in tiers where streak >= tier.days {
            allowed = tier.slots
        }
        guard let ladder = allowed else { return nil }   // 무제한
        return isMember ? max(memberFloorSlots, ladder) : ladder
    }

    /// 다음 단계 (없으면 이미 최고 단계)
    static func nextTier(afterStreak streak: Int) -> (days: Int, slots: Int?)? {
        tiers.first { $0.days > streak }
    }

    /// 오늘(기록 없으면 어제)부터 거꾸로 — 실패 없이 완주한 날의 연속 수.
    /// 캘린더 대시보드의 '연속 달성일'과 동일한 정의를 공유한다.
    static func currentStreak(sessions: [FocusSession]) -> Int {
        let calendar = Calendar.current
        let finished = sessions.filter { $0.outcome != nil }
        var count = 0
        var day = calendar.startOfDay(for: .now)
        while true {
            let daySessions = finished.filter { calendar.isDate($0.anchorDate, inSameDayAs: day) }
            let success = daySessions.contains { $0.outcome?.isSuccess == true }
            let failure = daySessions.contains { $0.outcome?.isFailure == true }
            if success && !failure {
                count += 1
            } else if count == 0 && daySessions.isEmpty && calendar.isDateInToday(day) {
                // 오늘 아직 기록 없음 → 어제부터 계산
            } else {
                break
            }
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }
}

// MARK: - 강도 (앱 전역 단일 값)

enum Intensity: String, Codable, CaseIterable, Identifiable {
    case spicy = "spicy"          // 매운맛
    case insane = "insane"        // 미친 매운맛

    var id: String { rawValue }
    var title: String { self == .spicy ? "매운맛" : "미친 매운맛" }
    var subtitle: String {
        self == .spicy
        ? "긴급 용무로 중단해도 10분 안에 재촬영하면 벌점 없음."
        : "유예도 사유도 없다. 이탈 즉시 실패. 상점 2배, 벌점 2배."
    }
    var emoji: String { self == .spicy ? "🌶️" : "🔥" }
}

// MARK: - 태그 프리셋

enum ActivityTag {
    static let presets = ["공부", "독서", "운동", "작업", "악기", "글쓰기"]
}

// MARK: - 예약

@Model
final class Reservation {
    @Attribute(.unique) var id: UUID
    /// 이 예약의 소유 계정 (AccountStore.currentUserID). 게스트는 "guest".
    var ownerUserID: String = ""
    var name: String
    var tag: String
    /// 하루 중 시작 시각(자정 기준 분). 일회성은 date와 조합.
    var startMinute: Int
    /// 지속 시간(분). 최소 10, 최대 480.
    var durationMinutes: Int
    /// 반복 요일 (1=일 ... 7=토, Calendar.weekday). 비어 있으면 일회성.
    var repeatWeekdays: [Int]
    /// 일회성 예약의 날짜(자정). 반복 예약은 nil.
    var oneOffDate: Date?
    var createdAt: Date
    var isActive: Bool

    init(name: String, tag: String, startMinute: Int, durationMinutes: Int,
         repeatWeekdays: [Int] = [], oneOffDate: Date? = nil, ownerUserID: String = "") {
        self.id = UUID()
        self.ownerUserID = ownerUserID
        self.name = name
        self.tag = tag
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.repeatWeekdays = repeatWeekdays
        self.oneOffDate = oneOffDate
        self.createdAt = .now
        self.isActive = true
    }

    var isRepeating: Bool { !repeatWeekdays.isEmpty }

    /// 주어진 날짜에 발생하는 예약이면 그 날의 시작 Date 반환
    func occurrence(on day: Date, calendar: Calendar = .current) -> Date? {
        let dayStart = calendar.startOfDay(for: day)
        if isRepeating {
            let weekday = calendar.component(.weekday, from: dayStart)
            guard repeatWeekdays.contains(weekday) else { return nil }
        } else {
            guard let d = oneOffDate,
                  calendar.isDate(d, inSameDayAs: dayStart) else { return nil }
        }
        return calendar.date(byAdding: .minute, value: startMinute, to: dayStart)
    }

    /// 다음 발생 시각 (지금 이후)
    func nextOccurrence(after date: Date = .now, calendar: Calendar = .current) -> Date? {
        for offset in 0..<28 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)),
                  let start = occurrence(on: day, calendar: calendar) else { continue }
            if start > date { return start }
        }
        return nil
    }

    /// 시간 구간 겹침 판정 (같은 날 기준, 분 단위)
    func overlaps(startMinute other: Int, duration: Int) -> Bool {
        let aStart = startMinute, aEnd = startMinute + durationMinutes
        let bStart = other, bEnd = other + duration
        return aStart < bEnd && bStart < aEnd
    }
}

// MARK: - 세션

enum SessionOutcome: String, Codable {
    case completed      // 완주 (자동 종료 도달)
    case exitFailed     // 이탈 실패 (재촬영 창 초과 포함)
    case noShow         // 10분 미시작 탈락
    case emergency      // 긴급 종료
    case safetyEnded    // 안전 종료 (배터리/저장공간/크래시/통화 불능)

    var title: String {
        switch self {
        case .completed:   return "완주"
        case .exitFailed:  return "이탈 실패"
        case .noShow:      return "노쇼 탈락"
        case .emergency:   return "긴급 종료"
        case .safetyEnded: return "안전 종료"
        }
    }
    var isSuccess: Bool { self == .completed }
    /// 캘린더 색 판정에서 '실패'로 치는가 (안전 종료는 중립)
    var isFailure: Bool { self == .exitFailed || self == .noShow }
}

@Model
final class FocusSession {
    @Attribute(.unique) var id: UUID
    /// 이 세션의 소유 계정. 게스트는 "guest".
    var ownerUserID: String = ""
    var activityName: String
    var tag: String
    var intensityRaw: String
    var scheduledAt: Date?          // 예약 세션이면 예약 시각, 즉시 세션이면 nil
    var startedAt: Date?            // 촬영 시작 시각 (노쇼는 nil)
    var endedAt: Date?
    var targetSeconds: Int          // 목표 순수 촬영 시간
    var recordedSeconds: Int        // 실제 순수 촬영 시간
    var outcomeRaw: String?
    var emergencyReason: String?
    var videoFileName: String?      // Documents/Sessions/ 내 파일명
    var thumbnailFileName: String?
    var reservationID: UUID?

    init(activityName: String, tag: String, intensity: Intensity,
         scheduledAt: Date?, targetSeconds: Int, reservationID: UUID? = nil,
         ownerUserID: String = "") {
        self.id = UUID()
        self.ownerUserID = ownerUserID
        self.activityName = activityName
        self.tag = tag
        self.intensityRaw = intensity.rawValue
        self.scheduledAt = scheduledAt
        self.targetSeconds = targetSeconds
        self.recordedSeconds = 0
        self.reservationID = reservationID
    }

    var intensity: Intensity { Intensity(rawValue: intensityRaw) ?? .spicy }
    var outcome: SessionOutcome? {
        get { outcomeRaw.flatMap(SessionOutcome.init(rawValue:)) }
        set { outcomeRaw = newValue?.rawValue }
    }
    var anchorDate: Date { startedAt ?? scheduledAt ?? .now }

    var videoURL: URL? {
        guard let name = videoFileName else { return nil }
        return SessionStorage.directory.appendingPathComponent(name)
    }
    var thumbnailURL: URL? {
        guard let name = thumbnailFileName else { return nil }
        return SessionStorage.directory.appendingPathComponent(name)
    }
}

enum SessionStorage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        return base
    }
    static func deleteFiles(of session: FocusSession) {
        if let v = session.videoURL { try? FileManager.default.removeItem(at: v) }
        if let t = session.thumbnailURL { try? FileManager.default.removeItem(at: t) }
    }
}

// MARK: - 점수 원장

enum ScoreEventType: String, Codable, CaseIterable {
    case complete       // 완주 상점
    case exitFail       // 이탈 벌점
    case noShow         // 노쇼 벌점
    case emergency      // 긴급 벌점
    case unlockBonus    // 미친 매운맛 잠금 해제 보너스
    case absence        // 촬영 중 자리비움 벌점 (사람 부재 감지)
    case penaltyReset   // 멤버십 가입 시 누적 벌점 리셋 (상쇄 이벤트 — 원장은 불변)
    case slotBonus      // 연속 달성으로 슬롯이 확장되는 순간의 보너스 상점

    var title: String {
        switch self {
        case .complete:     return "완주 상점"
        case .exitFail:     return "이탈 벌점"
        case .noShow:       return "노쇼 벌점"
        case .emergency:    return "긴급 종료"
        case .unlockBonus:  return "잠금 해제 보너스"
        case .absence:      return "자리비움 벌점"
        case .penaltyReset: return "멤버십 벌점 리셋"
        case .slotBonus:    return "슬롯 확장 보너스"
        }
    }
}

@Model
final class ScoreEvent {
    @Attribute(.unique) var id: UUID
    /// 이 점수의 소유 계정. 게스트는 "guest".
    var ownerUserID: String = ""
    var typeRaw: String
    var points: Int
    var sessionID: UUID?
    var intensityRaw: String
    var timestamp: Date
    var note: String?

    init(type: ScoreEventType, points: Int, sessionID: UUID?,
         intensity: Intensity, note: String? = nil, ownerUserID: String = "") {
        self.id = UUID()
        self.ownerUserID = ownerUserID
        self.typeRaw = type.rawValue
        self.points = points
        self.sessionID = sessionID
        self.intensityRaw = intensity.rawValue
        self.timestamp = .now
        self.note = note
    }

    var type: ScoreEventType { ScoreEventType(rawValue: typeRaw) ?? .complete }
    var intensity: Intensity { Intensity(rawValue: intensityRaw) ?? .spicy }
}

// MARK: - 점수 규칙 엔진

enum ScoreRules {
    /// 완주 상점은 활동 길이에 따라 커진다 (벌점은 길이와 무관하게 기존 유지).
    /// 10분~1시간 +10 · 1시간 30분~3시간 +20 · 4시간~8시간 +30
    static func completionBase(forMinutes minutes: Int) -> Int {
        switch minutes {
        case ..<90:  return 10
        case ..<240: return 20
        default:     return 30
        }
    }

    /// 미친 매운맛은 상점도 2배, 벌점도 2배 — 하이 리스크 하이 리턴.
    static func points(for outcome: SessionOutcome, intensity: Intensity,
                       durationMinutes: Int) -> (ScoreEventType, Int)? {
        let multiplier = intensity == .insane ? 2 : 1
        switch outcome {
        case .completed:   return (.complete, completionBase(forMinutes: durationMinutes) * multiplier)
        case .exitFailed:  return (.exitFail, -10 * multiplier)
        case .noShow:      return (.noShow, -15 * multiplier)
        case .emergency:   return (.emergency, -5 * multiplier)
        case .safetyEnded: return nil  // 벌점 없음
        }
    }
}
