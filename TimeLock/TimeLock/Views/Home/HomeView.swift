//
//  HomeView.swift
//  TimeLock
//
//  홈(활동 탭): 우상단 누적 상점·마이페이지, 다짐 카드, 활동 추가하기,
//  지금 바로 시작, 예정된 활동 리스트. 하단 [활동|기록] 토글은 HomeShellView가 담당.
//

import SwiftUI
import SwiftData

// MARK: - 쉘: 활동 | 기록 토글

struct HomeShellView: View {
    enum Tab { case activity, schedule }
    @State private var tab: Tab = .activity

    var body: some View {
        ZStack(alignment: .bottom) {
            switch tab {
            case .activity: HomeView()
            case .schedule: WeeklyScheduleView()
            }

            bottomToggle
                .padding(.bottom, 12)
        }
        .background(TL.ink.ignoresSafeArea())
        .animation(TLMotion.smooth, value: tab)
    }

    /// 하단 알약형 토글 — 글래스모피즘(반투명 블러) + 아이콘, 애플 탭바 감성 (1.5배 확대)
    private var bottomToggle: some View {
        HStack(spacing: 5) {
            toggleSegment("활동", icon: "clock.fill", tab: .activity)
            toggleSegment("일정", icon: "calendar", tab: .schedule)
        }
        .padding(7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    private func toggleSegment(_ title: String, icon: String, tab target: Tab) -> some View {
        let selected = tab == target
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(TLMotion.snappy) { tab = target }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
            }
            .foregroundStyle(selected ? TL.ink : TL.paper.opacity(0.72))
            .padding(.horizontal, 32)
            .padding(.vertical, 15)
            .background(
                Capsule()
                    .fill(selected ? AnyShapeStyle(TL.paper) : AnyShapeStyle(.clear))
                    .shadow(color: selected ? .black.opacity(0.25) : .clear, radius: 5, y: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 홈 (활동)

struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var account: AccountStore
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Reservation> { $0.isActive }, sort: \Reservation.startMinute)
    private var allActiveReservations: [Reservation]
    @Query private var allEvents: [ScoreEvent]

    /// 현재 계정의 예약만
    private var reservations: [Reservation] {
        allActiveReservations.filter { $0.ownerUserID == account.currentUserID }
    }

    /// 누적 총점 = 지금까지의 상점·벌점 전체 합
    private var totalScore: Int {
        allEvents.filter { $0.ownerUserID == account.currentUserID }
            .reduce(0) { $0 + $1.points }
    }
    /// 총점 색 — 상점 우세 초록, 벌점 우세 빨강, 0은 중립
    private var totalScoreTint: Color {
        totalScore > 0 ? TL.jade : (totalScore < 0 ? TL.rec : TL.paper)
    }

    @State private var now = Date()
    @State private var showEditor = false
    @State private var editing: Reservation?
    @State private var showQuickStart = false
    @State private var showGoalEditor = false
    @State private var goalText = ""

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// 다음 발생 시각 순으로 정렬한 예정된 활동
    private var upcoming: [(reservation: Reservation, fire: Date?)] {
        reservations
            .map { ($0, $0.nextOccurrence(after: now)) }
            .sorted { ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                        .padding(.top, 6)

                    goalCard

                    Button("활동 추가하기") {
                        editing = nil
                        showEditor = true
                    }
                    .buttonStyle(TLPrimaryButtonStyle())

                    quickStartRow

                    nextCountdownCard

                    upcomingSection
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 116)   // 하단 토글 자리
            }
            .background(TL.ink)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showEditor) {
                ReservationEditView(reservation: editing)
            }
            .sheet(isPresented: $showQuickStart) {
                QuickStartSheet()
                    .presentationDetents([.height(420)])
            }
            .sheet(isPresented: $showGoalEditor) {
                GoalEditorSheet(goal: $goalText) { saveGoal() }
                    .presentationDetents([.height(260)])
            }
            .onReceive(clock) { now = $0 }
            .onAppear { loadGoal() }
            .onChange(of: account.currentUserID) { loadGoal() }
        }
    }

    // MARK: 헤더 — 누적 상점 + 마이페이지

    private var header: some View {
        HStack(spacing: 10) {
            Spacer()

            // 누적 총점 배지 — 양수 스마일 / 음수 앵그리. 누르면 '기록'(캘린더 점수판)으로.
            NavigationLink {
                CalendarView()
            } label: {
                HStack(spacing: 8) {
                    Image(totalScore < 0 ? "MotiAngry" : "MotiSmile")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                    Text(scoreLabel)
                        .font(.tlTimer(22))
                        .foregroundStyle(totalScoreTint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(TL.surface))
                .overlay(Capsule().strokeBorder(TL.hairline, lineWidth: 1))
            }
            .pressableStyle()

            // 마이페이지
            NavigationLink {
                MyPageView()
            } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 45))
                    .foregroundStyle(TL.muted)
            }
            .pressableStyle()
        }
    }

    private var scoreLabel: String {
        let magnitude = abs(totalScore)
        let body = magnitude >= 1000
            ? String(format: "%.1fK", Double(magnitude) / 1000).replacingOccurrences(of: ".0K", with: "K")
            : "\(magnitude)"
        if totalScore > 0 { return "+\(body)" }
        if totalScore < 0 { return "-\(body)" }
        return "0"
    }

    // MARK: 다짐/목표 카드

    private var goalCard: some View {
        Button {
            showGoalEditor = true
        } label: {
            VStack(spacing: 6) {
                if goalText.isEmpty {
                    Text("나의 다짐, 목표를 적어보세요")
                        .font(.tlTitle(17))
                        .foregroundStyle(TL.faint)
                    Text("탭해서 작성")
                        .font(.system(size: 12)).foregroundStyle(TL.faint)
                } else {
                    Text(goalText)
                        .font(.tlTitle(18))
                        .foregroundStyle(TL.paper)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 110)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
            .overlay(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
                .strokeBorder(TL.hairline.opacity(0.6), lineWidth: 1))
        }
        .pressableStyle()
    }

    private var goalKey: String { "homeGoal.\(account.currentUserID)" }
    private func loadGoal() { goalText = UserDefaults.standard.string(forKey: goalKey) ?? "" }
    private func saveGoal() { UserDefaults.standard.set(goalText, forKey: goalKey) }

    // MARK: 지금 바로 시작

    private var quickStartRow: some View {
        Button {
            showQuickStart = true
        } label: {
            HStack {
                Text("지금 바로 시작")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(TL.paper)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
            .overlay(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
                .strokeBorder(TL.hairline.opacity(0.6), lineWidth: 1))
        }
        .pressableStyle()
    }

    // MARK: 다음 활동 카운트다운 (컴팩트)

    private var nextUpcoming: (reservation: Reservation, fire: Date)? {
        upcoming.compactMap { item in item.fire.map { (item.reservation, $0) } }
            .first { $0.1 > now }
    }

    @ViewBuilder
    private var nextCountdownCard: some View {
        if let next = nextUpcoming {
            let remaining = Int(next.fire.timeIntervalSince(now))
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    TLEyebrow(text: "다음 활동까지", color: TL.muted)
                    Text(next.reservation.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TL.paper)
                        .lineLimit(1)
                }
                Spacer()
                Text(countdownText(remaining))
                    .font(.tlTimer(24))
                    .foregroundStyle(TL.amber)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
            .overlay(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
                .strokeBorder(TL.hairline.opacity(0.6), lineWidth: 1))
        }
    }

    private func countdownText(_ seconds: Int) -> String {
        if seconds >= 86_400 { return "\(seconds / 86_400)일 \((seconds % 86_400) / 3600)시간" }
        return TLFormat.hms(seconds)
    }

    // MARK: 예정된 활동

    @ViewBuilder
    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("예정된 활동")
                .font(.tlTitle(20))
                .foregroundStyle(TL.paper)

            if upcoming.isEmpty {
                TLCard {
                    Text("아직 예정된 활동이 없습니다. '활동 추가하기'로 첫 자기계약을 만들어 보세요.")
                        .font(.system(size: 13)).foregroundStyle(TL.muted)
                }
            } else {
                ForEach(upcoming, id: \.reservation.id) { item in
                    reservationCard(item.reservation, fire: item.fire)
                }
            }
        }
    }

    private func reservationCard(_ reservation: Reservation, fire: Date?) -> some View {
        let isSoon = fire.map { $0.timeIntervalSince(now) <= 1800 && $0 > now } ?? false
        return Button {
            editing = reservation
            showEditor = true
        } label: {
            TLCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(reservation.name)
                            .font(.tlTitle(17))
                            .foregroundStyle(TL.paper)
                            .lineLimit(1)
                        Spacer()
                        TagChip(name: reservation.tag)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "bell.fill").font(.system(size: 11))
                        if let fire {
                            Text("\(nextLabel(fire)) · \(TLFormat.durationLabel(reservation.durationMinutes))\(reservation.isRepeating ? " · 매주 " + weekdayLabel(reservation.repeatWeekdays) : "")")
                        } else {
                            Text(TLFormat.durationLabel(reservation.durationMinutes))
                        }
                        Spacer()
                        if isSoon {
                            Label("곧 시작", systemImage: "lock.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(TL.amber)
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(TL.muted)
                }
            }
        }
        .pressableStyle()
    }

    private func nextLabel(_ fire: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(fire) { return "오늘 \(TLFormat.clock(fire))" }
        if cal.isDateInTomorrow(fire) { return "내일 \(TLFormat.clock(fire))" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E) a h:mm"
        return f.string(from: fire)
    }

    private func weekdayLabel(_ weekdays: [Int]) -> String {
        let names = ["", "일", "월", "화", "수", "목", "금", "토"]
        return weekdays.sorted().map { names[$0] }.joined(separator: " ")
    }
}

// MARK: - 다짐 편집 시트

private struct GoalEditorSheet: View {
    @Binding var goal: String
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField("예: 올해는 매일 2시간씩 공부한다", text: $goal, axis: .vertical)
                    .font(.tlBody)
                    .foregroundStyle(TL.paper)
                    .lineLimit(3...5)
                    .padding(14)
                    .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerM))

                Button("저장") {
                    onSave()
                    dismiss()
                }
                .buttonStyle(TLPrimaryButtonStyle())
            }
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(TL.ink)
            .navigationTitle("나의 다짐")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - 지금 바로 시작 시트

private struct QuickStartSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var tag = ActivityTag.presets[0]
    @State private var minutes = 60

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                TextField("활동명 (예: 모의고사 풀기)", text: $name)
                    .font(.tlBody)
                    .padding(14)
                    .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerM))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ActivityTag.presets, id: \.self) { preset in
                            Button { tag = preset } label: { TagChip(name: preset, selected: tag == preset) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TLEyebrow(text: "활동 시간")
                    Picker("활동 시간", selection: $minutes) {
                        ForEach(TimePolicy.durationOptionsMinutes, id: \.self) {
                            Text(TLFormat.durationLabel($0)).tag($0)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 110)
                }

                Button("촬영 준비하기") {
                    dismiss()
                    let finalName = name.trimmingCharacters(in: .whitespaces)
                    app.startImmediate(name: finalName.isEmpty ? tag : finalName, tag: tag, minutes: minutes)
                }
                .buttonStyle(TLPrimaryButtonStyle())
            }
            .padding(20)
            .background(TL.ink)
            .navigationTitle("지금 바로 시작")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
