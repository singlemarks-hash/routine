//
//  ReservationEditView.swift
//  TimeLock
//
//  활동 예약 생성/조회/수정/삭제.
//  - 활동명(필수)/태그/시작 시각/활동 시간(10분~8시간)/반복(요일·일회성)
//  - 겹치는 시간대 예약은 저장 차단 + 충돌 메시지
//  - 시작 30분 전부터 수정/삭제 잠금
//

import SwiftUI
import SwiftData

struct ReservationEditView: View {
    let reservation: Reservation?   // nil = 생성

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var subscription: SubscriptionManager
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Reservation> { $0.isActive }) private var allActiveReservations: [Reservation]
    @Query private var allSessions: [FocusSession]

    /// 겹침 검사·슬롯 카운트 모두 현재 계정의 예약 전체 —
    /// 그룹 챌린지 예약도 슬롯 1개를 차지한다 (슬롯을 늘리려면 연속 달성이 필요하도록)
    private var allReservations: [Reservation] {
        allActiveReservations.filter { $0.ownerUserID == account.currentUserID }
    }

    /// 슬롯을 실제로 차지하는 활동 — 앞으로 울릴 일이 남은 것만 센다.
    /// 오늘 끝난 활동은 오늘 일정에 계속 보이지만 슬롯은 이미 돌려준 상태다.
    private var slotUsingReservations: [Reservation] {
        allReservations.filter { $0.hasRemainingOccurrence() }
    }

    // MARK: 활동 슬롯 정책 (원띵 원칙 — 연속 달성일 사다리)
    // 3일→3개, 5일→4개, 7일→5개, 10일→10개, 30일→무제한.
    // 연속이 끊기면 한도가 내려가지만 기존 예약은 유지 — 새 추가만 제한된다.

    private var currentStreak: Int {
        SlotPolicy.currentStreak(sessions: allSessions.filter { $0.ownerUserID == account.currentUserID })
    }
    /// 현재 허용되는 최대 활동 수 (nil = 무제한)
    private var allowedSlots: Int? {
        SlotPolicy.allowedSlots(forStreak: currentStreak, isMember: subscription.isPro)
    }

    @State private var name = ""
    @State private var tag = ActivityTag.presets[0]
    @State private var customTag = ""
    /// 기본 시작 시각 = (현재 + 2시간)의 정각.
    /// 예: 9:39 → 11:00, 9:00 → 11:00, 8:59 → 10:00
    @State private var startTime: Date = {
        let cal = Calendar.current
        let plus2h = Date().addingTimeInterval(2 * 3600)
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: plus2h)
        return cal.date(from: comps) ?? plus2h
    }()
    @State private var durationMinutes = 60
    @State private var intensity: Intensity = .spicy
    @State private var isRepeating = false
    @State private var weekdays: Set<Int> = []
    @State private var oneOffDate = Date()          // 요일 반복 OFF일 때의 '시작일'
    @State private var noEndDate = true             // '종료일 없음' (기본 켜짐 = 무기한)
    @State private var oneOffEndDate = Date()       // '종료일' (종료일 없음 끄면 사용)
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false
    @State private var showSlotPolicy = false
    @FocusState private var customTagFocused: Bool

    private let weekdaySymbols = [(1, "일"), (2, "월"), (3, "화"), (4, "수"), (5, "목"), (6, "금"), (7, "토")]
    private let durations = TimePolicy.durationOptionsMinutes

    /// 편집 잠금 창: 발생 30분 전 ~ 발생 +10분(노쇼 확정 시점).
    /// 정각에 풀리면 알람을 놓친 직후(스윕 전 10분 안에) 예약을 아무거나 고쳐 저장해
    /// accountableFrom을 갱신, 방금 노쇼를 면책하는 회피 경로가 열린다 — 스윕이 그 발생을
    /// 확정하기 전까지는 어떤 편집도 막는다.
    private var isLocked: Bool {
        guard let r = reservation else { return false }
        if let next = r.nextOccurrence(), next.timeIntervalSinceNow <= 1800 { return true }
        // 방금 지난 발생이 아직 노쇼 확정 전인가 — 어제·오늘 발생 중 [발생, 발생+10분] 안이면 잠금
        let cal = Calendar.current
        let now = Date()
        for offset in [-1, 0] {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)),
                  let fire = r.occurrence(on: day, calendar: cal) else { continue }
            if fire <= now, now.timeIntervalSince(fire) <= TimePolicy.startWindowSeconds { return true }
        }
        return false
    }

    /// 슬롯 초과 상태 — 멤버십 강등·연속 하락으로 보유 예약이 허용치를 넘은 경우.
    /// 기존 예약은 유지하되 편집을 잠그고 삭제만 허용한다(읽기 전용).
    private var isOverSlotLimit: Bool {
        guard let allowed = allowedSlots else { return false }   // 무제한이면 초과 없음
        return slotUsingReservations.count > allowed
    }
    /// 미친 매운맛으로 만든 활동인데 지금은 그 등급을 쓸 수 없는 상태(멤버십 만료 등).
    /// 강도를 임의로 내리면 이미 쌓인 2배 벌점 기준이 바뀌므로 그대로 유지하고,
    /// 조회와 삭제만 허용한다. (다시 쓰려면 멤버십을 복구하면 된다)
    private var isLockedInsane: Bool {
        guard let r = reservation else { return false }
        return r.intensityOverride == .insane && !app.insaneUnlocked
    }

    /// 편집 화면(기존 예약)에서 읽기 전용이 되는 조건 — 슬롯 초과 또는 잠긴 미친맛
    private var isEditReadOnly: Bool { reservation != nil && (isOverSlotLimit || isLockedInsane) }

    /// 은퇴한 예약 — 삭제(오늘로 은퇴) 또는 자연 종료로 앞으로 발생이 없다.
    /// 일정 탭에는 오늘 자정까지만 남는 '보여주기 전용' 상태다. 편집·저장은 물론
    /// 삭제 버튼도 잠근다 — 이미 삭제(종료)된 것을 또 삭제할 수는 없고, 여기서
    /// 무언가를 바꿀 수 있으면 은퇴로 닫아둔 노쇼 집계·기록 정합이 다시 열린다.
    private var isRetired: Bool {
        guard let r = reservation else { return false }
        return !r.hasRemainingOccurrence()
    }

    /// 입력 필드·저장 비활성 조건 = 시작 임박 ∨ 슬롯 초과 읽기 전용 ∨ 은퇴 (삭제는 은퇴만 잠금)
    private var editingDisabled: Bool { isLocked || isEditReadOnly || isRetired }

    /// 이미 시작한 활동은 시작일을 바꿀 수 없다.
    ///
    /// 시작일은 그대로 createdAt(발생 시작 게이트)에 저장되는데, 노쇼 복구 루틴이
    /// 'scheduledAt < createdAt인 노쇼는 잘못된 기록'으로 보고 세션·벌점을 지운다.
    /// 시작일을 자유롭게 미룰 수 있으면 그 이전의 정당한 벌점이 전부 삭제되는
    /// 회피 경로가 열린다. 첫 발생이 이미 지났다면(=노쇼가 생길 수 있었다면) 잠근다.
    /// 아직 시작 전인 예약은 지울 기록 자체가 없으므로 자유롭게 바꿔도 안전하다.
    private var isStartDateLocked: Bool {
        guard let r = reservation else { return false }   // 신규 생성은 자유
        return lockedStartDay(of: r) != nil
    }

    /// 잠긴 예약이 강제로 써야 할 시작일(그 날 자정). 잠기지 않았으면 nil.
    ///
    /// 기준은 createdAt이 아니라 '실제 발생이 시작되는 날'이다. 레거시 일회성 예약은
    /// createdAt이 '만든 시각'이라 실제 날짜(oneOffDate)보다 훨씬 이르고, createdAt으로
    /// 판정하면 미래 날짜의 일회성 예약도 이미 시작한 것으로 잠겨 버린다. 그 상태로 저장하면
    /// 시작일이 만든 날로 끌려가 '만든 날부터 그 날까지 매일'로 바뀌는 손상이 난다.
    private func lockedStartDay(of r: Reservation) -> Date? {
        let cal = Calendar.current
        let startDay = r.activeDayRange(calendar: cal).lo
        // 시작 게이트 당일에 시각만 더하면 안 된다 — 그날이 고른 요일이 아닐 수 있다.
        // (7/20 월요일부터 '토요일마다'면 첫 발생은 7/25이지 7/20이 아니다)
        // 요일은 7개뿐이라 8일이면 실제 첫 발생을 반드시 찾는다.
        var firstFire: Date?
        for offset in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: startDay),
                  let fire = r.occurrence(on: day, calendar: cal) else { continue }
            firstFire = fire
            break
        }
        guard let firstFire else { return nil }
        return firstFire <= Date() ? startDay : nil
    }

    /// 활동 슬롯 현황 (원띵 — 신규 생성 화면에만). 탭하면 정책 표 팝업.
    private var slotPolicyNotice: some View {
        let used = slotUsingReservations.count
        let allowed = allowedSlots            // nil = 무제한 (연속 30일+)
        let full = allowed.map { used >= $0 } ?? false
        let slotLabel = allowed.map { "\(used)/\($0)" } ?? "\(used)/무제한"

        return Button {
            showSlotPolicy = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: full ? "lock.fill" : "flame.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(full ? TL.amber : TL.jade)
                VStack(alignment: .leading, spacing: 2) {
                    Text("활동 슬롯 \(slotLabel) · 연속 달성 \(currentStreak)일")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(TL.paper)
                    Text("터치하면 슬롯 정책을 볼 수 있어요")
                        .font(.system(size: 11)).foregroundStyle(TL.faint)
                }
                Spacer()
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(TL.muted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                .fill((full ? TL.amber : TL.jade).opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // 오류는 최상단(저장 버튼 바로 아래)에 — 스크롤 없이 즉시 보이게
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TL.rec)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                                .fill(TL.rec.opacity(0.12)))
                            .id("errorBanner")
                            .onAppear { withAnimation(TLMotion.smooth) { proxy.scrollTo("errorBanner", anchor: .top) } }
                            .onChange(of: errorMessage) {
                                withAnimation(TLMotion.smooth) { proxy.scrollTo("errorBanner", anchor: .top) }
                            }
                    }
                    if isRetired {
                        retiredNotice          // 은퇴 안내 하나만 — 다른 잠금 사유는 의미 없음
                    } else {
                        if isLocked {
                            lockNotice
                        }
                        if isEditReadOnly {
                            readOnlyNotice
                        }
                    }
                    if reservation == nil {
                        slotPolicyNotice
                    }
                    nameSection
                    tagSection
                    intensitySection
                    timeAndDurationSection
                    repeatSection
                    if reservation != nil && !isRetired {
                        Button("예약 삭제") { showDeleteConfirm = true }
                            .buttonStyle(TLGhostButtonStyle(tint: TL.rec))
                            .disabled(isLocked)   // 읽기 전용(슬롯 초과)에서도 삭제는 허용
                            .opacity(isLocked ? 0.4 : 1)
                    }
                }
                .padding(20)
            }
            .background(TL.ink)
            .navigationTitle(reservation == nil ? "활동 예약" : "예약 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }.foregroundStyle(TL.muted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !isRetired {           // 은퇴한 예약은 저장 버튼 자체가 없다 — 보여주기 전용
                        Button("저장") { save() }
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(editingDisabled ? TL.faint : TL.rec)
                            .disabled(editingDisabled)
                    }
                }
            }
            .confirmationDialog("이 예약을 삭제할까요?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("삭제", role: .destructive) { delete() }
            }
            .sheet(isPresented: $showSlotPolicy) {
                SlotPolicySheet(currentStreak: currentStreak, usedSlots: slotUsingReservations.count,
                                isMember: subscription.isPro)
                    .presentationDetents([.medium, .large])
            }
            .onAppear(perform: load)
            }   // ScrollViewReader
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 섹션

    /// 은퇴한(삭제·종료된) 예약 안내 — 보여주기 전용, 오늘 자정까지만 목록에 남는다.
    private var retiredNotice: some View {
        TLCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock.badge.xmark.fill").foregroundStyle(TL.amber)
                Text("이 활동은 삭제(종료)되어 더 이상 수정할 수 없습니다. 오늘 기록 확인용으로 자정까지만 일정에 표시되고, 이후에는 목록에서 사라집니다. 지난 기록은 기록 탭에서 계속 볼 수 있어요.")
                    .font(.system(size: 13))
                    .foregroundStyle(TL.paper)
            }
        }
    }

    private var lockNotice: some View {
        TLCard {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(TL.amber)
                Text("시작 30분 전입니다. 다짐을 지키기 위해 이 예약은 더 이상 수정하거나 삭제할 수 없습니다.")
                    .font(.system(size: 13))
                    .foregroundStyle(TL.paper)
            }
        }
    }

    /// 슬롯 초과(강등·연속 하락)로 읽기 전용일 때의 안내 — 삭제만 가능
    private var readOnlyNotice: some View {
        TLCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.slash.fill").foregroundStyle(TL.amber)
                // 두 사유가 겹칠 수 있다. 하나만 보여주면 "멤버십을 복구하면 편집된다"고 안내해놓고
                // 복구해도 슬롯 초과로 여전히 잠기는 상황이 된다 — 걸린 사유를 모두 적는다.
                Text([isLockedInsane
                      ? "미친 매운맛으로 만든 활동이에요. 지금은 그 등급을 쓸 수 없어 조회와 삭제만 할 수 있습니다. 강도를 임의로 내리면 이미 쌓인 2배 기준이 바뀌므로 그대로 둡니다."
                      : nil,
                      isOverSlotLimit
                      ? "활동 슬롯이 \(allowedSlots.map { "\($0)개" } ?? "무제한")로 줄어 보유한 예약이 한도를 넘었습니다. 예약을 슬롯 수 이내로 정리하거나 멤버십·연속 달성으로 슬롯을 늘리면 다시 편집할 수 있어요."
                      : nil].compactMap { $0 }.joined(separator: "\n\n"))
                    .font(.system(size: 13))
                    .foregroundStyle(TL.paper)
            }
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TLEyebrow(text: "활동명 (필수)")
            TextField("예: 기출문제 3회분", text: $name)
                .font(.tlBody)
                .padding(14)
                .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerM))
                .overlay(
                    RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                        .strokeBorder(TL.paper.opacity(0.7), lineWidth: 1.5)
                )
                .disabled(editingDisabled)
                .onChange(of: name) { _, new in
                    if new.count > ActivityTag.nameMaxLength {
                        name = String(new.prefix(ActivityTag.nameMaxLength))
                    }
                }
        }
    }

    /// 직접 입력 칸을 '쓰는 중'인가 — 커서가 들어와 있거나 이미 입력값이 있는 상태.
    ///
    /// 태그는 프리셋과 직접 입력 중 하나만 쓰인다(저장 시 직접 입력이 우선). 그런데 둘이
    /// 항상 같은 밝기로 나란히 있으면, 프리셋을 고른 사람은 "밑에도 채워야 하나" 싶고
    /// 직접 입력하는 사람은 "위 태그도 같이 붙나" 싶어진다. 그래서 쓰는 쪽만 살리고
    /// 반대쪽은 눌러둔다 — 직접 입력을 건드리는 순간 프리셋은 흐려지고 눌리지 않는다.
    private var customTagActive: Bool {
        customTagFocused || !customTag.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TLEyebrow(text: "태그")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ActivityTag.presets, id: \.self) { preset in
                        Button {
                            // 프리셋을 고르면 직접 입력은 비우고 커서도 뺀다 — 두 값이
                            // 동시에 남아 있으면 어느 쪽이 저장될지 화면만 봐선 알 수 없다.
                            customTagFocused = false
                            customTag = ""
                            tag = preset
                        } label: {
                            TagChip(name: preset, selected: !customTagActive && tag == preset)
                        }
                        .disabled(editingDisabled || customTagActive)
                    }
                }
            }
            .opacity(customTagActive ? 0.3 : 1)

            if customTagActive {
                Text("직접 입력한 태그를 씁니다 — 위 태그는 적용되지 않아요.")
                    .font(.system(size: 11))
                    .foregroundStyle(TL.faint)
            }

            TextField("직접 입력 (선택)", text: $customTag)
                .font(.system(size: 14))
                .focused($customTagFocused)
                .padding(10)
                .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerS))
                // 테두리는 이 칸을 실제로 쓸 때만 — 평소에 선이 없어야
                // '굳이 채우지 않아도 되는 칸'으로 읽힌다(활동명은 그 반대라 늘 선이 있다).
                .overlay(
                    RoundedRectangle(cornerRadius: TL.cornerS, style: .continuous)
                        .strokeBorder(customTagActive ? TL.paper.opacity(0.7) : .clear, lineWidth: 1.5)
                )
                .disabled(editingDisabled)
                .onChange(of: customTag) { _, newValue in
                    // 폭 예산을 넘기면 잘라낸다 — 되감긴 값으로 onChange가 한 번 더 돌지만
                    // 그때는 capped == newValue라 그대로 멎는다.
                    let capped = ActivityTag.truncatedToTagWidth(newValue)
                    if capped != newValue { customTag = capped }
                    // tag(프리셋 선택)에는 쓰지 않는다. 예전엔 여기서 tag를 덮어써서,
                    // 입력을 다 지워도 지워진 커스텀 문자열이 tag에 남아 그대로 저장됐다.
                }
        }
        // 프리셋 흐려짐·안내문·테두리가 한 동작으로 같이 움직이게 한다.
        .animation(TLMotion.smooth, value: customTagActive)
    }

    /// 강도 — 활동별로 설정 (그룹 방 만들기와 동일한 세그먼트, 혼자 하는 활동이라 '참여자 전원' 문구는 뺀다).
    /// 미친 매운맛은 멤버십 전용 — 무료 사용자에겐 잠금 표시 + 비활성화된 UI로 보여준다.
    private var intensitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TLEyebrow(text: "강도")
            HStack(spacing: 8) {
                ForEach(Intensity.allCases) { candidate in
                    let locked = candidate == .insane && !app.insaneUnlocked
                    Button {
                        guard !locked else { return }
                        intensity = candidate
                    } label: {
                        VStack(spacing: 3) {
                            HStack(spacing: 4) {
                                if locked { Image(systemName: "lock.fill").font(.system(size: 11)) }
                                Text("\(candidate.emoji) \(candidate.title)")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                            }
                            Text(locked ? "멤버십 전용"
                                 : (candidate == .spicy ? "최대 10분 긴급용무 허용" : "봐주기 없는 100% 몰입, 점수 2배"))
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(intensity == candidate ? TL.ink : (locked ? TL.faint : TL.muted))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                            .fill(intensity == candidate ? TL.paper : TL.surface))
                        .overlay(
                            RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                                .strokeBorder(TL.hairline.opacity(locked ? 0.5 : 0), lineWidth: 1)
                        )
                        // 잠긴 카드는 선택 여부와 무관하게 흐리게 — 눈으로도 '지금은 못 쓴다'가 읽혀야 한다.
                        .opacity(locked ? 0.45 : 1)
                        .saturation(locked ? 0 : 1)
                    }
                    .disabled(editingDisabled || locked)
                }
            }
        }
    }

    /// 시작 시각 + 활동 길이 — 컴팩트 pill(탭하면 팝업) + 길이 메뉴 + 완주 상점 미리보기.
    /// 가장 직관적이라 그룹 방 만들기와 동일한 형태로 통일.
    private var timeAndDurationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TLEyebrow(text: "몇시에 얼마나 진행하나요?")
            TLCard {
                VStack(spacing: 4) {
                    DatePicker("시작 시각", selection: $startTime, displayedComponents: .hourAndMinute)
                        .font(.tlBody).foregroundStyle(TL.paper)
                        .disabled(editingDisabled)
                    Divider().overlay(TL.hairline)
                    HStack(spacing: 10) {
                        Picker("활동 시간", selection: $durationMinutes) {
                            ForEach(durations, id: \.self) { Text(TLFormat.durationLabel($0)).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(TL.paper)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(editingDisabled)
                        Text("완료 시 +\(ScoreRules.completionBase(forMinutes: durationMinutes))점")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundStyle(TL.jade)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(TL.jade.opacity(0.14)))
                    }
                }
            }
        }
    }

    /// 시작일=종료일이면 그날 하루뿐이라 요일 반복 설정 자체가 무의미하다 (그 요일이 빠지면
    /// 발생이 0번이 되는 모순도 막는다) — 이 경우 요일 반복 UI를 아예 숨긴다.
    private var isSingleDay: Bool {
        !noEndDate && Calendar.current.isDate(oneOffDate, inSameDayAs: oneOffEndDate)
    }

    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TLEyebrow(text: "반복")
            TLCard {
                VStack(alignment: .leading, spacing: 14) {
                    // 기간 — 시작일 먼저 정하고, 그 기간에 요일 반복을 적용할지 고른다.
                    if isStartDateLocked {
                        // 이미 시작한 활동은 읽기 전용으로만 보여준다. DatePicker를 쓰면
                        // 선택 범위(오늘~) 밖의 과거 날짜라 표시가 깨지고, 되돌릴 수 없는
                        // 기록 삭제로 이어질 수 있다.
                        HStack {
                            Text("시작일").font(.tlBody).foregroundStyle(TL.paper)
                            Spacer()
                            Text(oneOffDate, style: .date)
                                .font(.tlBody).foregroundStyle(TL.muted)
                        }
                        Text("이미 시작한 활동이라 시작일은 바꿀 수 없어요. 지난 기록과 점수를 지키기 위한 제한이에요.")
                            .font(.system(size: 12)).foregroundStyle(TL.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // 하한은 '지금'이 아니라 '오늘 자정' — 오늘을 고를 수 있어야 한다.
                        // 상한은 ReservationPolicy.maxStartLeadMonths(1개월) — 그보다 먼 알람은
                        // 앱 업데이트·기기 교체를 지나서까지 울린다고 보장할 수 없다.
                        DatePicker("시작일", selection: $oneOffDate,
                                   in: Calendar.current.startOfDay(for: Date())...ReservationPolicy.maxStartDay(),
                                   displayedComponents: .date)
                            .font(.tlBody).foregroundStyle(TL.paper)
                            .disabled(editingDisabled)
                            // 시작일을 뒤로 옮기면 종료일도 함께 밀어준다. 이게 없으면 종료일이
                            // 예전 값(과거)에 남아, 시작일·종료일을 같은 날로 고른 줄 알았는데
                            // "종료일은 시작일 이후여야 해요"로 저장이 막힌다. DatePicker의
                            // in: 범위는 선택지만 제한할 뿐 값을 되돌려 써주지 않는다.
                            //
                            // 종료일을 시작일에 '붙이지' 말고 기간 길이를 유지한 채 통째로 민다.
                            // 붙이면 시작일=종료일이 되어 요일 반복 UI가 사라지고, 저장 시
                            // 고른 요일이 전체 요일로 덮여 월·수·금 반복이 조용히 하루짜리가 된다.
                            .onChange(of: oneOffDate) { oldStart, newStart in
                                guard oneOffEndDate < newStart else { return }
                                let cal = Calendar.current
                                let span = cal.dateComponents([.day],
                                                              from: cal.startOfDay(for: oldStart),
                                                              to: cal.startOfDay(for: oneOffEndDate)).day ?? 0
                                oneOffEndDate = cal.date(byAdding: .day, value: max(span, 0), to: newStart) ?? newStart
                            }
                        Text("시작일은 오늘부터 \(ReservationPolicy.maxStartLeadMonths)개월 이내로 정할 수 있어요.")
                            .font(.system(size: 12)).foregroundStyle(TL.faint)
                    }
                    Toggle(isOn: $noEndDate) {
                        Text("종료일 없음").font(.tlBody).foregroundStyle(TL.paper)
                    }
                    .tint(TL.rec)
                    .disabled(editingDisabled)
                    // 종료일을 켜는 순간의 보정. 하한은 '시작일'이 아니라 '시작일과 오늘 중 늦은 쪽'이다 —
                    // 무기한 예약은 종료일 값이 시작일(과거)로 채워져 있어, 시작일에만 맞추면
                    // 이미 지난 날짜가 그대로 남아 아무것도 안 골랐는데 "종료일이 이미 지났어요"로 막힌다.
                    .onChange(of: noEndDate) { _, hasNoEnd in
                        guard !hasNoEnd else { return }
                        let cal = Calendar.current
                        var floor = max(oneOffDate, cal.startOfDay(for: Date()))
                        // 요일 반복 중이면 종료일을 시작일에 붙이면 안 된다. 붙는 순간
                        // 시작일=종료일이 되어 요일 반복 UI가 사라지고, 저장 시 고른 요일이
                        // 전체 요일로 덮여 월·수·금 반복이 조용히 하루짜리가 된다.
                        // (무기한 예약은 종료일 값이 시작일과 같아서 늘 이 상태였다)
                        if isRepeating, cal.isDate(floor, inSameDayAs: oneOffDate),
                           let week = cal.date(byAdding: .day, value: 6, to: floor) {
                            floor = week
                        }
                        if oneOffEndDate < floor { oneOffEndDate = floor }
                    }
                    if !noEndDate {
                        // 종료일 하한 = 시작일과 오늘 중 늦은 쪽 (이미 지난 종료일은 고를 수 없게)
                        DatePicker("종료일", selection: $oneOffEndDate,
                                   in: max(oneOffDate, Calendar.current.startOfDay(for: Date()))...,
                                   displayedComponents: .date)
                            .font(.tlBody).foregroundStyle(TL.paper)
                            .disabled(editingDisabled)
                    }

                    if isSingleDay {
                        Divider().overlay(TL.hairline)
                        Text("하루짜리 활동이라 요일 반복 설정이 필요 없어요.")
                            .font(.system(size: 12)).foregroundStyle(TL.faint)
                    } else {
                        Divider().overlay(TL.hairline)
                        // 토글을 켜는 건 '매일은 아니다'라는 선언이다 — 그래서 켤 때마다
                        // 요일을 전부 비운 상태에서 다시 고르게 한다. (프로그래매틱 변경인
                        // load()에는 반응하지 않도록 .onChange가 아니라 바인딩에서 처리)
                        Toggle(isOn: Binding(
                            get: { isRepeating },
                            set: { on in
                                isRepeating = on
                                if on { weekdays = [] }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Text("요일 반복").font(.tlBody).foregroundStyle(TL.paper)
                                // 꺼짐 = 매일 — 토글 의미를 바로 알 수 있게 옆에 힌트 표시
                                if !isRepeating {
                                    Text("(매일)").font(.system(size: 13, weight: .semibold)).foregroundStyle(TL.muted)
                                }
                            }
                        }
                        .tint(TL.rec)
                        .disabled(editingDisabled)

                        // 요일 반복 ON = 고른 요일만, OFF = 매일.
                        if isRepeating {
                            HStack(spacing: 8) {
                                ForEach(weekdaySymbols, id: \.0) { (value, label) in
                                    Button {
                                        if weekdays.contains(value) {
                                            weekdays.remove(value)
                                        } else {
                                            weekdays.insert(value)
                                            // 7개 전부 = '매일'과 같은 뜻이다. 같은 의미를 두 가지
                                            // 상태로 표현하지 않도록, 마지막 요일을 채우는 순간
                                            // 토글을 끄고 '매일'로 넘긴다 — 켜진 동안은 최대 6개.
                                            if weekdays.count == weekdaySymbols.count { isRepeating = false }
                                        }
                                    } label: {
                                        Text(label)
                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                            .foregroundStyle(weekdays.contains(value) ? TL.ink : TL.muted)
                                            .frame(width: 36, height: 36)
                                            .background(Circle().fill(weekdays.contains(value) ? TL.paper : TL.surface))
                                            .overlay(Circle().strokeBorder(weekdays.contains(value) ? .clear : TL.hairline))
                                    }
                                    .disabled(editingDisabled)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 로직

    private func load() {
        guard let r = reservation else {
            // 강도는 활동마다 따로 정한다(전역 강도 정책 폐지). 신규는 매운맛에서 시작하고
            // 사용자가 직접 고른다.
            intensity = .spicy
            return
        }
        name = r.name
        // 저장된 태그가 프리셋이면 그 칩을 선택 상태로, 직접 입력 태그면 입력칸에 싣는다.
        // 직접 입력이었을 때 tag를 그 문자열로 두면, 사용자가 입력칸을 비우는 순간
        // 선택된 칩이 하나도 없는데 지워진 문자열이 그대로 저장된다 — 프리셋 기본값을 깔아둔다.
        let isPreset = ActivityTag.presets.contains(r.tag)
        tag = isPreset ? r.tag : ActivityTag.presets[0]
        if !isPreset { customTag = r.tag }
        durationMinutes = r.durationMinutes
        // 저장된 값을 그대로 보여준다. 예전에는 미친맛 미해제 상태에서 열면 화면을 매운맛으로
        // 내려놓고, 이름만 고쳐 저장해도 그 매운맛이 기록돼 원래 설정이 지워졌다.
        // (미친맛 버튼은 미해제면 어차피 눌리지 않으므로 새로 고를 수는 없다)
        intensity = r.intensityOverride ?? .spicy
        let base = Calendar.current.startOfDay(for: .now)
        startTime = Calendar.current.date(byAdding: .minute, value: r.startMinute, to: base) ?? .now
        // oneOffDate 마커가 있으면 '매일(기간/단발성)' 모드, 없으면 '요일 반복' 모드.
        // 기간(시작일·종료일)은 두 모드 공통이므로 항상 복원한다.
        let hasDate = r.oneOffDate != nil
        isRepeating = !hasDate                       // 마커 없음 = 요일 반복 토글 ON
        weekdays = Set(r.repeatWeekdays)
        // 시작일: 매일 모드는 마커, 요일 반복 모드는 시작 게이트(createdAt)
        oneOffDate = r.oneOffDate ?? Calendar.current.startOfDay(for: r.createdAt)
        if hasDate, !r.isRepeating {
            // 레거시 단발성 → 시작일=종료일 하루로 표시
            noEndDate = false
            oneOffEndDate = r.oneOffDate ?? .now
        } else {
            noEndDate = (r.endDate == nil)
            oneOffEndDate = r.endDate ?? oneOffDate
        }
    }

    private func save() {
        errorMessage = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        // 검증: 슬롯 초과 읽기 전용 — 강등·연속 하락으로 한도를 넘으면 편집 저장 차단(삭제만 허용).
        // (버튼도 비활성이지만 백스톱으로 이중 방어)
        if isEditReadOnly {
            errorMessage = isLockedInsane
                ? "미친 매운맛 활동은 지금 편집할 수 없어요. 조회와 삭제만 가능합니다."
                : "슬롯 한도를 초과해 편집이 잠겼습니다. 예약을 삭제해 슬롯 수 이내로 정리하면 다시 편집할 수 있어요."
            return
        }

        // 검증: 활동 슬롯 정책 (신규 생성만) — 연속 달성일 사다리. 기존 예약은 영향 없음.
        if reservation == nil, let allowed = allowedSlots, slotUsingReservations.count >= allowed {
            var message = "활동 슬롯이 가득 찼습니다 (현재 연속 \(currentStreak)일 → 최대 \(allowed)개)."
            if let next = SlotPolicy.nextTier(afterStreak: currentStreak) {
                message += " 연속 \(next.days)일을 달성하면 \(next.slots.map { "\($0)개" } ?? "무제한")까지 열려요."
            }
            message += " 이미 만든 활동은 그대로 유지됩니다."
            errorMessage = message
            return
        }

        // 검증: 활동명 필수
        guard !trimmedName.isEmpty else {
            errorMessage = "활동명을 입력하세요."
            return
        }
        // 검증: 주간 반복이면 요일 최소 1개 (하루짜리 활동은 요일 반복 UI가 없으므로 제외)
        if !isSingleDay && isRepeating && weekdays.isEmpty {
            errorMessage = "반복할 요일을 선택하세요."
            return
        }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        let startMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        // 기간(시작일·종료일)은 요일 반복·매일 공통. 요일 반복 OFF면 매일(요일 전체).
        // 하루짜리(시작일=종료일)는 요일 반복이 무의미하므로 항상 전체 요일로 저장.
        let cal = Calendar.current
        // 잠긴 예약(이미 시작함)은 UI가 시작일을 못 바꾸게 하지만, 저장 경로에서도 한 번 더
        // 기존 createdAt을 강제한다 — 어떤 경로로든 시작 게이트가 움직이면 노쇼 복구 루틴이
        // 과거의 정당한 벌점을 지워버린다.
        let startDay = reservation.flatMap { lockedStartDay(of: $0) } ?? cal.startOfDay(for: oneOffDate)
        let resolvedWeekdays: [Int] = (isRepeating && !isSingleDay) ? Array(weekdays) : [1, 2, 3, 4, 5, 6, 7]
        let resolvedOneOff: Date? = (isRepeating && !isSingleDay) ? nil : startDay   // 매일·하루 모드는 시작일 마커
        let resolvedEnd: Date? = (!noEndDate)
            ? cal.startOfDay(for: oneOffEndDate).addingTimeInterval(86_400 - 0.001)
            : nil

        // 검증: 시작일 상한 (신규 생성만). 기존 예약은 상한 도입 전에 만들어진 먼 시작일을
        // 가질 수 있는데, 이름만 고치는 정상 편집까지 막으면 손댈 방법이 없어진다.
        if reservation == nil, startDay > ReservationPolicy.maxStartDay(calendar: cal) {
            errorMessage = "시작일은 오늘부터 \(ReservationPolicy.maxStartLeadMonths)개월 이내로 정해주세요."
            return
        }

        // 검증: 종료일 지정 시 — 종료일 ≥ 시작일 · 아직 안 지남 (두 모드 공통)
        if !noEndDate {
            let endDay = cal.startOfDay(for: oneOffEndDate)
            guard endDay >= startDay else { errorMessage = "종료일은 시작일 이후여야 해요."; return }
            guard endDay >= cal.startOfDay(for: .now) else { errorMessage = "종료일이 이미 지났어요."; return }
        }
        let targetWeekdays = Set(resolvedWeekdays)

        // 검증 A: 이 설정이 애초에 성립하는가 — 기간 '전체'에 고른 요일이 한 번이라도 오는가.
        // (예: 7/27 월 ~ 7/29 수 기간에 금·토를 고르면 평생 울리지 않는다)
        // 기준을 '남은 발생'이 아니라 '기간 전체'로 잡아야, 마지막 날을 앞둔 예약의
        // 이름만 고치는 정상 편집이 막히지 않는다. 요일은 7개뿐이라 8일이면 판정된다.
        var anyOccurrence = false
        for offset in 0...8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: startDay) else { break }
            if let end = resolvedEnd, day > end { break }
            if targetWeekdays.contains(cal.component(.weekday, from: day)) { anyOccurrence = true; break }
        }
        if !anyOccurrence {
            errorMessage = "선택한 기간 안에 고른 요일이 없어요. 요일이나 기간을 조정해주세요."
            return
        }

        // 검증 B: 신규 생성은 앞으로 울릴 발생이 남아 있어야 한다.
        // (예: 밤 8시에 '오늘 아침 8시 하루'를 만들면 태어날 때부터 죽은 예약)
        // 기존 예약 편집에는 적용하지 않는다 — 마지막 날을 지나가는 중인 예약도
        // 이름 수정·조기 종료 같은 정상 편집이 가능해야 한다.
        if reservation == nil {
            var futureOccurrence = false
            let scanStart = max(startDay, cal.startOfDay(for: .now))
            for offset in 0...8 {
                guard let day = cal.date(byAdding: .day, value: offset, to: scanStart) else { break }
                if let end = resolvedEnd, day > end { break }
                guard targetWeekdays.contains(cal.component(.weekday, from: day)),
                      let fire = cal.date(byAdding: .minute, value: startMinute, to: day) else { continue }
                if fire > .now { futureOccurrence = true; break }
            }
            if !futureOccurrence {
                errorMessage = "이미 지난 시각이에요. 시작 시각이나 날짜를 조정해주세요."
                return
            }
        }

        // 검증: 실제로 부딪히는 예약만 차단 — 기간이 겹치고, 그 안에서 같은 요일·시간대일 때.
        // 기간을 안 보면 이미 끝난 활동이 새 활동을 영영 막고, 날짜가 다른 하루짜리끼리도
        // (둘 다 요일 전체로 저장되므로) 충돌로 잡힌다.
        let myRange: (lo: Date, hi: Date?) = (startDay, resolvedEnd.map { cal.startOfDay(for: $0) })
        for other in allReservations where other.id != reservation?.id {
            if ScheduleConflict.conflicts(
                aRange: myRange, aWeekdays: targetWeekdays,
                aStart: startMinute, aDuration: durationMinutes,
                bRange: other.activeDayRange(calendar: cal), bWeekdays: other.occupiedWeekdays(calendar: cal),
                bStart: other.startMinute, bDuration: other.durationMinutes) {
                errorMessage = "\(TLFormat.clock(clockDate(other.startMinute))) '\(other.name)' 예약과 시간이 겹칩니다."
                return
            }
        }

        let trimmedCustomTag = customTag.trimmingCharacters(in: .whitespaces)
        let finalTag = trimmedCustomTag.isEmpty ? tag : trimmedCustomTag
        if let r = reservation {
            // 일정에 실질 변화가 있는 편집인가 — 이름·태그·강도만 고친 저장으로
            // accountableFrom이 갱신되면 그 자체가 노쇼 면책 수단이 된다.
            let scheduleChanged = r.startMinute != startMinute
                || r.durationMinutes != durationMinutes
                || r.repeatWeekdays != resolvedWeekdays
                || r.oneOffDate != resolvedOneOff
                || r.endDate != resolvedEnd
                || r.createdAt != startDay
            r.name = trimmedName
            r.tag = finalTag
            r.startMinute = startMinute
            r.durationMinutes = durationMinutes
            r.repeatWeekdays = resolvedWeekdays
            r.oneOffDate = resolvedOneOff
            r.endDate = resolvedEnd
            r.intensityOverrideRaw = intensity.rawValue   // 활동별 강도

            // 시작일 = 발생 시작 게이트(createdAt). 잠긴(이미 시작한) 예약은 startDay가
            // 기존 값과 같으므로 실질적으로 불변이다.
            r.createdAt = startDay
            // 책임 기준은 '지금'과 '시작일' 중 늦은 쪽 — 편집으로 시각을 앞당겨도 소급 노쇼가
            // 나지 않고, 시작일이 미래면 그 전까지는 책임이 없다.
            // 단, 시각·요일·기간이 실제로 바뀐 편집에만 — 이름만 고친 저장은 책임 기준을
            // 건드리지 않는다(잠금 창과 함께 노쇼 면책 회피의 이중 방어).
            if scheduleChanged {
                r.accountableFrom = max(.now, startDay)
            }
            r.updatedAt = .now
            AccountStore.shared.mirrorReservation(r)   // 크로스 기기 동기화
        } else {
            let r = Reservation(name: trimmedName, tag: finalTag,
                                startMinute: startMinute, durationMinutes: durationMinutes,
                                repeatWeekdays: resolvedWeekdays,
                                oneOffDate: resolvedOneOff,
                                ownerUserID: account.currentUserID)
            r.endDate = resolvedEnd
            r.intensityOverrideRaw = intensity.rawValue   // 활동별 강도
            // 신규: 시작일 = 발생 시작 게이트(createdAt).
            r.createdAt = startDay
            // 책임 기준을 시작일 '자정'으로 두면, 오늘 만든 예약이 오늘 아침 발생분까지
            // 소급 노쇼로 잡힌다(토 16시에 만든 매일 06:00 예약이 -15점을 받던 결함).
            // '지금'과 '시작일' 중 늦은 쪽으로 둬서 생성 이전 발생분은 책임에서 제외한다.
            r.accountableFrom = max(.now, startDay)
            r.updatedAt = .now
            context.insert(r)
            AccountStore.shared.mirrorReservation(r)   // 크로스 기기 동기화
        }
        try? context.save()
        rescheduleAlarms()
        dismiss()
    }

    private func delete() {
        guard let r = reservation, !isLocked else { return }

        // 오늘 발생이 이미 '진행된' 예약은 통째로 지우지 않고 오늘로 은퇴시킨다.
        // 진행됨 = 오늘 기록이 확정됐거나(완주·실패·긴급 등) 시작 창이 이미 닫힘(노쇼 확정 예정).
        // 통째로 지우면 기록탭에는 오늘 벌점이 박혀 있는데 일정 탭 오늘 칸은 텅 비어
        // "오늘 아무것도 안 했는데 왜 실패지?"가 된다. endDate = 오늘로 두면 내일부터
        // 발생이 없고(시작 안 한 미래분은 전부 소멸), 오늘 행은 자정까지 남으며,
        // 만료 예약 정리가 날이 바뀌면 알아서 치운다. 슬롯은 hasRemainingOccurrence가
        // 남은 발생 없음으로 판정해 즉시 반납된다. 은퇴는 isActive를 유지하므로
        // 노쇼 스위퍼가 미기록 노쇼를 계속 집계할 수 있다(삭제로 벌점을 피하는 구멍 차단).
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let progressedToday: Bool = {
            guard let fire = r.occurrence(on: today) else { return false }
            if fire.addingTimeInterval(TimePolicy.startWindowSeconds) < .now { return true }
            // 술어는 검증된 형태만 — 옵셔널 값 비교 술어는 실기기에서만 조용히 실패한
            // 전례가 있다(WeeklyScheduleView 참고). 나머지 조건은 메모리에서 거른다.
            let descriptor = FetchDescriptor<FocusSession>(
                predicate: #Predicate { $0.scheduledAt != nil })
            let sessions = (try? context.fetch(descriptor)) ?? []
            return sessions.contains { s in
                guard s.reservationID == r.id, s.outcome != nil,
                      let scheduled = s.scheduledAt else { return false }
                return cal.isDate(scheduled, inSameDayAs: today)
            }
        }()

        if progressedToday {
            r.endDate = today
        } else {
            r.isActive = false      // 시작 전 — 흔적 없이 소멸
        }
        r.updatedAt = .now
        AccountStore.shared.mirrorReservation(r)   // 삭제·은퇴 모두 다른 기기에 전파
        try? context.save()
        rescheduleAlarms()
        dismiss()
    }

    private func rescheduleAlarms() {
        app.rescheduleAlarmsForCurrentUser()
    }

    private func clockDate(_ minute: Int) -> Date {
        Calendar.current.date(byAdding: .minute, value: minute,
                              to: Calendar.current.startOfDay(for: .now)) ?? .now
    }
}

// MARK: - 활동 슬롯 현황 배지 (활동 예약·그룹 생성·그룹 참여 공용)

/// 최상단에 슬롯 현황을 보여주는 배지 — 터치하면 정책 표. 그룹 예약도 슬롯 1개를 차지하므로
/// 방을 만들거나 참여할 때도 동일하게 노출해, 슬롯이 왜 줄어드는지 바로 알 수 있게 한다.
struct SlotStatusBadge: View {
    let used: Int
    let allowed: Int?     // nil = 무제한
    let streak: Int
    var onTap: () -> Void

    var body: some View {
        let full = allowed.map { used >= $0 } ?? false
        let label = allowed.map { "\(used)/\($0)" } ?? "\(used)/무제한"
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: full ? "lock.fill" : "flame.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(full ? TL.amber : TL.jade)
                VStack(alignment: .leading, spacing: 2) {
                    Text("활동 슬롯 \(label) · 연속 달성 \(streak)일")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(TL.paper)
                    Text("그룹도 슬롯 1개를 사용해요 · 터치하면 정책")
                        .font(.system(size: 11)).foregroundStyle(TL.faint)
                }
                Spacer()
                Image(systemName: "info.circle").font(.system(size: 15)).foregroundStyle(TL.muted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                .fill((full ? TL.amber : TL.jade).opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 활동 슬롯 정책 팝업 (단계표)

struct SlotPolicySheet: View {
    let currentStreak: Int
    let usedSlots: Int
    let isMember: Bool
    @Environment(\.dismiss) private var dismiss

    /// 표 행: (라벨, 연속일 하한, 슬롯 표기).
    /// 멤버십 계정은 연속과 무관하게 기본 10개가 보장되므로 사다리를 접고 '기본 10개 / 연속 30일 무제한' 2줄만 보여준다.
    private var rows: [(label: String, minDays: Int, slots: String)] {
        if isMember {
            return [
                ("기본",       0,  "\(SlotPolicy.memberFloorSlots)개"),
                ("연속 30일", 30,  "무제한")
            ]
        }
        return [
            ("기본",       0,  "2개"),
            ("연속 3일",   3,  "3개"),
            ("연속 5일",   5,  "4개"),
            ("연속 7일",   7,  "5개"),
            ("연속 10일", 10,  "10개"),
            ("연속 30일", 30,  "무제한")
        ]
    }

    /// 현재 연속일이 속한 행 인덱스
    private var currentRow: Int {
        var index = 0
        for (i, row) in rows.enumerated() where currentStreak >= row.minDays { index = i }
        return index
    }

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("하나에 집중하는 습관을 위해, 활동 슬롯은 연속 달성일로 늘어납니다.")
                    .font(.system(size: 14)).foregroundStyle(TL.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 단계표
                VStack(spacing: 0) {
                    HStack {
                        Text("연속 달성일").font(.tlLabel).foregroundStyle(TL.faint)
                        Spacer()
                        Text("최대 활동").font(.tlLabel).foregroundStyle(TL.faint)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)

                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        let isCurrent = index == currentRow
                        HStack {
                            Text(row.label)
                                .font(.system(size: 15, weight: isCurrent ? .bold : .medium, design: .rounded))
                                .foregroundStyle(isCurrent ? TL.jade : TL.paper)
                            if isCurrent {
                                Text("현재")
                                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                                    .foregroundStyle(TL.ink)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(TL.jade))
                            }
                            Spacer()
                            Text(row.slots)
                                .font(.tlTimer(15))
                                .foregroundStyle(isCurrent ? TL.jade : TL.paper)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(isCurrent ? TL.jade.opacity(0.10) : .clear)
                        if index < rows.count - 1 {
                            Divider().overlay(TL.hairline.opacity(0.5))
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous).fill(TL.surface))
                .clipShape(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))

                Label(isMember
                      ? "멤버십 적용 중 — 연속일과 무관하게 최소 \(SlotPolicy.memberFloorSlots)개가 보장됩니다."
                      : "멤버십에 가입하면 연속일과 무관하게 최소 \(SlotPolicy.memberFloorSlots)개부터 시작합니다.",
                      systemImage: "crown.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(TL.jade)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Label("연속이 끊기면 한도가 내려가지만, 이미 만든 활동은 사라지지 않아요. 새로 추가하는 것만 제한됩니다.", systemImage: "shield.checkerboard")
                    .font(.system(size: 12)).foregroundStyle(TL.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

            }
            .padding(20)
            }
            .background(TL.ink)
            .navigationTitle("활동 슬롯 정책 · 연속 \(currentStreak)일")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }.foregroundStyle(TL.muted)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
