//
//  Models.swift
//  TimeLock
//
//  도메인 모델: 예약(자기계약), 세션(수행 기록), 점수 원장(트랜잭션).
//  규칙 변경 시 재계산이 가능하도록 원장은 원본 이벤트를 그대로 보존한다.
//

import Foundation
import SwiftData

// MARK: - 강도 (앱 전역 단일 값)

enum Intensity: String, Codable, CaseIterable, Identifiable {
    case spicy = "spicy"          // 매운맛
    case insane = "insane"        // 미친 매운맛

    var id: String { rawValue }
    var title: String { self == .spicy ? "매운맛" : "미친 매운맛" }
    var subtitle: String {
        self == .spicy
        ? "이탈하면 경고 후 10초 유예. 복귀하지 못하면 실패."
        : "유예도 사유도 없다. 이탈 즉시 실패, 벌점 2배."
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
         repeatWeekdays: [Int] = [], oneOffDate: Date? = nil) {
        self.id = UUID()
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
    case exitFailed     // 이탈 실패
    case noShow         // 5분 미시작 탈락
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
         scheduledAt: Date?, targetSeconds: Int, reservationID: UUID? = nil) {
        self.id = UUID()
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
    case unlockBonus    // 미친 매운맛 해금 보너스

    var title: String {
        switch self {
        case .complete:    return "완주 상점"
        case .exitFail:    return "이탈 벌점"
        case .noShow:      return "노쇼 벌점"
        case .emergency:   return "긴급 종료"
        case .unlockBonus: return "해금 보너스"
        }
    }
}

@Model
final class ScoreEvent {
    @Attribute(.unique) var id: UUID
    var typeRaw: String
    var points: Int
    var sessionID: UUID?
    var intensityRaw: String
    var timestamp: Date
    var note: String?

    init(type: ScoreEventType, points: Int, sessionID: UUID?,
         intensity: Intensity, note: String? = nil) {
        self.id = UUID()
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
    static func points(for outcome: SessionOutcome, intensity: Intensity) -> (ScoreEventType, Int)? {
        switch outcome {
        case .completed:
            return (.complete, intensity == .insane ? 15 : 10)
        case .exitFailed:
            return (.exitFail, intensity == .insane ? -20 : -10)   // 미친 매운맛 벌점 2배
        case .noShow:
            return (.noShow, -15)
        case .emergency:
            return (.emergency, intensity == .insane ? -10 : -5)
        case .safetyEnded:
            return nil  // 벌점 없음
        }
    }
}
