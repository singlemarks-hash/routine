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
    enum Tab { case activity, schedule, group }
    @State private var tab: Tab = .activity
    /// 활동 탭의 내비게이션 경로를 쉘이 들고 있는다. 마이페이지처럼 활동 탭 위에 쌓인
    /// 화면은 탭을 다시 눌러도 '이미 활동 탭'이라 아무 일도 안 일어나 빠져나올 수 없었다.
    /// (일정·그룹은 탭이 바뀌면서 화면이 통째로 교체돼 정상으로 보였다)
    @State private var activityPath = NavigationPath()
    @EnvironmentObject private var account: AccountStore

    /// 그룹 챌린지는 계정 전용 — 게스트에겐 탭 자체를 숨긴다
    private var showsGroupTab: Bool { account.isSignedIn && !account.isGuest }

    var body: some View {
        ZStack(alignment: .bottom) {
            switch tab {
            case .activity: HomeView(path: $activityPath)
            case .schedule: WeeklyScheduleView()
            case .group: GroupTabView()
            }

            bottomToggle
                .padding(.bottom, 12)
        }
        .background(TL.ink.ignoresSafeArea())
        .animation(TLMotion.smooth, value: tab)
        .onChange(of: showsGroupTab) {
            if !showsGroupTab, tab == .group { tab = .activity }
        }
    }

    /// 하단 알약형 토글 — 글래스모피즘(반투명 블러) + 아이콘, 애플 탭바 감성
    private var bottomToggle: some View {
        HStack(spacing: 5) {
            // 활동 = 불꽃(다짐을 불태운다), 일정 = 시계, 그룹 = 사람들
            toggleSegment("활동", icon: "flame.fill", tab: .activity)
            toggleSegment("일정", icon: "clock.fill", tab: .schedule)
            if showsGroupTab {
                toggleSegment("그룹", icon: "person.3.fill", tab: .group)
            }
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
        // 3개 탭이면 캡슐 폭을 줄여 한 줄에 들어가게 한다
        let compact = showsGroupTab
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // 이미 그 탭이면 그 탭의 첫 화면으로 돌아간다 — iOS 탭바의 표준 동작이다.
            if tab == target {
                if target == .activity { activityPath = NavigationPath() }
            } else {
                withAnimation(TLMotion.snappy) { tab = target }
            }
        } label: {
            HStack(spacing: compact ? 6 : 8) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 17 : 20, weight: .semibold))
                Text(title)
                    .font(.system(size: compact ? 17 : 20, weight: .bold, design: .rounded))
            }
            .foregroundStyle(selected ? TL.ink : TL.paper.opacity(0.72))
            .padding(.horizontal, compact ? 18 : 32)
            .padding(.vertical, compact ? 13 : 15)
            .background(
                Capsule()
                    .fill(selected ? AnyShapeStyle(TL.paper) : AnyShapeStyle(.clear))
                    .shadow(color: selected ? .black.opacity(0.25) : .clear, radius: 5, y: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 활동 탭에서 밀어 올리는 화면들. 값 기반이어야 쉘이 들고 있는 경로로 되돌릴 수 있다
/// (뷰를 직접 넘기는 방식은 경로에 남지 않아 '활동' 탭을 다시 눌러도 못 빠져나온다).
enum HomeRoute: Hashable { case calendar, myPage }

// MARK: - 홈 (활동)

struct HomeView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var account: AccountStore
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Reservation> { $0.isActive }, sort: \Reservation.startMinute)
    private var allActiveReservations: [Reservation]
    @Query private var allSessions: [FocusSession]

    /// 현재 계정의 예약만
    private var reservations: [Reservation] {
        allActiveReservations.filter { $0.ownerUserID == account.currentUserID }
    }

    /// 현재 계정의 세션만
    private var mySessions: [FocusSession] {
        allSessions.filter { $0.ownerUserID == account.currentUserID }
    }

    /// 누적 활동 성공 시간 — 완주 세션의 순수 촬영 시간 합(시간 단위 내림).
    /// 상/벌점 배지를 대체한다: 홈에서 매일 마주하는 숫자는 벌점이 아니라 쌓인 시간이어야 한다.
    private var totalSuccessHours: Int {
        mySessions.filter { $0.outcome?.isSuccess == true }
            .reduce(0) { $0 + $1.recordedSeconds } / 3600
    }
    private var totalSuccessHoursLabel: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: totalSuccessHours)) ?? "\(totalSuccessHours)"
    }

    @State private var now = Date()
    @State private var editorTarget: EditorTarget?

    /// 편집 시트 대상 — Identifiable 아이템으로 예약을 원자적으로 전달한다.
    /// (isPresented + 별도 @State 조합은 시트 콘텐츠가 예전 값으로 만들어질 수 있어
    ///  탭 전환 후 첫 진입에서 활동명이 비어 보이는 문제가 있었다. item: 방식이 이를 막는다.)
    private enum EditorTarget: Identifiable {
        case new
        case edit(Reservation)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let r): return r.id.uuidString
            }
        }
    }
    @State private var showQuickStart = false
    @State private var showGoalEditor = false
    @State private var goalText = ""
    @State private var showGroupLockNotice = false

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// '오늘' 발생하는 활동 — 일정 탭의 오늘 칸과 완전히 같은 기준(요일/일회성 매칭)으로 판정한다.
    /// 그룹 방 시작일 전이거나 오늘치 시각이 지났어도, 일정 탭에 보이면 홈에도 똑같이 보이게 한다.
    /// 이미 완료(성공·실패)한 활동도 목록에 남긴다 — 흐림 처리 + 결과 점으로 '오늘 한 일'이
    /// 보여야 하루가 쌓이는 감각이 든다. 미완료가 먼저, 완료는 아래로.
    private var upcoming: [(reservation: Reservation, fire: Date?, done: SessionOutcome?)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return reservations
            .compactMap { r -> (Reservation, Date?, SessionOutcome?)? in
                // 알람시계 로직(occurrence) 한 곳으로 오늘 발생 여부 판정 —
                // 시작일 전·종료일 후는 자동 제외. 오늘치 시각이 지났어도 발생 자체는 유효.
                guard let fire = r.occurrence(on: today) else { return nil }
                return (r, fire, todayOutcome(r))
            }
            .sorted {
                // 미완료 우선, 같은 그룹 안에서는 발생 시각순
                if ($0.2 == nil) != ($1.2 == nil) { return $0.2 == nil }
                return ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture)
            }
    }

    /// 오늘 이 예약의 확정 결과 — 기록이 여럿(긴급 중단 후 재촬영)이면 가장 나중 것.
    /// nil = 아직 시작 전(또는 진행 중 — 촬영 중엔 홈이 보일 일이 없다).
    private func todayOutcome(_ r: Reservation) -> SessionOutcome? {
        let cal = Calendar.current
        let rid = r.id
        let owner = account.currentUserID
        return allSessions
            .filter { s in
                s.ownerUserID == owner && s.reservationID == rid && s.outcome != nil &&
                (s.scheduledAt.map { cal.isDateInToday($0) } ?? false)
            }
            .max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }?
            .outcome
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                        .padding(.top, 6)

                    streakCard

                    goalCard

                    Button("활동 추가하기") {
                        editorTarget = .new
                    }
                    .buttonStyle(TLPrimaryButtonStyle())

                    quickStartRow

                    upcomingSection
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 116)   // 하단 토글 자리
            }
            .background(TL.ink)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .calendar: CalendarView()
                case .myPage:   MyPageView()
                }
            }
            .sheet(item: $editorTarget) { target in
                switch target {
                case .new:            ReservationEditView(reservation: nil)
                case .edit(let r):   ReservationEditView(reservation: r)
                }
            }
            .sheet(isPresented: $showQuickStart) {
                QuickStartSheet()
                    .presentationDetents([.height(420)])
            }
            .sheet(isPresented: $showGoalEditor) {
                GoalEditorSheet(goal: $goalText) { account.saveHomeGoal(goalText) }
                    .presentationDetents([.height(260)])
            }
            .onReceive(clock) { now = $0 }
            .onAppear { account.reloadHomeGoal() }
            .onChange(of: account.currentUserID) { account.reloadHomeGoal() }
            .alert("그룹 일정이에요", isPresented: $showGroupLockNotice) {
                Button("확인", role: .cancel) {}
            } message: {
                Text("그룹에서 만들어진 일정은 수정하거나 삭제할 수 없어요. 그만두려면 그룹 탭에서 탈퇴하세요.")
            }
        }
    }

    // MARK: 헤더 — 누적 성공 시간 + 마이페이지

    private var header: some View {
        HStack(spacing: 10) {
            // 누적 활동 성공 시간 배지 (좌측 정렬) — 탭 → 기록 캘린더.
            NavigationLink(value: HomeRoute.calendar) {
                HStack(spacing: 8) {
                    Image("clock")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                    (Text(totalSuccessHoursLabel).foregroundStyle(TL.jade)
                     + Text("시간").foregroundStyle(TL.muted))
                        .font(.tlTimer(21))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(TL.surface))
                .overlay(Capsule().strokeBorder(TL.hairline, lineWidth: 1))
            }
            .pressableStyle()

            Spacer()

            // 기록관리 — 시간 배지와 동일하게 기록 캘린더로 진입
            NavigationLink(value: HomeRoute.calendar) {
                Image(systemName: "calendar")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(TL.paper)
                    .frame(width: 45, height: 45)
                    .background(Circle().fill(TL.surface))
                    .overlay(Circle().strokeBorder(TL.hairline, lineWidth: 1))
            }
            .pressableStyle()

            // 마이페이지
            NavigationLink(value: HomeRoute.myPage) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 45))
                    .foregroundStyle(TL.muted)
            }
            .pressableStyle()
        }
    }

    // MARK: 연속달성 카드 — 좌측 일수 + 우측 5일 스트립 (D-3 ~ 내일)

    private var streakCard: some View {
        let streak = SlotPolicy.currentStreak(sessions: mySessions)
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekdayNames = ["", "일", "월", "화", "수", "목", "금", "토"]

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("연속달성")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(TL.muted)
                    Image("fire").resizable().scaledToFit().frame(width: 14, height: 14)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(streak)")
                        .font(.tlTimer(30))
                        .foregroundStyle(TL.jade)
                    Text("일")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(TL.muted)
                }
            }

            Spacer(minLength: 6)

            // 최근 3일 + 오늘 + 내일. 판정은 기록 캘린더와 같은 규칙(DayOutcomeIcon) 하나.
            HStack(spacing: 0) {
                ForEach(-3...1, id: \.self) { offset in
                    let day = cal.date(byAdding: .day, value: offset, to: today) ?? today
                    let daySessions = mySessions.filter { cal.isDate($0.anchorDate, inSameDayAs: day) }
                    let icon = DayOutcomeIcon.judge(daySessions: daySessions, day: day, now: now)
                        ?? .notStarted
                    let isToday = offset == 0

                    VStack(spacing: 5) {
                        Text(weekdayNames[cal.component(.weekday, from: day)])
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(isToday ? TL.paper : TL.faint)
                        Image(icon.assetName)
                            .resizable().scaledToFit()
                            .frame(width: 24, height: 24)
                            .opacity(offset > 0 ? 0.45 : 1)   // 아직 오지 않은 날은 흐리게
                        Text("\(cal.component(.day, from: day))")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(isToday ? TL.paper : TL.muted)
                    }
                    .frame(width: 44)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: TL.cornerS, style: .continuous)
                            .fill(isToday ? TL.raised : .clear)
                    )
                    // 열 사이 헤어라인 (마지막 열 제외)
                    .overlay(alignment: .trailing) {
                        if offset < 1 {
                            Rectangle().fill(TL.hairline.opacity(0.35)).frame(width: 1, height: 30)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
        .overlay(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
            .strokeBorder(TL.hairline.opacity(0.6), lineWidth: 1))
    }

    // MARK: 다짐/목표 카드

    private var goalCard: some View {
        Button {
            goalText = account.homeGoal   // 편집 시트 초안을 현재 값으로 시드
            showGoalEditor = true
        } label: {
            VStack(spacing: 6) {
                if account.homeGoal.isEmpty {
                    Text("나의 다짐, 목표를 적어보세요")
                        .font(.tlTitle(17))
                        .foregroundStyle(TL.faint)
                    Text("탭해서 작성")
                        .font(.system(size: 12)).foregroundStyle(TL.faint)
                } else {
                    Text(account.homeGoal)
                        .font(.tlTitle(18))
                        .foregroundStyle(TL.paper)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 84)   // 연속달성 카드가 들어온 만큼 다짐 카드는 낮게
            .padding(16)
            .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
            .overlay(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
                .strokeBorder(TL.hairline.opacity(0.6), lineWidth: 1))
        }
        .pressableStyle()
    }

    // 다짐 저장/로드/동기화는 AccountStore(homeGoal published)로 일원화 — 여기선 편집 초안(goalText)만 다룬다.

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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("오늘 예정된 활동")
                    .font(.tlTitle(20))
                    .foregroundStyle(TL.paper)
                Text(todayDateLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(TL.faint)
            }

            if upcoming.isEmpty {
                TLCard {
                    Text("오늘은 예정된 활동이 없어요. 이번 주 계획은 일정 탭에서 확인할 수 있어요.")
                        .font(.system(size: 13)).foregroundStyle(TL.muted)
                }
            } else {
                ForEach(upcoming, id: \.reservation.id) { item in
                    reservationCard(item.reservation, fire: item.fire, done: item.done)
                }
            }
        }
    }

    private var todayDateLabel: String {
        let comps = Calendar.current.dateComponents([.month, .day], from: now)
        return "\(comps.month ?? 1)월 \(comps.day ?? 1)일"
    }

    private func reservationCard(_ reservation: Reservation, fire: Date?,
                                 done: SessionOutcome?) -> some View {
        // 12시간 이내로 들어온 미완료 활동만 남은 시간 타이머(앰버) 표시
        let remaining = fire.map { Int($0.timeIntervalSince(now)) } ?? -1
        let showsTimer = done == nil && remaining > 0 && remaining <= 12 * 3600
        // 완료 결과 점 — 일정 탭의 불빛과 같은 규칙 (성공 초록 / 실패 빨강 / 중립 앰버)
        let doneTint: Color? = done.map {
            $0.isSuccess ? TL.jade : ($0.isFailure ? TL.rec : TL.amber)
        }

        return Button {
            // 그룹 예약은 편집 잠금 — 그룹 탭에서 관리 (탈퇴로만 삭제)
            guard !reservation.isGroupReservation else {
                showGroupLockNotice = true
                return
            }
            editorTarget = .edit(reservation)
        } label: {
            TLCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if reservation.isGroupReservation {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(TL.amber)
                        }
                        Text(reservation.name)
                            .font(.tlTitle(17))
                            .foregroundStyle(TL.paper)
                            .lineLimit(1)
                        Spacer()
                        if showsTimer {
                            Text(remainingMinuteLabel(remaining))
                                .font(.system(size: 13, weight: .heavy, design: .rounded))
                                .foregroundStyle(TL.amber)
                                .lineLimit(1)
                                .layoutPriority(1)   // 이름보다 카운트다운 문구를 우선 확보
                        } else {
                            if let doneTint {
                                // 오늘 결과 점 — 태그 칩 왼편 (일정 탭과 동일 문법)
                                Circle().fill(doneTint).frame(width: 9, height: 9)
                            }
                            TagChip(name: reservation.tag)
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "bell.fill").font(.system(size: 11))
                        if let fire {
                            // 오늘 것만 보여주므로 날짜(오늘·내일·M월 D일)는 생략하고 시각만.
                            Text("\(TLFormat.clock(fire)) · \(TLFormat.durationLabel(reservation.durationMinutes)) · \(reservation.repeatLabel())")
                        } else {
                            Text(TLFormat.durationLabel(reservation.durationMinutes))
                        }
                        Spacer()
                        if showsTimer {
                            TagChip(name: reservation.tag)
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(TL.muted)
                }
            }
            // 완료한 활동은 흐림 처리로 목록에 남긴다 (일정 탭의 '지나감'과 동일 문법)
            .opacity(done == nil ? 1 : 0.42)
        }
        .pressableStyle()
    }

    /// 남은 시간을 분단위 문구로 — 초 카운트다운의 불안감을 줄인다 (12시간 이내만 노출).
    /// 1분 미만은 "곧 시작", 그 외 "59분 / 1시간 20분 / 3시간 뒤 시작". 올림.
    private func remainingMinuteLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "곧 시작" }
        let m = Int((Double(seconds) / 60).rounded(.up))
        let time = m >= 60 ? (m % 60 == 0 ? "\(m / 60)시간" : "\(m / 60)시간 \(m % 60)분") : "\(m)분"
        return "\(time) 뒤 시작"
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
                    HStack {
                        TLEyebrow(text: "활동 시간")
                        Spacer()
                        // 선택한 길이의 완주 상점 미리 보기
                        Text("완료 시 +\(ScoreRules.completionBase(forMinutes: minutes))점")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundStyle(TL.jade)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(TL.jade.opacity(0.14)))
                    }
                    Picker("활동 시간", selection: $minutes) {
                        ForEach(TimePolicy.durationOptionsMinutes, id: \.self) {
                            Text(TLFormat.durationLabel($0)).tag($0)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 110)
                }

                Button("촬영 준비하기") {
                    let finalName = name.trimmingCharacters(in: .whitespaces)
                    guard !finalName.isEmpty else { return }
                    dismiss()
                    app.startImmediate(name: finalName, tag: tag, minutes: minutes)
                }
                .buttonStyle(TLPrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)

                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("활동명을 입력해야 시작할 수 있습니다.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TL.amber)
                }
            }
            .padding(20)
            .background(TL.ink)
            .navigationTitle("지금 바로 시작")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
