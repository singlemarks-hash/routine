//
//  GroupViews.swift
//  TimeLock
//
//  그룹 챌린지 탭 — 초대코드로 모인 사람들이 같은 일정으로 대결한다.
//  방 목록 → 방 만들기(방장·초대코드) / 참여하기(코드+닉네임) → 랭킹 → 최종 결과.
//  게스트에게는 이 탭 자체가 보이지 않는다 (HomeShellView가 숨김).
//

import SwiftUI
import SwiftData

// MARK: - 그룹 탭 (방 목록)

struct GroupTabView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var subscription: SubscriptionManager
    @StateObject private var store = GroupStore.shared
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showPaywall = false

    /// 그룹 챌린지는 멤버십 전용. 단, 구독 중 참여한 방이 남아 있으면
    /// (구독이 끝나도 노쇼 벌점은 계속 쌓이므로) 기존 방 열람·관리는 막지 않는다.
    private var locked: Bool { !subscription.isPro }

    @Query private var everyReservation: [Reservation]

    /// 내 그룹 활동 — 방 목록이 비어 있어도 이게 남아 있으면 정리할 게 있다는 뜻이다.
    private var myGroupReservations: [Reservation] {
        everyReservation.filter {
            $0.isActive && $0.isGroupReservation && $0.ownerUserID == account.currentUserID
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                        .padding(.top, 6)

                    // 탭은 누구에게나 열어둔다. 참여 중인 방은 구독이 끊겨도 계속 굴러가고
                    // (노쇼 벌점도 계속 쌓인다) 나가려면 그 방에 들어갈 수 있어야 한다.
                    // 결제는 '새로 시작하는 행동'에서만 요구한다.
                    notices

                    loadFailureNotice

                    if locked { membershipPromo }

                    Button("그룹방 만들기") {
                        if locked { showPaywall = true } else { showCreate = true }
                    }
                    .buttonStyle(TLPrimaryButtonStyle())

                    Button("초대코드로 참여하기") {
                        if locked { showPaywall = true } else { showJoin = true }
                    }
                    .buttonStyle(TLGhostButtonStyle())

                    roomList
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 116)   // 하단 토글 자리
            }
            .background(TL.ink)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.refresh() }
            .task { await store.refresh() }
            .sheet(isPresented: $showCreate) { GroupCreateView() }
            .sheet(isPresented: $showJoin) { GroupJoinView() }
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }

    // MARK: 방 목록을 못 불러왔을 때

    /// 참여 중인 활동은 있는데 방 목록이 비어 있다 = 조회가 실패한 것이다.
    /// (성공했다면 pruneOrphanGroupReservations가 사라진 방의 활동까지 정리해 둔다)
    /// 이때 빈 화면만 보여주면 탈퇴할 방을 찾지 못해 슬롯을 비울 방법이 없어진다.
    @ViewBuilder
    private var loadFailureNotice: some View {
        if store.rooms.isEmpty && !myGroupReservations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("방 정보를 불러오지 못했습니다")
                    .font(.tlTitle(15)).foregroundStyle(TL.paper)
                Text("참여 중인 그룹 활동이 있는데 방 목록을 읽지 못했어요. 네트워크를 확인하고 다시 시도해 주세요.")
                    .font(.system(size: 13)).foregroundStyle(TL.muted)
                Button("다시 시도") { Task { await store.refresh() } }
                    .buttonStyle(TLGhostButtonStyle())
            }
            .padding(14)
            .background(TL.raised, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(TL.hairline, lineWidth: 1))
        }
    }

    // MARK: 비구독자 안내 — 잠금이 아니라 안내다

    /// 탭을 막지 않는 대신, 왜 만들기·참여하기가 결제로 이어지는지 여기서 알린다.
    private var membershipPromo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13)).foregroundStyle(TL.amber)
                Text("새 그룹은 멤버십 전용이에요")
                    .font(.tlTitle(15)).foregroundStyle(TL.paper)
            }
            Text("참여 중인 방은 그대로 보고 관리할 수 있어요. 방을 새로 만들거나 초대코드로 참여하려면 멤버십이 필요합니다.")
                .font(.system(size: 13)).foregroundStyle(TL.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(TL.raised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(TL.hairline, lineWidth: 1))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TLEyebrow(text: "GROUP CHALLENGE", color: TL.rec)
            Text("같이 하면 못 도망간다")
                .font(.tlTitle(24))
                .foregroundStyle(TL.paper)
            Text("초대코드로 모여 같은 일정으로 대결해요.\n그룹 점수는 0점부터, 개인 누적에도 그대로 쌓입니다.")
                .font(.system(size: 13))
                .foregroundStyle(TL.muted)
                .lineSpacing(3)
        }
    }

    /// 방장이 확인해야 하는 자동 삭제 안내 + 참여자의 해체 안내
    @ViewBuilder
    private var notices: some View {
        ForEach(Array(store.cancelledNotices.enumerated()), id: \.offset) { index, message in
            noticeCard(message) { store.cancelledNotices.remove(at: index) }
        }
        ForEach(Array(store.disbandedNotices.enumerated()), id: \.offset) { index, message in
            noticeCard(message) { store.disbandedNotices.remove(at: index) }
        }
    }

    private func noticeCard(_ message: String, dismiss: @escaping () -> Void) -> some View {
        TLCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(TL.amber)
                Text(message)
                    .font(.system(size: 13)).foregroundStyle(TL.paper)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(TL.muted)
                }
            }
        }
    }

    @ViewBuilder
    private var roomList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("내 그룹")
                .font(.tlTitle(20))
                .foregroundStyle(TL.paper)

            if store.rooms.isEmpty {
                TLCard {
                    Text("참여 중인 그룹이 없습니다. 방을 만들어 초대코드를 공유하거나, 받은 코드로 참여해 보세요.")
                        .font(.system(size: 13)).foregroundStyle(TL.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(store.rooms) { room in
                    NavigationLink {
                        GroupRoomDetailView(room: room)
                    } label: {
                        roomCard(room)
                    }
                    .pressableStyle()
                }
            }
        }
    }

    private func roomCard(_ room: GroupRoom) -> some View {
        TLCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(room.name)
                        .font(.tlTitle(17))
                        .foregroundStyle(TL.paper)
                        .lineLimit(1)
                    if room.isHostMine {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(TL.amber)
                    }
                    Spacer()
                    statusChip(room)
                }
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill").font(.system(size: 11))
                    Text("\(room.memberCount)명")
                    Text("·")
                    Text(GroupFormat.scheduleLine(room))
                        .lineLimit(1)
                }
                .font(.system(size: 13))
                .foregroundStyle(TL.muted)
            }
        }
    }

    private func statusChip(_ room: GroupRoom) -> some View {
        let (label, color): (String, Color) =
            room.doomed ? ("삭제 예정", TL.rec)
            : room.isFinished ? ("종료", TL.faint)
            // 시작 시각은 지났지만 아직 시작/취소 판정이 안 끝난 방은 '진행 중'이 아니다.
            : room.status == "scheduled" && room.hasStarted ? ("확인 중", TL.amber)
            : room.hasStarted ? ("진행 중", TL.jade)
            : ("\(GroupFormat.dDay(room.startDate)) 시작", TL.amber)
        return Text(label)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - 방 만들기 (방장)

/// 검증 실패 시 살짝 좌우로 떨리는 효과 (반복 요일 미선택 안내 등)
struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: 7 * sin(animatableData * .pi * 4), y: 0))
    }
}

struct GroupCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = GroupStore.shared
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var subscription: SubscriptionManager
    @Query(filter: #Predicate<Reservation> { $0.isActive }) private var allActiveReservations: [Reservation]
    @Query private var allSessions: [FocusSession]
    @State private var showSlotPolicy = false

    // 그룹 예약도 슬롯 1개를 차지 — 방 만들기 최상단에 현황 노출 (활동 예약과 동일)
    private var slotUsed: Int { allActiveReservations.filter { $0.ownerUserID == account.currentUserID }.count }
    private var slotStreak: Int { SlotPolicy.currentStreak(sessions: allSessions.filter { $0.ownerUserID == account.currentUserID }) }
    private var slotAllowed: Int? { SlotPolicy.allowedSlots(forStreak: slotStreak, isMember: subscription.isPro) }

    @State private var name = ""
    @State private var nickname = ""
    @State private var intensity: Intensity = .spicy
    @State private var startTime = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: .now)!
    @State private var minutes = 30
    @State private var isRepeating = false          // ON=고른 요일만, OFF=매일(기간). 개인 활동과 동일한 모델.
    @State private var weekdays: Set<Int> = []
    @State private var startDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
    @State private var endDay = Calendar.current.date(byAdding: .day, value: 28, to: Calendar.current.startOfDay(for: .now))!
    @State private var working = false
    @State private var errorMessage: String?
    @State private var createdRoom: GroupRoom?
    @State private var weekdayError = false     // 요일 반복인데 요일 미선택
    @State private var shakeCount = 0           // 흔들림 트리거

    private var tomorrow: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
    }
    private var maxEndDay: Date {
        // 포함 일수 기준(안드로이드 통일): startDay 당일 포함 최대 maxDurationDays일 → +(N-1)
        Calendar.current.date(byAdding: .day, value: GroupPolicy.maxDurationDays - 1, to: startDay)!
    }
    /// 시작일=종료일이면 그날 하루뿐이라 요일 반복 설정 자체가 무의미하다.
    private var isSingleDayRoom: Bool {
        Calendar.current.isDate(startDay, inSameDayAs: endDay)
    }
    // 요일 미선택이어도 버튼은 활성 — 눌렀을 때 안내(빨간 박스 + 흔들림)를 보여주기 위함.
    private var formReady: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !nickname.trimmingCharacters(in: .whitespaces).isEmpty
    }
    /// 미친 매운맛 해제 여부 — 매운맛 완주 3회(성실 경로) 또는 멤버십
    private var insaneUnlocked: Bool { AppState.shared.insaneUnlocked }

    var body: some View {
        NavigationStack {
            Group {
                if let room = createdRoom {
                    createdPanel(room)
                } else {
                    form
                }
            }
            .background(TL.ink)
            .navigationTitle(createdRoom == nil ? "그룹방 만들기" : "방 완성")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(createdRoom == nil ? "닫기" : "완료") { dismiss() }
                        .foregroundStyle(TL.muted)
                }
            }
            .sheet(isPresented: $showSlotPolicy) {
                SlotPolicySheet(currentStreak: slotStreak, usedSlots: slotUsed, isMember: subscription.isPro)
                    .presentationDetents([.medium, .large])
            }
        }
        .preferredColorScheme(.dark)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SlotStatusBadge(used: slotUsed, allowed: slotAllowed, streak: slotStreak) {
                    showSlotPolicy = true
                }
                field("방 이름 (참여자 전원의 활동명이 됩니다)") {
                    // 길이 제한 없음 — 방 이름으로 챌린지 규칙을 설명하는 경우가 있어
                    // (예: "매일 아침 6시, 늦으면 벌금") 개인 활동명 한도를 적용하지 않는다.
                    TextField("예: 영어공부 매일 30분 도전!", text: $name)
                        .groupFieldStyle()
                }
                field("내 닉네임 (이 방에서만 사용 · 최대 \(GroupPolicy.nicknameMaxLength)자)") {
                    TextField("예: 열공대장", text: $nickname)
                        .groupFieldStyle()
                        .onChange(of: nickname) { _, new in
                            if new.count > GroupPolicy.nicknameMaxLength {
                                nickname = String(new.prefix(GroupPolicy.nicknameMaxLength))
                            }
                        }
                }

                field("강도 — 참여자 전원에게 동일 적용") {
                    HStack(spacing: 8) {
                        ForEach(Intensity.allCases) { candidate in
                            let locked = candidate == .insane && !insaneUnlocked
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
                                .background(
                                    RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                                        .fill(intensity == candidate ? TL.paper : TL.surface)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                                        .strokeBorder(TL.hairline.opacity(locked ? 0.5 : 0), lineWidth: 1)
                                )
                                .opacity(locked ? 0.45 : 1)
                                .saturation(locked ? 0 : 1)
                            }
                            .disabled(locked)
                        }
                    }
                }

                // 시작 시각 + 길이 — 컴팩트 pill(탭하면 팝업) + 길이 메뉴 + 완주 상점. 활동 예약과 동일 형태.
                field("몇시에 얼마나 진행하나요?") {
                    TLCard {
                        VStack(spacing: 4) {
                            DatePicker("시작 시각", selection: $startTime, displayedComponents: .hourAndMinute)
                                .font(.system(size: 15)).foregroundStyle(TL.paper)
                            Divider().overlay(TL.hairline)
                            HStack(spacing: 10) {
                                Picker("활동 길이", selection: $minutes) {
                                    ForEach(TimePolicy.durationOptionsMinutes, id: \.self) {
                                        Text(TLFormat.durationLabel($0)).tag($0)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(TL.paper)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text("완료 시 +\(ScoreRules.completionBase(forMinutes: minutes))점")
                                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                                    .foregroundStyle(TL.jade)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(TL.jade.opacity(0.14)))
                            }
                        }
                    }
                }

                // 기간 — 시작일·종료일 먼저 정하고, 그 기간에 요일 반복을 적용할지 고른다.
                field("기간 — 시작은 1시간 뒤부터, 최대 3개월") {
                    VStack(spacing: 0) {
                        // 상한 3개월 — 개인 활동과 같은 규칙. 그보다 먼 알람은 보장할 수 없다.
                        DatePicker("시작일", selection: $startDay,
                                   in: Calendar.current.startOfDay(for: .now)...ReservationPolicy.maxStartDay(),
                                   displayedComponents: .date)
                        Divider().overlay(TL.hairline)
                            .padding(.vertical, 6)
                        DatePicker("종료일", selection: $endDay, in: startDay...maxEndDay, displayedComponents: .date)
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(TL.paper)
                    .colorScheme(.dark)
                    .padding(14)
                    .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))
                    .onChange(of: startDay) {
                        if endDay < startDay { endDay = startDay }
                        if endDay > maxEndDay { endDay = maxEndDay }
                    }
                }

                // 요일 반복(ON=고른 요일, OFF=매일). 시작일=종료일(하루)이면 요일 반복이
                // 무의미하므로(그 요일이 빠지면 발생이 0번이 되는 모순도 방지) UI 자체를 숨긴다.
                if isSingleDayRoom {
                    Text("하루짜리 그룹이라 요일 반복 설정이 필요 없어요.")
                        .font(.system(size: 12)).foregroundStyle(TL.faint)
                } else {
                    field("반복") {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle(isOn: $isRepeating) {
                                HStack(spacing: 6) {
                                    Text("요일 반복").font(.tlBody).foregroundStyle(TL.paper)
                                    // 꺼짐 = 매일 — 토글 의미를 바로 알 수 있게 옆에 힌트 표시
                                    if !isRepeating {
                                        Text("(매일)").font(.system(size: 13, weight: .semibold)).foregroundStyle(TL.muted)
                                    }
                                }
                            }
                            .tint(TL.rec)
                            // 켤 때 고른 요일이 없으면 평일 기본값 (개인 활동과 동일)
                            .onChange(of: isRepeating) { _, on in
                                if on && weekdays.isEmpty { weekdays = [2, 3, 4, 5, 6] }
                            }

                            if isRepeating {
                                // 개인 활동 요일 반복 UI와 통일 — 미선택 요일에도 헤어라인 테두리로 영역 표시
                                HStack(spacing: 8) {
                                    ForEach(1...7, id: \.self) { day in
                                        let selected = weekdays.contains(day)
                                        Button {
                                            if selected { weekdays.remove(day) } else { weekdays.insert(day) }
                                            if !weekdays.isEmpty { weekdayError = false }
                                        } label: {
                                            Text(GroupFormat.weekdayNames[day] ?? "")
                                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                                .foregroundStyle(selected ? TL.ink : TL.muted)
                                                .frame(width: 38, height: 38)
                                                .background(Circle().fill(selected ? TL.paper : TL.surface))
                                                .overlay(Circle().strokeBorder(selected ? .clear : TL.hairline))
                                        }
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))
                        // 요일 미선택 안내 시 얇은 빨간 테두리 + 살짝 흔들림
                        .overlay(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                            .strokeBorder(weekdayError ? TL.rec : .clear, lineWidth: 1.5))
                        .modifier(Shake(animatableData: CGFloat(shakeCount)))
                    }

                    if isRepeating && weekdayError {
                        Text("반복할 요일을 하나 이상 선택하세요.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TL.rec)
                    }
                }

                summaryCard

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TL.rec)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(working ? "만드는 중…" : "방 만들고 초대코드 받기") { create() }
                    .buttonStyle(TLPrimaryButtonStyle())
                    .disabled(working || !formReady)
                    .opacity(formReady ? 1 : 0.5)
            }
            .padding(20)
            .padding(.bottom, 24)
        }
    }

    private var summaryCard: some View {
        TLCard {
            VStack(alignment: .leading, spacing: 6) {
                TLEyebrow(text: "요약")
                Text(summaryText)
                    .font(.system(size: 13))
                    .foregroundStyle(TL.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summaryText: String {
        let time = GroupFormat.time(startMinute)
        let common = "\(time) 시작 · \(TLFormat.durationLabel(minutes)) · \(intensity.title)\n시작 \(GroupPolicy.joinCutoffMinutes)분 전까지만 참여할 수 있고, 시작 시각에 \(GroupPolicy.minMembersToStart)명 미만이면 방이 자동 삭제됩니다."
        // 시작일=종료일이면 요일 반복 여부와 무관하게 그날 하루만 진행하는 단발 그룹.
        if Calendar.current.isDate(startDay, inSameDayAs: endDay) {
            return "\(GroupFormat.day(startDay)) 하루 · \(common)"
        }
        let days = !isRepeating ? "매일"
            : weekdays.isEmpty ? "요일 미선택"
            : weekdays.count == 7 ? "매일"
            : "반복요일 " + weekdays.sorted().compactMap { GroupFormat.weekdayNames[$0] }.joined(separator: " ")
        return "\(GroupFormat.day(startDay)) ~ \(GroupFormat.day(endDay))\n\(days) · \(common)"
    }

    private var startMinute: Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private func create() {
        errorMessage = nil
        // 요일 반복인데 요일 미선택 → 빨간 박스 안내 + 흔들림 (하루짜리는 요일 반복 UI가 없으므로 제외)
        if !isSingleDayRoom && isRepeating && weekdays.isEmpty {
            withAnimation(.easeInOut(duration: 0.15)) { weekdayError = true }
            withAnimation(.linear(duration: 0.5)) { shakeCount += 1 }
            return
        }
        let calendar = Calendar.current
        // 요일 반복 OFF = 매일(요일 전체). 시작일=종료일(하루)이면 요일 반복이 무의미하므로 항상 전체 요일.
        let effectiveWeekdays = (isRepeating && !isSingleDayRoom) ? weekdays.sorted() : [1, 2, 3, 4, 5, 6, 7]
        let effectiveEndDay = endDay
        let startDate = calendar.date(byAdding: .minute, value: startMinute,
                                      to: calendar.startOfDay(for: startDay))!
        // endDate = 종료일의 끝(23:59:59.999) — 안드로이드와 통일. 마지막 날 세션 시각이 아니라 그날 전체를 포함해
        // 다른 시간대 참여자가 자기 로컬 마지막 세션을 마칠 여유를 준다.
        let endDate = calendar.startOfDay(for: effectiveEndDay).addingTimeInterval(86_400 - 0.001)
        // 종료일·기간 검증 (안드로이드와 동일 — 시작일 포함 일수 기준)
        guard effectiveEndDay >= startDay else { errorMessage = "종료일이 시작일보다 빠를 수 없어요."; return }
        guard calendar.startOfDay(for: startDay) <= ReservationPolicy.maxStartDay(calendar: calendar) else {
            errorMessage = "시작일은 오늘부터 \(ReservationPolicy.maxStartLeadMonths)개월 이내로 정해주세요."
            return
        }
        let inclusiveDays = (calendar.dateComponents([.day],
            from: calendar.startOfDay(for: startDay), to: calendar.startOfDay(for: effectiveEndDay)).day ?? 0) + 1
        guard inclusiveDays <= GroupPolicy.maxDurationDays else {
            errorMessage = "기간은 최대 \(GroupPolicy.maxDurationDays)일(3개월)까지 가능해요."
            return
        }
        // 시작은 지금부터 최소 1시간 뒤 (참여자가 10분 전 알람을 받을 수 있게 여유를 둔다)
        guard startDate >= Date().addingTimeInterval(Double(GroupPolicy.minStartLeadMinutes) * 60) else {
            errorMessage = "시작은 지금부터 최소 \(GroupPolicy.minStartLeadMinutes / 60)시간 이후로 설정해주세요."
            return
        }
        // 방장도 참여자와 같은 규칙 — 슬롯 1개 확보 + 기존 예약(다른 그룹 포함) 겹침 검사
        do {
            try store.checkSlotAvailable()
            try store.checkScheduleConflict(startMinute: startMinute, durationMinutes: minutes,
                                            repeatWeekdays: effectiveWeekdays,
                                            startDate: startDate, endDate: endDate)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        working = true
        Task {
            defer { working = false }
            do {
                createdRoom = try await store.createRoom(
                    name: name.trimmingCharacters(in: .whitespaces),
                    nickname: nickname.trimmingCharacters(in: .whitespaces),
                    intensity: intensity,
                    startMinute: startMinute, durationMinutes: minutes,
                    repeatWeekdays: effectiveWeekdays,
                    startDate: startDate, endDate: endDate)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 생성 완료 — 초대코드 안내
    private func createdPanel(_ room: GroupRoom) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "party.popper.fill")
                .font(.system(size: 44))
                .foregroundStyle(TL.amber)
            Text("'\(room.name)'\n방이 만들어졌어요")
                .font(.tlTitle(22))
                .foregroundStyle(TL.paper)
                .multilineTextAlignment(.center)
            InviteCodeCard(code: room.code)
            Text("초대코드를 공유하면 시작 전까지 최대 \(GroupPolicy.maxMembers)명이 참여할 수 있어요.\n코드는 방장인 나에게만 보여요.")
                .font(.system(size: 13))
                .foregroundStyle(TL.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Spacer()
            Button("확인") { dismiss() }
                .buttonStyle(TLPrimaryButtonStyle())
        }
        .padding(24)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TL.muted)
            content()
        }
    }
}

// MARK: - 참여하기 (초대코드 + 닉네임)

struct GroupJoinView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = GroupStore.shared
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var subscription: SubscriptionManager
    @Query(filter: #Predicate<Reservation> { $0.isActive }) private var allActiveReservations: [Reservation]
    @Query private var allSessions: [FocusSession]
    @State private var showSlotPolicy = false

    // 참여도 그룹 예약(슬롯 1개)이 생기므로 상단에 슬롯 현황 노출
    private var slotUsed: Int { allActiveReservations.filter { $0.ownerUserID == account.currentUserID }.count }
    private var slotStreak: Int { SlotPolicy.currentStreak(sessions: allSessions.filter { $0.ownerUserID == account.currentUserID }) }
    private var slotAllowed: Int? { SlotPolicy.allowedSlots(forStreak: slotStreak, isMember: subscription.isPro) }

    @State private var code = ""
    @State private var nickname = ""
    @State private var preview: GroupRoom?
    @State private var working = false
    @State private var errorMessage: String?
    @State private var joined = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if joined {
                        joinedPanel
                    } else {
                        SlotStatusBadge(used: slotUsed, allowed: slotAllowed, streak: slotStreak) {
                            showSlotPolicy = true
                        }
                        Text("방장에게 받은 초대코드를 입력하세요.")
                            .font(.system(size: 14))
                            .foregroundStyle(TL.muted)

                        TextField("초대코드 (5자리)", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.tlTimer(24))
                            .multilineTextAlignment(.center)
                            .groupFieldStyle()
                            .onChange(of: code) {
                                code = String(code.uppercased().prefix(GroupPolicy.codeLength))
                                preview = nil
                            }

                        if let room = preview {
                            previewCard(room)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("이 방에서 쓸 닉네임 (중복 불가 · 선착순 · 최대 \(GroupPolicy.nicknameMaxLength)자)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(TL.muted)
                                TextField("예: 지지않는사람", text: $nickname)
                                    .groupFieldStyle()
                                    .onChange(of: nickname) { _, new in
                                        if new.count > GroupPolicy.nicknameMaxLength {
                                            nickname = String(new.prefix(GroupPolicy.nicknameMaxLength))
                                        }
                                    }
                            }
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TL.rec)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if preview == nil {
                            Button(working ? "찾는 중…" : "방 찾기") { lookup() }
                                .buttonStyle(TLPrimaryButtonStyle())
                                .disabled(working || code.count < GroupPolicy.codeLength)
                                .opacity(code.count >= GroupPolicy.codeLength ? 1 : 0.5)
                        } else {
                            Button(working ? "참여 중…" : "이 방에 참여하기") { join() }
                                .buttonStyle(TLPrimaryButtonStyle())
                                .disabled(working || nickname.trimmingCharacters(in: .whitespaces).isEmpty)
                                .opacity(nickname.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                        }
                    }
                }
                .padding(20)
            }
            .background(TL.ink)
            .navigationTitle("초대코드로 참여")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                        .foregroundStyle(TL.muted)
                }
            }
            .sheet(isPresented: $showSlotPolicy) {
                SlotPolicySheet(currentStreak: slotStreak, usedSlots: slotUsed, isMember: subscription.isPro)
                    .presentationDetents([.medium, .large])
            }
        }
        .preferredColorScheme(.dark)
    }

    private func previewCard(_ room: GroupRoom) -> some View {
        TLCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(room.name)
                        .font(.tlTitle(18))
                        .foregroundStyle(TL.paper)
                    Spacer()
                    Text("\(room.memberCount)/\(GroupPolicy.maxMembers)명")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(room.memberCount >= GroupPolicy.maxMembers ? TL.rec : TL.jade)
                }
                Text(GroupFormat.scheduleLine(room))
                    .font(.system(size: 13)).foregroundStyle(TL.muted)
                Text("\(GroupFormat.day(room.startDate)) ~ \(GroupFormat.day(room.endDate)) · \(room.intensity.emoji) \(room.intensity.title)")
                    .font(.system(size: 13)).foregroundStyle(TL.muted)
            }
        }
    }

    private var joinedPanel: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(TL.jade)
            Text("참여 완료!")
                .font(.tlTitle(22))
                .foregroundStyle(TL.paper)
            Text("시작 시각이 되면 그룹 일정이 자동으로 내 활동에 추가되고,\n그때부터 상벌점이 그룹 랭킹에 집계됩니다.")
                .font(.system(size: 13))
                .foregroundStyle(TL.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button("확인") { dismiss() }
                .buttonStyle(TLPrimaryButtonStyle())
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func lookup() {
        errorMessage = nil
        working = true
        Task {
            defer { working = false }
            do {
                preview = try await store.lookup(code: code)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func join() {
        guard let room = preview else { return }
        errorMessage = nil
        working = true
        Task {
            defer { working = false }
            do {
                try store.checkSlotAvailable()                // 그룹도 슬롯 1개를 차지한다
                try store.checkScheduleConflict(room: room)   // 기존 예약과 겹침 검사
                try await store.join(room: room, nickname: nickname.trimmingCharacters(in: .whitespaces))
                joined = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 방 상세 (시작 전 대기실 / 진행 중 랭킹 / 종료 결과)

/// 그룹 방에서 활동을 시작하는 보조 진입 — 알람을 놓쳐도 여기서 촬영을 시작할 수 있다.
/// '활동 시작하기'는 예정 시각부터 10분 창 안에서만 활성화되며, 그 외엔 다음 시작까지 카운트다운만 보인다.
private struct GroupStartActivityCard: View {
    let room: GroupRoom
    @EnvironmentObject private var app: AppState
    @State private var now = Date()
    // 분단위 표시라 초당 갱신이 필요 없다 — 15초 폴링으로 예약·창 재계산까지 함께 처리(부하·불안감↓). [P3-3]
    @State private var reservation: Reservation?
    @State private var windowFire: Date?
    @State private var nextFire: Date?
    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    /// 남은 초 → 올림 분(최소 1). 초단위 카운트다운 대신 '분'만 보여 UI·심리 부하를 줄인다.
    private func minutesUp(_ seconds: Int) -> Int { max(1, Int((Double(seconds) / 60).rounded(.up))) }

    /// '다음 시작까지' 문구 — 예: "59분 뒤 시작", "2시간 5분 뒤 시작", "1분 뒤 시작".
    private func startsInLabel(_ seconds: Int) -> String {
        let m = minutesUp(seconds)
        if m >= 1440 { return "\(m / 1440)일 뒤 시작" }
        if m >= 60 { return "\(m / 60)시간 \(m % 60)분 뒤 시작" }
        return "\(m)분 뒤 시작"
    }

    /// 예약·시작 창·다음 발생 시각을 다시 조회한다 (fetch 포함 — 15초 간격·onAppear에서만 호출).
    private func refresh() {
        let r = app.groupReservation(roomID: room.id)
        reservation = r
        windowFire = r.flatMap { app.startableWindowFire(for: $0) }
        nextFire = r?.nextOccurrence(after: Date())
    }

    var body: some View {
        TLCard {
            VStack(alignment: .leading, spacing: 12) {
                TLEyebrow(text: "활동 인증")

                if let fire = windowFire {
                    // 창 안 — 지금 시작 가능. 남은 시간을 분단위로(내림) 표시 — 초단위는 불안감만 키운다.
                    // 안전 쪽으로 내림: "1분 미만"이 되어도 실제로는 아직 여유가 있을 수 있음.
                    let remainSeconds = max(0, Int(fire.addingTimeInterval(TimePolicy.startWindowSeconds).timeIntervalSince(now)))
                    let remainMinutes = remainSeconds / 60
                    Text("지금 활동을 시작할 수 있어요")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(TL.paper)
                    Label(remainMinutes >= 1 ? "남은 시간 \(remainMinutes)분" : "남은 시간 1분 미만", systemImage: "timer")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(TL.amber)
                    Button {
                        // 탭 '그 순간' 창을 다시 검증한다 — 15초 캐시 탓에 창이 닫힌 뒤 눌리면
                        // 노쇼 스위퍼와 이중 기록될 수 있으므로, 캐시(fire)가 아니라 fresh 값으로 확인. [audit]
                        guard let r = reservation, let freshFire = app.startableWindowFire(for: r) else {
                            refresh()   // 이미 창이 닫혔으면 카드 상태만 즉시 갱신하고 시작하지 않는다
                            return
                        }
                        app.proceedToMountGuide(reservation: r, fireDate: freshFire, fromAlarm: false)
                    } label: {
                        Label("활동 시작하기", systemImage: "record.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TLPrimaryButtonStyle())
                } else if let next = nextFire {
                    // 창 밖 — 분단위 카운트다운("59분 뒤 시작" ~ "1분 뒤 시작"). 버튼 비활성.
                    Text(startsInLabel(max(0, Int(next.timeIntervalSince(now)))))
                        .font(.system(size: 22, weight: .black, design: .rounded)).foregroundStyle(TL.amber)
                    Button {} label: {
                        Label("활동 시작하기", systemImage: "record.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TLPrimaryButtonStyle())
                    .disabled(true)
                    .opacity(0.4)
                    Text("예정 시각부터 \(TimePolicy.startWindowMinutes)분 안에만 시작할 수 있어요.")
                        .font(.system(size: 12)).foregroundStyle(TL.faint)
                } else {
                    Text("예정된 활동이 없어요.")
                        .font(.system(size: 14)).foregroundStyle(TL.muted)
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(clock) { d in
            now = d       // 분단위 표시라 15초 간격이면 충분 — 매초 갱신·잦은 fetch가 필요 없다
            refresh()
        }
    }
}

struct GroupRoomDetailView: View {
    /// 진입 시점의 스냅샷. 화면을 열어 둔 사이 방 상태가 바뀌므로 표시에는 쓰지 않는다.
    let initialRoom: GroupRoom

    init(room: GroupRoom) { self.initialRoom = room }

    /// 실제로 그릴 방 — 목록(store.rooms)의 최신 값을 따라간다.
    /// 스냅샷만 붙들면 시작 시각이 지나도 화면이 그대로여서, 곧 취소될 방에서
    /// '활동 시작하기'가 눌리는 상태가 된다.
    private var room: GroupRoom {
        store.rooms.first(where: { $0.id == initialRoom.id }) ?? initialRoom
    }
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var app: AppState
    @StateObject private var store = GroupStore.shared

    @State private var members: [GroupMember] = []
    @State private var loading = true
    @State private var confirmLeave = false
    @State private var confirmQuit = false
    @State private var confirmDisband = false
    @State private var working = false
    @State private var leaveError: String?
    @State private var now = Date()
    /// 이 방을 목록에서 한 번이라도 본 적이 있는가 — 본 뒤에 사라지면 닫는다.
    /// (진입 직후 목록이 비어 있는 순간에 잘못 닫히지 않게 하는 가드)
    @State private var sawRoomInStore = false
    // 시작 카운트다운은 '분' 단위 표시라 30초 폴링이면 충분(부하·불안감↓).
    @State private var clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var myUID: String { account.currentUserID }

    /// 나가기·해체·중도포기 공통 실행 — 성공했을 때만 화면을 닫는다.
    /// 예전엔 `try?` 뒤에 무조건 dismiss라 실패해도 나간 것처럼 보이고 그룹 예약이 일정에 남았다.
    private func runLeaveAction(_ action: @escaping () async throws -> Void) async {
        working = true
        defer { working = false }
        do {
            try await action()
            dismiss()
        } catch {
            leaveError = error.localizedDescription
        }
    }

    /// 남은 시간 문구 — 예: "6시간 18분 뒤 시작", "42분 뒤 시작", "곧 시작".
    private func startRemainLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "곧 시작" }
        let m = seconds / 60
        let h = m / 60, mm = m % 60
        if h > 0 { return "\(h)시간 \(mm)분 뒤 시작" }
        return "\(mm)분 뒤 시작"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                infoCard

                // 시작 10분 이내인데 아직 2명 미만이면, 곧 폭파(자동 삭제)될 방임을 경고한다.
                // 삭제가 확정된 방은 아래 doomedCard가 더 정확히 안내한다 — 경고 카드가 겹치지 않게 뺀다.
                if !room.doomed, !room.hasStarted,
                   Int(room.startDate.timeIntervalSince(now)) <= 10 * 60,
                   room.memberCount < GroupPolicy.minMembersToStart {
                    disbandWarningCard
                }

                if room.doomed {
                    // 참여 마감이 지났는데 인원이 모자란 방 — 시작 시각에 삭제된다.
                    // 활동은 진행되지 않으므로 시작 버튼도 랭킹도 띄우지 않는다.
                    doomedCard
                    waitingSection
                } else if room.status == "scheduled" && !room.hasStarted {
                    invitePreStartCard
                    waitingSection
                } else if room.status == "scheduled" {
                    // 시작 시각은 지났는데 아직 시작/취소 판정이 끝나지 않았다.
                    // 여기서 시작 버튼을 열면 곧 취소될 방에서 촬영이 시작된다.
                    pendingDecisionCard
                    waitingSection
                } else if room.isFinished {
                    resultSection
                } else {
                    GroupStartActivityCard(room: room)   // 알람을 놓쳐도 방에서 직접 시작 (창 안에서만 활성)
                    rankingSection
                }

                actionSection
            }
            .padding(20)
            .padding(.bottom, 40)
        }
        .background(TL.ink)
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        // 화면에 들어올 때마다 방 상태를 즉시 다시 읽는다 — 타이머를 기다리지 않는다.
        .task {
            // onChange는 초기값에 발화하지 않는다 — 여기서 한 번 세워야 자동 닫기가 동작한다.
            sawRoomInStore = store.rooms.contains { $0.id == initialRoom.id }
            await store.refresh()
            sawRoomInStore = sawRoomInStore || store.rooms.contains { $0.id == initialRoom.id }
            await load()
        }
        .refreshable {
            await store.refresh()
            await load()
        }
        .onChange(of: store.rooms) { _, rooms in
            if rooms.contains(where: { $0.id == initialRoom.id }) {
                sawRoomInStore = true
            } else if sawRoomInStore {
                // 서버에서 사라진 방(해체·취소·보존 만료)의 화면을 옛 정보로 계속 띄우면
                // 이미 없는 방의 초대·나가기 버튼이 살아 있는 것처럼 보인다.
                dismiss()
            }
        }
        .onReceive(clock) { tick in
            now = tick
            // 시작 시각이 지났는데 아직 판정 전이면, 화면을 열어 둔 채로도 스스로 확인한다.
            // (그대로 두면 '확인 중'에 머물러 사용자가 화면을 나갔다 들어와야 한다)
            // 목록에 남아 있는 방에 한해, 판정이 필요한 구간에서만 확인한다.
            if store.rooms.contains(where: { $0.id == initialRoom.id }),
               room.status == "scheduled", room.hasStarted || !room.joinOpen {
                Task { await store.refresh() }
            }
        }
        .alert("처리하지 못했어요", isPresented: Binding(
            get: { leaveError != nil }, set: { if !$0 { leaveError = nil } })) {
            Button("확인", role: .cancel) { leaveError = nil }
        } message: {
            Text(leaveError ?? "")
        }
    }

    private func load() async {
        loading = true
        members = await store.members(roomID: room.id)
        loading = false
    }

    // MARK: 정보 카드

    private var infoCard: some View {
        TLCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(room.name)
                        .font(.tlTitle(20))
                        .foregroundStyle(TL.paper)
                    if room.isHostMine {
                        Image(systemName: "star.fill")
                            .font(.system(size: 13)).foregroundStyle(TL.amber)
                    }
                }
                Text(GroupFormat.scheduleLine(room))
                    .font(.system(size: 13)).foregroundStyle(TL.muted)
                Text("\(GroupFormat.day(room.startDate)) ~ \(GroupFormat.day(room.endDate)) · \(room.intensity.emoji) \(room.intensity.title) · \(room.memberCount)명")
                    .font(.system(size: 13)).foregroundStyle(TL.muted)
            }
        }
    }

    // MARK: 폭파 임박 경고 (시작 10분 이내 · 2명 미만)

    /// 삭제가 확정된 방 (참여 마감 후 인원 미달)
    private var doomedCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "trash.fill")
                .font(.system(size: 15)).foregroundStyle(TL.rec)
            VStack(alignment: .leading, spacing: 4) {
                Text("참여 인원이 모자라 이 방은 시작 시각에 삭제됩니다.")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(TL.rec)
                Text("참여 마감이 지나 더 들어올 수 없어요. 활동은 진행되지 않고 알람도 취소했습니다.")
                    .font(.system(size: 12)).foregroundStyle(TL.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
            .fill(TL.rec.opacity(0.12)))
    }

    /// 시작 시각이 지났지만 아직 시작/취소가 정해지지 않은 방
    private var pendingDecisionCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 15)).foregroundStyle(TL.amber)
            Text("시작 여부를 확인하는 중입니다. 잠시 후 다시 열어주세요.")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(TL.amber)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
            .fill(TL.amber.opacity(0.12)))
    }

    private var disbandWarningCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15)).foregroundStyle(TL.rec)
            Text("참여자가 2명 미만이 되어 방이 곧 삭제될 예정입니다.")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(TL.rec)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.rec.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
            .strokeBorder(TL.rec.opacity(0.4), lineWidth: 1))
    }

    // MARK: 시작 전 — '활동 인증' 카드 통일 (활성 카드와 같은 틀: 카운트다운 + 코드 + 안내)

    /// 시작 카운트다운 문구와 임박(노랑) 여부. 12시간 이내면 분단위 남은시간(임박),
    /// 그보다 멀면 일/시간 단위로 담담하게.
    private func startCountdown() -> (text: String, urgent: Bool) {
        let secs = Int(room.startDate.timeIntervalSince(now))
        if secs <= 12 * 3600 { return (startRemainLabel(secs), true) }
        let m = max(1, secs / 60)
        if m >= 1440 { return ("\(m / 1440)일 뒤 시작", false) }
        return ("\(m / 60)시간 뒤 시작", false)
    }

    /// 최초 시작 전 — 활성 상태의 '활동 인증' 카드와 동일한 틀.
    /// 버튼 자리에는 초대코드(방장만), 그 아래엔 참여 마감 안내.
    private var invitePreStartCard: some View {
        let cd = startCountdown()
        return TLCard {
            VStack(alignment: .leading, spacing: 12) {
                TLEyebrow(text: "초대하기")
                Text(cd.text)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(cd.urgent ? TL.amber : TL.paper)
                if room.isHostMine {
                    InviteCodeCard(code: room.code)   // '활동 시작하기' 버튼 자리에 코드
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("• 시작 10분 전까지만 참여할 수 있어요")
                    Text("• 초대코드는 방장만 볼 수 있어요")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TL.amber)
            }
        }
    }

    // MARK: 시작 전 — 참여자 대기실

    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TLEyebrow(text: "참여자 \(members.count)/\(GroupPolicy.maxMembers)")
            TLCard {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(members.sorted { $0.joinedAt < $1.joinedAt }) { member in
                            HStack(spacing: 8) {
                                Text(member.nickname)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(TL.paper)
                                if member.id == room.hostUID {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 11)).foregroundStyle(TL.amber)
                                }
                                if member.id == myUID {
                                    Text("나")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(TL.ink)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(Capsule().fill(TL.jade))
                                }
                                Spacer()
                            }
                            .padding(.vertical, 9)
                            if member.id != members.sorted(by: { $0.joinedAt < $1.joinedAt }).last?.id {
                                Divider().overlay(TL.hairline.opacity(0.5))
                            }
                        }
                    }
                }
            }
            Text("시작 시각에 \(GroupPolicy.minMembersToStart)명 미만이면 방이 자동 삭제됩니다.")
                .font(.system(size: 12)).foregroundStyle(TL.faint)
        }
    }

    // MARK: 진행 중 — 랭킹 (상위 5명 + 내 순위)

    private var rankingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TLEyebrow(text: "실시간 랭킹")
            TLCard {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                } else {
                    let ranked = GroupStore.ranked(members)
                    let visible = ranked.count <= 7 ? ranked : Array(ranked.prefix(5))
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.member.id) { index, item in
                            rankRow(item)
                            if index < visible.count - 1 {
                                Divider().overlay(TL.hairline.opacity(0.5))
                            }
                        }
                        // 많을 때: … + 내 순위
                        if ranked.count > 7, let mine = ranked.first(where: { $0.member.id == myUID }),
                           mine.rank > 5 {
                            Text("⋯")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(TL.faint)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                            Divider().overlay(TL.hairline.opacity(0.5))
                            rankRow(mine)
                        }
                    }
                }
            }
            Text("점수는 이 그룹 일정에서 얻은 상벌점만 집계돼요. 동점은 공동 등수입니다.")
                .font(.system(size: 12)).foregroundStyle(TL.faint)
        }
    }

    // MARK: 종료 — 최종 결과 (전원)

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TLEyebrow(text: "최종 결과", color: TL.amber)
            TLCard {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                } else {
                    let ranked = GroupStore.ranked(members)
                    VStack(spacing: 0) {
                        ForEach(Array(ranked.enumerated()), id: \.element.member.id) { index, item in
                            rankRow(item)
                            if index < ranked.count - 1 {
                                Divider().overlay(TL.hairline.opacity(0.5))
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12)).foregroundStyle(TL.amber)
                Text(deletionNotice)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(TL.muted)
            }
            Text("결과는 종료 후 \(GroupPolicy.resultRetentionDays)일 동안 보관됩니다.")
                .font(.system(size: 12)).foregroundStyle(TL.faint)
        }
    }

    /// 남은 보존 기간 안내. 날짜 경계 기준으로 세어 "0일 뒤"가 뜨지 않게 한다.
    private var deletionNotice: String {
        let cal = Calendar.current
        let remaining = cal.dateComponents([.day],
                                           from: cal.startOfDay(for: now),
                                           to: cal.startOfDay(for: room.deleteAt)).day ?? 0
        if remaining <= 0 { return "오늘 중 이 방과 결과가 자동으로 삭제됩니다." }
        return "\(remaining)일 뒤 이 방과 결과가 자동으로 삭제됩니다."
    }

    private func rankRow(_ item: (rank: Int, member: GroupMember)) -> some View {
        let isMe = item.member.id == myUID
        return HStack(spacing: 10) {
            Text("\(item.rank)")
                .font(.tlTimer(17))
                .foregroundStyle(item.rank == 1 ? TL.amber : TL.paper)
                .frame(width: 30, alignment: .center)
            Text(item.member.nickname)
                .font(.system(size: 15, weight: isMe ? .bold : .semibold))
                .foregroundStyle(TL.paper)
                .lineLimit(1)
            if item.member.id == room.hostUID {
                Image(systemName: "star.fill")
                    .font(.system(size: 11)).foregroundStyle(TL.amber)
            }
            if isMe {
                Text("나")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TL.ink)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(TL.jade))
            }
            if item.member.quit {
                Text("중도 포기")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TL.rec)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().strokeBorder(TL.rec.opacity(0.5), lineWidth: 1))
            }
            Spacer()
            Text(item.member.score >= 0 ? "+\(item.member.score)" : "\(item.member.score)")
                .font(.tlTimer(16))
                .foregroundStyle(item.member.score >= 0 ? TL.jade : TL.rec)
        }
        .padding(.vertical, 10)
    }

    // MARK: 하단 액션 — 해체 / 탈퇴 / 중도 포기 / 나가기

    @ViewBuilder
    private var actionSection: some View {
        if room.isFinished {
            Button(working ? "나가는 중…" : "방 나가기 (결과가 내 목록에서 사라져요)") {
                // 다른 나가기 경로와 동일하게 — 성공했을 때만 닫는다.
                Task { await runLeaveAction { try await store.hideFinishedRoom(room: room) } }
            }
            .buttonStyle(TLGhostButtonStyle())
            .disabled(working)
        } else if room.status == "cancelled" || room.status == "disbanded" {
            // 이미 끝난 방 — 정리가 아직 안 됐을 뿐이다. 벌점 액션을 보이면 안 된다.
            Button(working ? "나가는 중…" : "방 나가기") {
                Task { await runLeaveAction { try await store.hideFinishedRoom(room: room) } }
            }
            .buttonStyle(TLGhostButtonStyle())
            .disabled(working)
        } else if room.hasStarted, room.status == "scheduled" {
            // 시작 시각은 지났는데 아직 시작/취소 판정이 안 끝났다. 여기서 무벌점 탈퇴를 열면
            // 곧 active가 될 방을 벌점 없이 빠져나가는 회피 경로가 되고, 중도 포기를 열면
            // 진행조차 안 한 방에서 -50점을 물게 된다. 그래서 아무 액션도 노출하지 않는다.
            Text("시작 여부를 확인하는 중이에요. 잠시 후 다시 시도해주세요.")
                .font(.system(size: 12)).foregroundStyle(TL.faint)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if !room.hasStarted {
            if room.isHostMine {
                // 처리 중에는 다시 누르지 못하게 막는다 — 두 번 실행되면 인원수가 두 번 줄어
                // 목록·상세의 참여자 수가 어긋나고 허위 '정원 초과'까지 난다.
                Button(working ? "해체하는 중…" : "방 해체하기") { confirmDisband = true }
                    .buttonStyle(TLGhostButtonStyle(tint: TL.rec))
                    .disabled(working)
                    .confirmationDialog("방을 해체할까요?", isPresented: $confirmDisband, titleVisibility: .visible) {
                        Button("해체하기", role: .destructive) {
                            // 실패했는데 닫으면 '나갔다'고 오해하고 예약이 남는다 — 성공했을 때만 닫는다.
                            Task { await runLeaveAction { try await store.disband(room: room) } }
                        }
                    } message: {
                        Text("참여자 전원에게 방이 사라지고, 되돌릴 수 없습니다.")
                    }
            } else {
                Button {
                    confirmLeave = true
                } label: {
                    VStack(spacing: 2) {
                        Text(working ? "탈퇴하는 중…" : "탈퇴하기")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(TL.rec)
                        Text("시작 전에는 벌점 없음")
                            .font(.system(size: 11))
                            .foregroundStyle(TL.faint)
                    }
                }
                .buttonStyle(TLGhostButtonStyle(tint: TL.rec))
                .disabled(working)
                    .confirmationDialog("방에서 나갈까요?", isPresented: $confirmLeave, titleVisibility: .visible) {
                        Button("탈퇴하기", role: .destructive) {
                            Task { await runLeaveAction { try await store.leaveBeforeStart(room: room) } }
                        }
                    }
            }
        } else {
            Button(working ? "처리 중…" : "중도 포기하기 (벌점 \(ScoreRules.groupQuitPenalty)점)") { confirmQuit = true }
                .buttonStyle(TLGhostButtonStyle(tint: TL.rec))
                .disabled(working)
                .confirmationDialog("정말 중도 포기할까요?", isPresented: $confirmQuit, titleVisibility: .visible) {
                    Button("포기하기 (벌점 \(ScoreRules.groupQuitPenalty)점)", role: .destructive) {
                        Task { await runLeaveAction { try await store.quitAfterStart(room: room) } }
                    }
                } message: {
                    Text("벌점 \(ScoreRules.groupQuitPenalty)점이 그룹 점수와 내 누적 점수에 모두 기록되고, 남은 그룹 일정이 삭제됩니다. 지금까지 얻은 점수는 유지됩니다.")
                }
        }
    }
}

// MARK: - 공용 조각

/// 초대코드 카드 — 방장 전용. 탭하면 복사.
struct InviteCodeCard: View {
    let code: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = code
            copied = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        } label: {
            VStack(spacing: 4) {
                Text(code.map(String.init).joined(separator: " "))
                    .font(.tlTimer(30))
                    .foregroundStyle(TL.paper)
                    .kerning(2)
                Text(copied ? "복사됐어요!" : "초대코드 · 탭해서 복사")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied ? TL.jade : TL.faint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.raised))
            .overlay(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
                .strokeBorder(TL.rec.opacity(0.45), lineWidth: 1))
        }
        .pressableStyle()
    }
}

/// 날짜·요일·시간 표기 공용
enum GroupFormat {
    static let weekdayNames: [Int: String] = [1: "일", 2: "월", 3: "화", 4: "수", 5: "목", 6: "금", 7: "토"]

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E)"
        return formatter.string(from: date)
    }

    static func time(_ minute: Int) -> String {
        let h = minute / 60, m = minute % 60
        let isPM = h >= 12
        let h12 = h % 12 == 0 ? 12 : h % 12
        return m == 0 ? "\(isPM ? "오후" : "오전") \(h12)시"
                      : "\(isPM ? "오후" : "오전") \(h12):\(String(format: "%02d", m))"
    }

    static func dDay(_ date: Date) -> String {
        let days = Calendar.current.dateComponents(
            [.day], from: Calendar.current.startOfDay(for: .now),
            to: Calendar.current.startOfDay(for: date)).day ?? 0
        return days <= 0 ? "오늘" : "D-\(days)"
    }

    static func scheduleLine(_ room: GroupRoom) -> String {
        // 시작일=종료일(또는 요일 없음, 레거시)이면 그날 하루만 진행하는 단발 그룹
        let sameDay = Calendar.current.isDate(room.startDate, inSameDayAs: room.endDate)
        let when = (room.repeatWeekdays.isEmpty || sameDay)
            ? "\(day(room.startDate)) 하루"
            : room.repeatWeekdays.count == 7 ? "매일"
            : "반복요일 " + room.repeatWeekdays.sorted().compactMap { weekdayNames[$0] }.joined(separator: " ")
        return "\(when) · \(time(room.startMinute)) · \(TLFormat.durationLabel(room.durationMinutes))"
    }
}

// MARK: - 텍스트필드 스타일

private extension View {
    func groupFieldStyle() -> some View {
        self
            .font(.tlBody)
            .foregroundStyle(TL.paper)
            .padding(14)
            .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                .strokeBorder(TL.hairline, lineWidth: 1))
    }
}
