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
    enum Tab { case activity, records }
    @State private var tab: Tab = .activity

    var body: some View {
        ZStack(alignment: .bottom) {
            switch tab {
            case .activity: HomeView()
            case .records:  CalendarView()
            }

            bottomToggle
                .padding(.bottom, 12)
        }
        .background(TL.ink.ignoresSafeArea())
        .animation(TLMotion.smooth, value: tab)
    }

    /// 하단 알약형 토글 — 목업의 [활동 | 기록]
    private var bottomToggle: some View {
        HStack(spacing: 0) {
            toggleSegment("활동", tab: .activity)
            toggleSegment("기록", tab: .records)
        }
        .padding(4)
        .background(Capsule().fill(TL.raised))
        .overlay(Capsule().strokeBorder(TL.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    private func toggleSegment(_ title: String, tab target: Tab) -> some View {
        Button {
            tab = target
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(tab == target ? TL.ink : TL.muted)
                .frame(width: 92)
                .padding(.vertical, 10)
                .background(Capsule().fill(tab == target ? TL.paper : .clear))
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

    /// 누적 상점 (양수 포인트 합)
    private var totalReward: Int {
        allEvents.filter { $0.ownerUserID == account.currentUserID && $0.points > 0 }
            .reduce(0) { $0 + $1.points }
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

                    upcomingSection
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 96)   // 하단 토글 자리
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

            // 🔥 누적 상점 배지
            HStack(spacing: 5) {
                Text("🔥").font(.system(size: 15))
                Text(rewardLabel)
                    .font(.tlTimer(15))
                    .foregroundStyle(TL.paper)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(TL.surface))
            .overlay(Capsule().strokeBorder(TL.hairline, lineWidth: 1))

            // 마이페이지
            NavigationLink {
                MyPageView()
            } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(TL.muted)
            }
            .pressableStyle()
        }
    }

    private var rewardLabel: String {
        totalReward >= 1000
            ? String(format: "%.1fK", Double(totalReward) / 1000).replacingOccurrences(of: ".0K", with: "K")
            : "\(totalReward)"
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
