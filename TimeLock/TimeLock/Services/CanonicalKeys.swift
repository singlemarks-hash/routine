//
//  CanonicalKeys.swift
//  TimeLock
//
//  저장 데이터의 언어 중립 정본 키 (docs/영어화-설계도.md D3).
//
//  태그·취소 사유·벌점 note를 한글 문구 대신 소문자 키/토큰으로 저장한다.
//  - 쓰기: 항상 키로 쓴다 (이 파일의 상수·빌더만 사용).
//  - 읽기: 키·레거시 한글 둘 다 해석한다. 과거 기록은 영원히 한글이므로
//    레거시 → 키 역매핑은 영구 유지한다 (삭제 금지).
//  - 표시: label()이 로케일 문구로 푼다. 지금은 한국어 원문(바이트 동일),
//    Phase 1에서 String Catalog(NSLocalizedString) 참조로 전환된다.
//
//  ⚠️ 키 문자열은 Firestore·Android와 공유되는 유선 포맷이다 — 한 글자도 바꾸지 말 것.
//

import Foundation
import SwiftData

// MARK: - 태그 (7종)

enum CanonicalTag {
    /// 예약 편집·즉시 시작의 선택지 (그룹 제외 — 그룹 예약은 시스템이 만든다)
    static let presets = ["study", "reading", "workout", "work", "music", "writing"]
    static let group = "group"

    /// 레거시 한글 → 키. '악기'는 '연주'로 개명된 옛 이름 — 같은 키로 흡수한다.
    private static let legacy: [String: String] = [
        "공부": "study", "독서": "reading", "운동": "workout",
        "작업": "work", "연주": "music", "악기": "music",
        "글쓰기": "writing", "그룹": "group",
    ]

    /// 저장값 → 정본 키. 프리셋도 레거시도 아니면(직접 입력 태그) 원문 그대로.
    static func canonical(_ raw: String) -> String { legacy[raw] ?? raw }

    /// 저장값 → 표시 문구. 커스텀 태그는 사용자가 쓴 원문 그대로 보여준다.
    static func label(_ raw: String) -> String {
        switch canonical(raw) {
        case "study":   return "공부"
        case "reading": return "독서"
        case "workout": return "운동"
        case "work":    return "작업"
        case "music":   return "연주"
        case "writing": return "글쓰기"
        case "group":   return "그룹"
        default:        return raw
        }
    }
}

// MARK: - 일정 취소 사유 (프리셋 3 + 긴급 지속, 자유 입력은 원문 저장)

enum CancelReason {
    /// 취소 시트의 프리셋 순서 그대로
    static let presets = ["reason.urgent", "reason.sick", "reason.rest"]
    /// 긴급 용무 재촬영 창에서 '일정 취소'를 고른 경우
    static let emergencyOngoing = "reason.emergency_ongoing"

    private static let legacy: [String: String] = [
        "급한 일이 생겼어요": "reason.urgent",
        "몸이 좋지 않아요": "reason.sick",
        "오늘은 쉬고싶어요": "reason.rest",
        "긴급 용무 지속": "reason.emergency_ongoing",
    ]

    static func canonical(_ raw: String) -> String { legacy[raw] ?? raw }

    static func label(_ raw: String) -> String {
        switch canonical(raw) {
        case "reason.urgent":            return "급한 일이 생겼어요"
        case "reason.sick":              return "몸이 좋지 않아요"
        case "reason.rest":              return "오늘은 쉬고싶어요"
        case "reason.emergency_ongoing": return "긴급 용무 지속"
        default:                         return raw   // 자유 입력 사유
        }
    }
}

// MARK: - 벌점/보너스 note 토큰 (`note.코드` 또는 `note.코드|인자`)

enum ScoreNote {
    // 인자 없는 토큰
    static let cameraStartFailed = "note.camera_start_failed"      // 카메라 시작 실패
    static let recordingIncomplete = "note.recording_incomplete"   // 영상 손상/부족
    static let recordingStalled = "note.recording_stalled"         // 촬영이 정상 진행되지 않음
    static let exitImmediate = "note.exit_immediate"               // 미친 매운맛 이탈 즉시 실패
    static let appKilled = "note.app_killed"                       // 촬영 중 앱 종료

    // 인자 있는 토큰 빌더
    static func noResume(minutes: Int) -> String { "note.no_resume|\(minutes)" }
    static func noShowWindow(minutes: Int) -> String { "note.noshow_window|\(minutes)" }
    static func slotBonus(days: Int) -> String { "note.slot_bonus|\(days)" }
    static func absenceOver(count: Int) -> String { "note.absence_over|\(count)" }
    static func absenceMinutes(_ minutes: Int) -> String { "note.absence_minutes|\(minutes)" }
    static func groupGiveup(roomName: String) -> String { "note.group_giveup|\(roomName)" }

    /// 레거시 한글 note → 토큰. 매칭 안 되면(자유 입력 긴급 사유 등) 원문 그대로.
    /// 취소 사유 프리셋도 note 칸에 실려 있으므로 함께 해석한다.
    static func canonical(_ raw: String) -> String {
        switch raw {
        case "카메라 시작 실패":                    return cameraStartFailed
        case "촬영 불완전 — 영상 손상/부족":         return recordingIncomplete
        case "촬영이 정상 진행되지 않음":            return recordingStalled
        case "이탈 즉시 실패":                      return exitImmediate
        case "촬영 중 앱 종료 (배터리·강제 종료 등)": return appKilled
        default: break
        }
        if let n = argument(of: raw, prefix: "", suffix: "분 내 재촬영 없음") { return noResume(minutes: n) }
        if let n = argument(of: raw, prefix: "", suffix: "분 내 미시작") { return noShowWindow(minutes: n) }
        if let n = argument(of: raw, prefix: "연속 ", suffix: "일 달성 — 활동 슬롯 확장 보너스") { return slotBonus(days: n) }
        if let n = argument(of: raw, prefix: "자리비움 ", suffix: "회 초과 — 즉시 실패") { return absenceOver(count: n) }
        if let n = argument(of: raw, prefix: "자리비움 ", suffix: "분 — 즉시 실패") { return absenceMinutes(n) }
        if raw.hasPrefix("그룹 '"), raw.hasSuffix("' 중도 포기") {
            let name = String(raw.dropFirst("그룹 '".count).dropLast("' 중도 포기".count))
            return groupGiveup(roomName: name)
        }
        return CancelReason.canonical(raw)
    }

    /// 저장값(토큰·레거시 한글·자유 입력) → 표시 문구.
    static func label(_ raw: String) -> String {
        guard raw.hasPrefix("note.") else { return CancelReason.label(raw) }
        let body = raw.dropFirst("note.".count)
        let parts = body.split(separator: "|", maxSplits: 1).map(String.init)
        let code = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        switch code {
        case "camera_start_failed":  return "카메라 시작 실패"
        case "recording_incomplete": return "촬영 불완전 — 영상 손상/부족"
        case "recording_stalled":    return "촬영이 정상 진행되지 않음"
        case "exit_immediate":       return "이탈 즉시 실패"
        case "app_killed":           return "촬영 중 앱 종료 (배터리·강제 종료 등)"
        case "no_resume":            return "\(arg)분 내 재촬영 없음"
        case "noshow_window":        return "\(arg)분 내 미시작"
        case "slot_bonus":           return "연속 \(arg)일 달성 — 활동 슬롯 확장 보너스"
        case "absence_over":         return "자리비움 \(arg)회 초과 — 즉시 실패"
        case "absence_minutes":      return "자리비움 \(arg)분 — 즉시 실패"
        case "group_giveup":         return "그룹 '\(arg)' 중도 포기"
        default:                     return raw   // 미래 토큰 — 원문 노출이 크래시보다 낫다
        }
    }

    /// "\(prefix)N\(suffix)" 꼴에서 N을 뽑는다. 전체가 정확히 그 꼴일 때만.
    private static func argument(of raw: String, prefix: String, suffix: String) -> Int? {
        guard raw.hasPrefix(prefix), raw.hasSuffix(suffix),
              raw.count > prefix.count + suffix.count else { return nil }
        let mid = raw.dropFirst(prefix.count).dropLast(suffix.count)
        guard !mid.isEmpty, mid.allSatisfy(\.isNumber) else { return nil }
        return Int(mid)
    }
}

// MARK: - 로컬 DB 1회 스윕 (레거시 한글 → 키 재작성)

/// 앱 시작 시 한 번, 로컬 SwiftData의 태그·사유·note를 정본 키로 재작성한다.
/// canonical(키) == 키 라서 몇 번을 돌아도 결과가 같다(멱등) — 플래그는 낭비 방지용일 뿐이다.
/// 클라우드 사본은 지우거나 고치지 않는다: 읽기 호환(레거시 역매핑)이 영구라 옛 문서는 그대로 둬도
/// 표시가 맞고, 다음 미러 때 자연히 키로 덮인다. (불변식 4는 '삭제' 이야기 — 재작성은 해당 없음)
enum L10nKeySweep {
    private static let flag = "l10n.keySweep.v1"

    static func runIfNeeded(context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        var changed = 0

        if let reservations = try? context.fetch(FetchDescriptor<Reservation>()) {
            for r in reservations {
                let key = CanonicalTag.canonical(r.tag)
                if key != r.tag { r.tag = key; changed += 1 }
            }
        }
        if let sessions = try? context.fetch(FetchDescriptor<FocusSession>()) {
            for s in sessions {
                let key = CanonicalTag.canonical(s.tag)
                if key != s.tag { s.tag = key; changed += 1 }
                if let reason = s.emergencyReason {
                    let token = ScoreNote.canonical(reason)
                    if token != reason { s.emergencyReason = token; changed += 1 }
                }
            }
        }
        if let events = try? context.fetch(FetchDescriptor<ScoreEvent>()) {
            for e in events {
                if let note = e.note {
                    let token = ScoreNote.canonical(note)
                    if token != note { e.note = token; changed += 1 }
                }
            }
        }

        do {
            try context.save()
            defaults.set(true, forKey: flag)   // 저장이 성공했을 때만 완료 처리 — 실패 시 다음 실행에 재시도
            if changed > 0 { print("✅ [TimeLock] L10n 키 스윕 완료 — \(changed)건 재작성") }
        } catch {
            print("⚠️ [TimeLock] L10n 키 스윕 저장 실패: \(error.localizedDescription)")
        }
    }
}
