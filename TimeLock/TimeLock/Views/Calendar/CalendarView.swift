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

    // 홈 우상단 누적점수 배지에서 푸시되는 화면 — 자체 NavigationStack 없음
    var body: some View {
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
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(
            get: { selectedDay.map(DayBox.init) },
            set: { selectedDay = $0?.date })) { box in
            DayDetailView(day: box.date,
                          sessions: sessions(on: box.date),
                          scoreEvents: scoreEvents)
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
                        .frame(width: 32, height: 32)
                }
                .pressableStyle()
                Spacer()
                Text(monthTitle)
                    .font(.tlTitle(18))
                    .foregroundStyle(TL.paper)
                Spacer()
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right").foregroundStyle(TL.muted)
                        .frame(width: 32, height: 32)
                }
                .pressableStyle()
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
        // 그날의 누적 상·벌점 합계로 원 색을 정한다 — 양수 초록 / 음수 빨강 / 0은 앰버
        let dayScore = scoreEvents
            .filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
            .reduce(0) { $0 + $1.points }
        let hasRecords = !daySessions.isEmpty
        let state: Color? = hasRecords
            ? (dayScore > 0 ? TL.jade : (dayScore < 0 ? TL.rec : TL.amber))
            : nil
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
                        .background(Circle().fill(state.opacity(0.22)))
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

// 성적표 스타일: 시간순 내역 리스트 + 항목별 토글로 상세(썸네일·사유·순수 촬영시간) 열람.
// 상점·벌점은 운영자 평가 수단 — 회원이 삭제/수정할 수 없다(조회 전용).
struct DayDetailView: View {
    let day: Date
    let sessions: [FocusSession]
    let scoreEvents: [ScoreEvent]

    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<UUID> = []

    /// 시간순 정렬
    private var ordered: [FocusSession] {
        sessions.sorted { $0.anchorDate < $1.anchorDate }
    }

    private var dayReward: Int {
        ordered.compactMap { pts($0) }.filter { $0 > 0 }.reduce(0, +)
    }
    private var dayPenalty: Int {
        ordered.compactMap { pts($0) }.filter { $0 < 0 }.reduce(0, +)
    }
    private var allOpen: Bool { !ordered.isEmpty && expanded.count == ordered.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if ordered.isEmpty {
                        TLCard {
                            Text("이 날은 기록이 없습니다.")
                                .font(.system(size: 14)).foregroundStyle(TL.muted)
                        }
                    } else {
                        summaryHeader
                        TLCard {
                            VStack(spacing: 0) {
                                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, session in
                                    reportRow(session)
                                    if index < ordered.count - 1 {
                                        Divider().overlay(TL.hairline.opacity(0.5))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(TL.ink)
            .navigationTitle(TLFormat.dayTitle(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !ordered.isEmpty {
                        // 고정 폭 — '모두 접기'↔'모두 펼치기' 글자 수 차이로 버튼이 움직이지 않게.
                        // 전체 전환은 애니메이션 없이 즉시 (개별 토글만 부드럽게).
                        Button {
                            expanded = allOpen ? [] : Set(ordered.map(\.id))
                        } label: {
                            Text(allOpen ? "모두 접기" : "모두 펼치기")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(TL.muted)
                                .frame(width: 84, alignment: .leading)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }.foregroundStyle(TL.muted)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 상단 합계 (성적표 헤더)

    private var summaryHeader: some View {
        HStack(spacing: 10) {
            summaryChip(value: "+\(dayReward)", label: "상점", tint: TL.jade)
            summaryChip(value: "\(dayPenalty)", label: "벌점", tint: TL.rec)
            summaryChip(value: "\(dayReward + dayPenalty)", label: "합계",
                        tint: dayReward + dayPenalty >= 0 ? TL.paper : TL.rec)
        }
    }

    private func summaryChip(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.tlTimer(20)).foregroundStyle(tint)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(TL.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous).fill(TL.surface))
    }

    // MARK: 내역 행 (접힘: 원·시간·활동·점수 / 펼침: 썸네일·사유·순수촬영)

    private func reportRow(_ session: FocusSession) -> some View {
        let outcome = session.outcome ?? .completed
        let isOpen = expanded.contains(session.id)
        let points = pts(session)

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                // 성취 원 — 성공 초록 / 실패 빨강 / 그 외(긴급·안전) 앰버
                Circle()
                    .fill(circleColor(outcome))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(circleColor(outcome).opacity(0.35), lineWidth: 3))
                Text(TLFormat.clock(session.anchorDate))
                    .font(.tlTimer(14)).foregroundStyle(TL.paper)
                    .frame(width: 70, alignment: .leading)
                Text(session.activityName)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(TL.paper)
                    .lineLimit(1)
                Spacer()
                if let points {
                    Text(points > 0 ? "+\(points)" : "\(points)")
                        .font(.tlTimer(14))
                        .foregroundStyle(points > 0 ? TL.jade : TL.rec)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TL.faint)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
            .onTapGesture { toggle(session.id) }

            if isOpen {
                detail(session, outcome: outcome)
                    .padding(.bottom, 13)
            }
        }
    }

    /// 탭 시점의 현재 상태를 직접 읽어 토글 — 캡처된 값에 의존하지 않는다
    private func toggle(_ id: UUID) {
        withAnimation(TLMotion.snappy) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    @ViewBuilder
    private func detail(_ session: FocusSession, outcome: SessionOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(outcome.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(outcome.isSuccess ? TL.jade : (outcome.isFailure ? TL.rec : TL.amber))
                Text("· \(session.intensity.title)")
                    .font(.system(size: 12)).foregroundStyle(TL.muted)
            }

            if let thumbURL = session.thumbnailURL,
               let image = UIImage(contentsOfFile: thumbURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))
                    // fill로 넘친 이미지는 clipShape로 잘라도 '터치 영역'은 그대로 남아
                    // 위 헤더 행의 탭(접기)을 가로챈다 — 장식 이미지이므로 히트 테스트 제외
                    .allowsHitTesting(false)
            }

            if let reason = reason(for: session), !reason.isEmpty {
                Label(reason, systemImage: "text.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TL.amber)
            }

            Text("순수 촬영 \(TLFormat.hms(session.recordedSeconds)) / 목표 \(TLFormat.hms(session.targetSeconds))")
                .font(.system(size: 12)).foregroundStyle(TL.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 28)
    }

    // MARK: 보조

    private func pts(_ session: FocusSession) -> Int? {
        ScoreRules.points(for: session.outcome ?? .completed, intensity: session.intensity,
                          durationMinutes: session.targetSeconds / 60)?.1
    }

    private func circleColor(_ outcome: SessionOutcome) -> Color {
        outcome.isSuccess ? TL.jade : (outcome.isFailure ? TL.rec : TL.amber)
    }

    /// 실패/긴급 사유 — 점수 원장의 note 우선, 없으면 세션의 긴급 사유
    private func reason(for session: FocusSession) -> String? {
        if let note = scoreEvents.first(where: { $0.sessionID == session.id })?.note, !note.isEmpty {
            return note
        }
        return session.emergencyReason
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

    /// 연속 달성일 — 슬롯 정책과 동일한 정의를 공유 (SlotPolicy)
    private var streak: Int { SlotPolicy.currentStreak(sessions: sessions) }

    private var byTag: [(String, Int)] {
        Dictionary(grouping: finished.filter { $0.outcome?.isSuccess == true }, by: \.tag)
            .mapValues { $0.reduce(0) { $0 + $1.recordedSeconds } }
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    // 컴팩트 레이아웃 — 3열×2줄 + 축소된 카드로 캘린더와 함께 한 화면에 들어온다
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TLEyebrow(text: "누적 대시보드")

            HStack(spacing: 8) {
                statCard(value: "\(totalReward + totalPenalty)", label: "총점",
                         tint: totalReward + totalPenalty >= 0 ? TL.jade : TL.rec)
                statCard(value: "\(streak)일", label: "연속 달성일", tint: TL.paper)
                statCard(value: "\(completionRate)%", label: "완주율", tint: TL.jade)
            }
            HStack(spacing: 8) {
                statCard(value: "\(noShowRate)%", label: "노쇼율", tint: noShowRate > 0 ? TL.rec : TL.muted)
                statCard(value: "+\(totalReward)", label: "총 상점", tint: TL.jade)
                statCard(value: "\(totalPenalty)", label: "총 벌점", tint: TL.rec)
            }

            if !byTag.isEmpty {
                TLCard {
                    VStack(alignment: .leading, spacing: 8) {
                        TLEyebrow(text: "태그별 시간 분포")
                        let maxSeconds = byTag.first?.1 ?? 1
                        ForEach(byTag, id: \.0) { tag, seconds in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(tag).font(.system(size: 12, weight: .semibold)).foregroundStyle(TL.paper)
                                    Spacer()
                                    Text(TLFormat.hms(seconds)).font(.tlTimer(12)).foregroundStyle(TL.muted)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(TL.hairline.opacity(0.4))
                                        Capsule().fill(TL.jade)
                                            .frame(width: geo.size.width * CGFloat(seconds) / CGFloat(max(1, maxSeconds)))
                                    }
                                }
                                .frame(height: 5)
                            }
                        }
                    }
                }
            }
        }
    }

    private func statCard(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.tlTimer(19)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(TL.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous).fill(TL.surface))
    }
}
