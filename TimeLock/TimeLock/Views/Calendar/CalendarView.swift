//
//  CalendarView.swift
//  TimeLock
//
//  월간 성공캘린더: 날짜에 실패/노쇼가 하나라도 있으면 빨강, 모두 완주면 초록.
//  날짜 상세: 세션 기록(썸네일)·점수 내역·태그별 시간.
//  누적 대시보드: 총점, 완주율/노쇼율, 태그 분포, 스트릭.
//  정책: 타임랩스 원본은 세션 종료 화면에서 저장하지 않으면 삭제되므로
//  캘린더에는 재생·공유가 없고 기록만 남는다. 모든 데이터는 현재 계정 것만 보인다.
//

import SwiftUI
import SwiftData

struct CalendarView: View {
    @EnvironmentObject private var account: AccountStore
    @Query private var everySession: [FocusSession]
    @Query private var everyScoreEvent: [ScoreEvent]

    @State private var monthAnchor = Date()
    @State private var selectedDay: Date?

    private var calendar: Calendar { Calendar.current }

    /// 현재 계정의 기록만
    private var allSessions: [FocusSession] {
        everySession.filter { $0.ownerUserID == account.currentUserID }
    }
    private var scoreEvents: [ScoreEvent] {
        everyScoreEvent.filter { $0.ownerUserID == account.currentUserID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    monthGrid
                    DashboardSection(sessions: allSessions, scoreEvents: scoreEvents)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(TL.ink)
            .navigationTitle("기록")
            .sheet(item: Binding(
                get: { selectedDay.map(DayBox.init) },
                set: { selectedDay = $0?.date })) { box in
                DayDetailView(day: box.date,
                              sessions: sessions(on: box.date),
                              scoreEvents: scoreEvents)
            }
        }
    }

    private struct DayBox: Identifiable {
        let date: Date
        var id: Date { date }
    }

    private func sessions(on day: Date) -> [FocusSession] {
        allSessions.filter { calendar.isDate($0.anchorDate, inSameDayAs: day) }
    }

    // MARK: 월간 그리드

    private var monthGrid: some View {
        VStack(spacing: 14) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left").foregroundStyle(TL.muted)
                }
                Spacer()
                Text(monthTitle)
                    .font(.tlTitle(18))
                    .foregroundStyle(TL.paper)
                Spacer()
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right").foregroundStyle(TL.muted)
                }
            }
            .padding(.horizontal, 4)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(["일", "월", "화", "수", "목", "금", "토"], id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(TL.faint)
                }
                ForEach(monthDays, id: \.self) { day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
    }

    private func dayCell(_ day: Date) -> some View {
        let daySessions = sessions(on: day).filter { $0.outcome != nil }
        let hasFailure = daySessions.contains { $0.outcome?.isFailure == true }
        let hasSuccess = daySessions.contains { $0.outcome?.isSuccess == true }
        let state: Color? = daySessions.isEmpty ? nil : (hasFailure ? TL.rec : (hasSuccess ? TL.jade : TL.faint))
        let isToday = calendar.isDateInToday(day)

        return Button {
            if !daySessions.isEmpty { selectedDay = day }
        } label: {
            VStack(spacing: 5) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.tlTimer(14))
                    .foregroundStyle(isToday ? TL.paper : TL.muted)
                // 미니 REC 링 — 캘린더 완주 마크
                if let state {
                    Circle()
                        .strokeBorder(state, lineWidth: 2.5)
                        .background(Circle().fill(state.opacity(hasFailure || hasSuccess ? 0.22 : 0.1)))
                        .frame(width: 14, height: 14)
                } else {
                    Circle().fill(TL.hairline.opacity(0.4)).frame(width: 4, height: 4).padding(5)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: TL.cornerS)
                    .fill(isToday ? TL.raised : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월"
        return f.string(from: monthAnchor)
    }

    private var monthDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let dayCount = calendar.range(of: .day, in: .month, for: monthAnchor)?.count ?? 30
        var days: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for offset in 0..<dayCount {
            days.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        return days
    }

    private func shiftMonth(_ delta: Int) {
        monthAnchor = calendar.date(byAdding: .month, value: delta, to: monthAnchor) ?? monthAnchor
    }
}

// MARK: - 날짜 상세

struct DayDetailView: View {
    let day: Date
    let sessions: [FocusSession]
    let scoreEvents: [ScoreEvent]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    tagSummary
                    ForEach(sessions, id: \.id) { session in
                        sessionCard(session)
                    }
                }
                .padding(20)
            }
            .background(TL.ink)
            .navigationTitle(TLFormat.dayTitle(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }.foregroundStyle(TL.muted)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var tagSummary: some View {
        let byTag = Dictionary(grouping: sessions.filter { $0.outcome?.isSuccess == true }, by: \.tag)
            .mapValues { $0.reduce(0) { $0 + $1.recordedSeconds } }
            .sorted { $0.value > $1.value }
        return Group {
            if !byTag.isEmpty {
                TLCard {
                    VStack(alignment: .leading, spacing: 8) {
                        TLEyebrow(text: "태그별 누적")
                        ForEach(byTag, id: \.key) { tag, seconds in
                            HStack {
                                TagChip(name: tag)
                                Spacer()
                                Text(TLFormat.hms(seconds)).font(.tlTimer(15)).foregroundStyle(TL.paper)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sessionCard(_ session: FocusSession) -> some View {
        let outcome = session.outcome ?? .completed
        let points = ScoreRules.points(for: outcome, intensity: session.intensity)?.1

        return TLCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.activityName).font(.tlTitle(16)).foregroundStyle(TL.paper)
                        Text("\(TLFormat.clock(session.anchorDate)) · \(session.intensity.title)\(session.outcome == .emergency ? " · 긴급" : "")")
                            .font(.system(size: 12)).foregroundStyle(TL.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(outcome.title)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(outcome.isSuccess ? TL.jade : (outcome.isFailure ? TL.rec : TL.amber))
                        if let points {
                            Text(points > 0 ? "+\(points)" : "\(points)")
                                .font(.tlTimer(14))
                                .foregroundStyle(points > 0 ? TL.jade : TL.rec)
                        }
                    }
                }

                if let thumbURL = session.thumbnailURL,
                   let image = UIImage(contentsOfFile: thumbURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            Text("기록 썸네일 · 원본은 세션 종료 시 저장/삭제됨")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(TL.paper.opacity(0.85))
                                .padding(6)
                        }
                }

                Text("순수 촬영 \(TLFormat.hms(session.recordedSeconds)) / 목표 \(TLFormat.hms(session.targetSeconds))")
                    .font(.system(size: 12)).foregroundStyle(TL.muted)
            }
        }
    }
}

// MARK: - 누적 대시보드

struct DashboardSection: View {
    let sessions: [FocusSession]
    let scoreEvents: [ScoreEvent]

    private var finished: [FocusSession] { sessions.filter { $0.outcome != nil } }
    private var completions: Int { finished.filter { $0.outcome?.isSuccess == true }.count }
    private var noShows: Int { finished.filter { $0.outcome == .noShow }.count }
    private var started: Int { finished.filter { $0.startedAt != nil }.count }

    private var totalReward: Int { scoreEvents.filter { $0.points > 0 }.reduce(0) { $0 + $1.points } }
    private var totalPenalty: Int { scoreEvents.filter { $0.points < 0 }.reduce(0) { $0 + $1.points } }

    private var completionRate: Int {
        guard started > 0 else { return 0 }
        return Int(Double(completions) / Double(started) * 100)
    }
    private var noShowRate: Int {
        guard !finished.isEmpty else { return 0 }
        return Int(Double(noShows) / Double(finished.count) * 100)
    }

    /// 스트릭: 오늘부터 거꾸로, 실패 없는 완주 일수
    private var streak: Int {
        let calendar = Calendar.current
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

    private var byTag: [(String, Int)] {
        Dictionary(grouping: finished.filter { $0.outcome?.isSuccess == true }, by: \.tag)
            .mapValues { $0.reduce(0) { $0 + $1.recordedSeconds } }
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TLEyebrow(text: "누적 대시보드")

            HStack(spacing: 10) {
                statCard(value: "\(totalReward + totalPenalty)", label: "총점",
                         tint: totalReward + totalPenalty >= 0 ? TL.jade : TL.rec)
                statCard(value: "\(streak)일", label: "스트릭", tint: TL.paper)
            }
            HStack(spacing: 10) {
                statCard(value: "\(completionRate)%", label: "완주율", tint: TL.jade)
                statCard(value: "\(noShowRate)%", label: "노쇼율", tint: noShowRate > 0 ? TL.rec : TL.muted)
            }

            HStack(spacing: 10) {
                statCard(value: "+\(totalReward)", label: "총 상점", tint: TL.jade)
                statCard(value: "\(totalPenalty)", label: "총 벌점", tint: TL.rec)
            }

            if !byTag.isEmpty {
                TLCard {
                    VStack(alignment: .leading, spacing: 10) {
                        TLEyebrow(text: "태그별 시간 분포")
                        let maxSeconds = byTag.first?.1 ?? 1
                        ForEach(byTag, id: \.0) { tag, seconds in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(tag).font(.system(size: 13, weight: .semibold)).foregroundStyle(TL.paper)
                                    Spacer()
                                    Text(TLFormat.hms(seconds)).font(.tlTimer(13)).foregroundStyle(TL.muted)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(TL.hairline.opacity(0.4))
                                        Capsule().fill(TL.jade)
                                            .frame(width: geo.size.width * CGFloat(seconds) / CGFloat(max(1, maxSeconds)))
                                    }
                                }
                                .frame(height: 6)
                            }
                        }
                    }
                }
            }
        }
    }

    private func statCard(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.tlTimer(24)).foregroundStyle(tint)
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(TL.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous).fill(TL.surface))
    }
}
