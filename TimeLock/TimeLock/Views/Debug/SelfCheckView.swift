//
//  SelfCheckView.swift
//  TimeLock — 개발용 자가진단
//
//  이번에 고친 규칙들을 '실제 코드'로 돌려 한 화면에서 확인한다.
//  시간이 지나야 재현되는 버그(만료 정리·알람 유실 등)와 달리, 계산 규칙은
//  여기서 즉시 검증되므로 회귀를 빠르게 잡을 수 있다.
//
//  릴리즈 빌드에는 포함되지 않는다 (#if DEBUG).
//  안드로이드를 이식할 때도 같은 시나리오를 그대로 대조하면 된다.
//

#if DEBUG
import SwiftUI
import SwiftData

// MARK: - 결과 모델

private struct CheckResult: Identifiable {
    let id = UUID()
    let group: String
    let name: String
    let passed: Bool
}

// MARK: - 화면

struct SelfCheckView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppState
    /// 비활성(소프트 삭제)까지 포함해 원본 상태를 그대로 본다
    @Query private var allReservations: [Reservation]

    @State private var results: [CheckResult] = []
    @State private var actionLog: String = ""

    private var passed: Int { results.filter(\.passed).count }
    private var failed: [CheckResult] { results.filter { !$0.passed } }

    var body: some View {
        NavigationStack {
            List {
                summarySection
                if !failed.isEmpty { failureSection }
                resultsSection
                actionsSection
                dumpSection
            }
            .navigationTitle("자가진단")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("다시 실행") { results = SelfCheck.runAll() }
                }
            }
            .onAppear { if results.isEmpty { results = SelfCheck.runAll() } }
        }
    }

    private var summarySection: some View {
        Section {
            HStack {
                Text(failed.isEmpty ? "✅ 전부 통과" : "❌ 실패 \(failed.count)건")
                    .font(.headline)
                    .foregroundStyle(failed.isEmpty ? .green : .red)
                Spacer()
                Text("\(passed)/\(results.count)").foregroundStyle(.secondary)
            }
        }
    }

    private var failureSection: some View {
        Section("실패한 항목") {
            ForEach(failed) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name).font(.system(size: 14, weight: .semibold))
                    Text(r.group).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var resultsSection: some View {
        ForEach(Array(Set(results.map(\.group))).sorted(), id: \.self) { group in
            Section(group) {
                ForEach(results.filter { $0.group == group }) { r in
                    HStack {
                        Text(r.passed ? "✅" : "❌")
                        Text(r.name).font(.system(size: 13))
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section("실행") {
            Button("지금 노쇼 집계 실행") {
                app.sweepNoShows()
                actionLog = "노쇼 집계 실행됨 — 기록 탭에서 확인하세요."
            }
            Button("만료 예약 정리 실행") {
                app.cleanupExpiredReservations()
                actionLog = "만료 정리 실행됨 — 아래 목록의 활성 여부를 확인하세요."
            }
            Button("알람 다시 걸기") {
                app.rescheduleAlarmsForCurrentUser()
                actionLog = "알람 재스케줄됨."
            }
            if !actionLog.isEmpty {
                Text(actionLog).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var dumpSection: some View {
        Section("예약 원본 상태 (비활성 포함 \(allReservations.count)건)") {
            ForEach(allReservations) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(r.isActive ? "활성" : "비활성") · \(r.name)")
                        .font(.system(size: 13, weight: .semibold))
                    Text(SelfCheck.describe(r))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 검사 본체

private enum SelfCheck {

    static let cal = Calendar.current
    static let all7 = [1, 2, 3, 4, 5, 6, 7]

    static func runAll() -> [CheckResult] {
        var out: [CheckResult] = []
        out += occurrenceChecks()
        out += conflictChecks()
        out += rangeChecks()
        out += deadReservationChecks()
        out += groupRoomChecks()
        return out
    }

    // MARK: 도구

    private static func day(_ offset: Int, from base: Date = Date()) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: base))!
    }

    /// 앱이 종료일을 저장하는 방식과 동일 (그 날의 끝)
    private static func endOfDay(_ d: Date) -> Date {
        cal.startOfDay(for: d).addingTimeInterval(86_400 - 0.001)
    }

    /// 오늘 이후로 그 요일이 처음 오는 날 (연도에 의존하지 않게 상대 계산)
    private static func firstDay(weekday: Int) -> Date {
        var d = cal.startOfDay(for: Date())
        for _ in 0..<7 {
            if cal.component(.weekday, from: d) == weekday { return d }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return d
    }

    private static func make(start: Date, end: Date?, weekdays: [Int],
                             startMinute: Int, duration: Int,
                             oneOff: Date? = nil) -> Reservation {
        let r = Reservation(name: "검사", tag: "검사", startMinute: startMinute,
                            durationMinutes: duration, repeatWeekdays: weekdays,
                            oneOffDate: oneOff, ownerUserID: "selfcheck")
        r.createdAt = start
        r.endDate = end
        return r
    }

    private static func check(_ group: String, _ name: String,
                              _ actual: Bool, _ expected: Bool) -> CheckResult {
        CheckResult(group: group, name: name, passed: actual == expected)
    }

    // MARK: 1. 발생 판정 (시작일·종료일 게이트)

    private static func occurrenceChecks() -> [CheckResult] {
        let g = "1. 발생 판정"
        var out: [CheckResult] = []
        let base = day(3)   // 오늘 시각의 영향을 받지 않도록 며칠 뒤를 기준으로

        // 하루짜리 = 요일 전체 + 시작일 == 종료일 (앱이 저장하는 형태)
        let single = make(start: base, end: endOfDay(base), weekdays: all7,
                          startMinute: 9 * 60, duration: 60, oneOff: base)
        out.append(check(g, "하루짜리 — 당일 울림", single.occurrence(on: base) != nil, true))
        out.append(check(g, "하루짜리 — 다음날 안 울림", single.occurrence(on: day(1, from: base)) != nil, false))
        out.append(check(g, "하루짜리 — 전날 안 울림", single.occurrence(on: day(-1, from: base)) != nil, false))

        // 무기한 매일
        let daily = make(start: base, end: nil, weekdays: all7, startMinute: 9 * 60, duration: 60)
        out.append(check(g, "무기한 매일 — 시작일 울림", daily.occurrence(on: base) != nil, true))
        out.append(check(g, "무기한 매일 — 30일 뒤에도 울림", daily.occurrence(on: day(30, from: base)) != nil, true))

        // 요일 반복 (월요일만)
        let mon = firstDay(weekday: 2)
        let weekly = make(start: mon, end: nil, weekdays: [2], startMinute: 9 * 60, duration: 60)
        out.append(check(g, "요일 반복 — 고른 요일 울림", weekly.occurrence(on: mon) != nil, true))
        out.append(check(g, "요일 반복 — 안 고른 요일 안 울림",
                         weekly.occurrence(on: day(1, from: mon)) != nil, false))

        // 기간 게이트
        let ranged = make(start: base, end: endOfDay(day(2, from: base)), weekdays: all7,
                          startMinute: 9 * 60, duration: 60)
        out.append(check(g, "종료일 당일 울림", ranged.occurrence(on: day(2, from: base)) != nil, true))
        out.append(check(g, "종료일 다음날 안 울림", ranged.occurrence(on: day(3, from: base)) != nil, false))
        out.append(check(g, "시작일 전날 안 울림", ranged.occurrence(on: day(-1, from: base)) != nil, false))

        return out
    }

    // MARK: 2. 겹침 판정 (기간 + 자정 넘김)

    private static func conflictChecks() -> [CheckResult] {
        let g = "2. 겹침 판정"
        var out: [CheckResult] = []
        let all = Set(all7)

        func conflict(_ aLo: Date, _ aHi: Date?, _ aW: Set<Int>, _ aS: Int, _ aD: Int,
                      _ bLo: Date, _ bHi: Date?, _ bW: Set<Int>, _ bS: Int, _ bD: Int) -> Bool {
            ScheduleConflict.conflicts(
                aRange: (aLo, aHi), aWeekdays: aW, aStart: aS, aDuration: aD,
                bRange: (bLo, bHi), bWeekdays: bW, bStart: bS, bDuration: bD, calendar: cal)
        }

        // 이미 끝난 활동이 나중 활동을 막으면 안 된다
        out.append(check(g, "기간이 안 겹치면 충돌 아님",
                         conflict(day(0), day(10), all, 9 * 60, 60,
                                  day(20), day(30), all, 9 * 60, 60), false))

        // 날짜가 다른 하루짜리끼리 (둘 다 요일 전체로 저장됨)
        out.append(check(g, "다른 날 하루짜리끼리 충돌 아님",
                         conflict(day(3), day(3), all, 9 * 60, 60,
                                  day(4), day(4), all, 9 * 60, 60), false))

        out.append(check(g, "같은 날 같은 시각은 충돌",
                         conflict(day(3), day(3), all, 9 * 60, 60,
                                  day(3), day(3), all, 9 * 60, 60), true))

        // 딱 붙은 시간대는 충돌이 아니어야 한다 (09~10 / 10~11)
        out.append(check(g, "시간이 딱 붙으면 충돌 아님",
                         conflict(day(3), day(3), all, 9 * 60, 60,
                                  day(3), day(3), all, 10 * 60, 60), false))

        // 자정 넘김 — 토 23:00+8h(→일 07:00) vs 일 02:00+2h
        let sat = firstDay(weekday: 7)
        let sun = day(1, from: sat)
        out.append(check(g, "자정 넘긴 활동과 다음날 새벽 활동은 충돌",
                         conflict(sat, sat, all, 23 * 60, 480,
                                  sun, sun, all, 2 * 60, 120), true))

        // 자정을 넘겨도 시간이 안 겹치면 충돌 아님 (→일 07:00 vs 일 09:00)
        out.append(check(g, "자정 넘겼지만 시간 안 겹치면 충돌 아님",
                         conflict(sat, sat, all, 23 * 60, 480,
                                  sun, sun, all, 9 * 60, 60), false))

        // 기간이 하루만 겹치는데 그날이 둘 다 발생하지 않는 요일
        let mon = firstDay(weekday: 2)
        let tue = day(1, from: mon)
        out.append(check(g, "겹치는 하루가 비발생 요일이면 충돌 아님",
                         conflict(mon, tue, [2], 9 * 60, 60,
                                  tue, day(14, from: tue), [2], 9 * 60, 60), false))

        // 무기한끼리
        out.append(check(g, "무기한 매일끼리 같은 시각은 충돌",
                         conflict(day(0), nil, all, 9 * 60, 60,
                                  day(0), nil, all, 9 * 60, 60), true))
        out.append(check(g, "무기한 vs 하루짜리 같은 시각은 충돌",
                         conflict(day(0), nil, all, 9 * 60, 60,
                                  day(5), day(5), all, 9 * 60, 60), true))
        out.append(check(g, "요일이 다르면 충돌 아님",
                         conflict(day(0), nil, [2], 9 * 60, 60,
                                  day(0), nil, [3], 9 * 60, 60), false))
        return out
    }

    // MARK: 3. 기간 시작일 판정 (레거시 일회성 손상 방지)

    private static func rangeChecks() -> [CheckResult] {
        let g = "3. 기간 시작일"
        var out: [CheckResult] = []

        // 레거시 일회성: 만든 시각은 과거, 실제 날짜는 미래.
        // 범위 시작이 '만든 날'로 잡히면 편집 시 '매일'로 손상된다.
        let legacy = make(start: day(-5), end: nil, weekdays: [],
                          startMinute: 9 * 60, duration: 60, oneOff: day(7))
        out.append(check(g, "레거시 일회성 — 범위 시작이 실제 날짜",
                         cal.isDate(legacy.activeDayRange(calendar: cal).lo, inSameDayAs: day(7)), true))
        out.append(check(g, "레거시 일회성 — 범위 시작이 만든 날이 아님",
                         cal.isDate(legacy.activeDayRange(calendar: cal).lo, inSameDayAs: day(-5)), false))

        // 매일(기간) 예약은 시작 게이트가 곧 범위 시작
        let ranged = make(start: day(2), end: endOfDay(day(9)), weekdays: all7,
                          startMinute: 9 * 60, duration: 60, oneOff: day(2))
        out.append(check(g, "기간 예약 — 범위 시작이 시작일",
                         cal.isDate(ranged.activeDayRange(calendar: cal).lo, inSameDayAs: day(2)), true))
        out.append(check(g, "기간 예약 — 범위 끝이 종료일",
                         ranged.activeDayRange(calendar: cal).hi.map {
                             cal.isDate($0, inSameDayAs: day(9)) } ?? false, true))
        out.append(check(g, "무기한 — 범위 끝이 없음",
                         make(start: day(0), end: nil, weekdays: all7,
                              startMinute: 540, duration: 60)
                             .activeDayRange(calendar: cal).hi == nil, true))
        return out
    }

    // MARK: 4. 죽은 예약 (저장돼도 평생 안 울리는 설정)

    private static func deadReservationChecks() -> [CheckResult] {
        let g = "4. 죽은 예약"
        var out: [CheckResult] = []

        // 월~수 기간에 금·토를 고르면 그 기간에 해당 요일이 없다
        let mon = firstDay(weekday: 2)
        let dead = make(start: mon, end: endOfDay(day(2, from: mon)), weekdays: [6, 7],
                        startMinute: 9 * 60, duration: 60)
        out.append(check(g, "기간에 없는 요일 — 발생 없음",
                         dead.nextOccurrence(after: mon, calendar: cal) == nil, true))

        // 같은 기간에 그 안에 있는 요일을 고르면 정상
        let alive = make(start: mon, end: endOfDay(day(2, from: mon)), weekdays: [3],
                         startMinute: 9 * 60, duration: 60)
        out.append(check(g, "기간에 있는 요일 — 발생 있음",
                         alive.nextOccurrence(after: mon, calendar: cal) != nil, true))

        // 먼 미래에 시작하는 예약도 첫 발생을 찾아야 한다 —
        // 못 찾으면 알람 안전망이 한 건도 걸지 못해 그날 알람이 통째로 유실된다.
        let farStart = day(67)
        let far = make(start: farStart, end: nil, weekdays: all7,
                       startMinute: 8 * 60, duration: 60, oneOff: farStart)
        out.append(check(g, "두 달 뒤 시작 — 첫 발생을 찾는다",
                         far.nextOccurrence(after: Date(), calendar: cal) != nil, true))

        // 종료일이 지난 예약은 더 이상 발생이 없다 (만료 정리 대상)
        let expired = make(start: day(-10), end: endOfDay(day(-3)), weekdays: all7,
                           startMinute: 9 * 60, duration: 60, oneOff: day(-10))
        out.append(check(g, "만료된 예약 — 남은 발생 없음",
                         expired.nextOccurrence(after: Date(), calendar: cal) == nil, true))
        return out
    }

    // MARK: 5. 그룹방 종료 판정 (마지막 활동이 끝나는 순간)

    private static func groupRoomChecks() -> [CheckResult] {
        let g = "5. 그룹방 종료"
        var out: [CheckResult] = []

        func room(startDay: Date, endDay: Date, weekdays: [Int],
                  startMinute: Int, duration: Int) -> GroupRoom {
            GroupRoom(id: "selfcheck", name: "검사", code: "AAAAA", hostUID: "selfcheck",
                      intensityRaw: Intensity.spicy.rawValue,
                      startMinute: startMinute, durationMinutes: duration,
                      repeatWeekdays: weekdays,
                      startDate: cal.date(byAdding: .minute, value: startMinute, to: startDay)!,
                      endDate: endOfDay(endDay),
                      status: "active", memberCount: 2)
        }

        // 오늘 오전 11시에 10분짜리 하루 그룹 — 11:30(=11:00+10분+유예 20분)에 확정된다.
        let today = cal.startOfDay(for: Date())
        let oneDay = room(startDay: today, endDay: today, weekdays: all7,
                          startMinute: 11 * 60, duration: 10)
        let expected = cal.date(byAdding: .minute, value: 11 * 60 + 10 + GroupPolicy.settleGraceMinutes,
                                to: today)!
        out.append(check(g, "하루 그룹 — 종료 시각 = 마지막 활동 + 유예",
                         abs(oneDay.finishedAt.timeIntervalSince(expected)) < 1, true))
        out.append(check(g, "하루 그룹 — 종료일 자정보다 이르다",
                         oneDay.finishedAt < endOfDay(today), true))

        // 어제 끝난 하루 그룹은 이미 '종료'
        let yesterday = day(-1)
        let past = room(startDay: yesterday, endDay: yesterday, weekdays: all7,
                        startMinute: 11 * 60, duration: 10)
        out.append(check(g, "어제 끝난 그룹 — 종료 상태", past.isFinished, true))
        out.append(check(g, "어제 끝난 그룹 — 아직 삭제 시점 아님", past.isExpired, false))

        // 내일 시작하는 하루 그룹은 아직 종료 아님
        let future = room(startDay: day(1), endDay: day(1), weekdays: all7,
                          startMinute: 11 * 60, duration: 10)
        out.append(check(g, "내일 그룹 — 종료 아님", future.isFinished, false))

        // 월~금 기간에 월·수만 반복 → 마지막 발생은 금요일이 아니라 수요일
        let mon = firstDay(weekday: 2)
        let weekly = room(startDay: mon, endDay: day(4, from: mon), weekdays: [2, 4],
                          startMinute: 9 * 60, duration: 30)
        let wed = day(2, from: mon)
        out.append(check(g, "요일 반복 — 마지막 발생일이 수요일",
                         cal.isDate(weekly.finishedAt, inSameDayAs: wed), true))

        // 보존 기간이 다 지난 그룹은 삭제 대상
        let old = room(startDay: day(-GroupPolicy.resultRetentionDays - 2),
                       endDay: day(-GroupPolicy.resultRetentionDays - 2),
                       weekdays: all7, startMinute: 11 * 60, duration: 10)
        out.append(check(g, "보존 기간 지난 그룹 — 삭제 대상", old.isExpired, true))
        return out
    }

    // MARK: 덤프

    static func describe(_ r: Reservation) -> String {
        let f = DateFormatter()
        f.dateFormat = "yy-MM-dd"
        let start = f.string(from: r.createdAt)
        let end = r.endDate.map { f.string(from: $0) } ?? "무기한"
        let marker = r.oneOffDate.map { f.string(from: $0) } ?? "-"
        let days = r.repeatWeekdays.sorted().map(String.init).joined(separator: ",")
        let next = r.nextOccurrence().map { d -> String in
            let g = DateFormatter(); g.dateFormat = "MM-dd HH:mm"; return g.string(from: d)
        } ?? "없음"
        return """
        시작 \(start) · 종료 \(end) · 마커 \(marker)
        요일 [\(days)] · \(r.startMinute / 60):\(String(format: "%02d", r.startMinute % 60)) · \(r.durationMinutes)분
        다음 발생 \(next)\(r.groupID != nil ? " · 그룹" : "")
        """
    }
}
#endif
