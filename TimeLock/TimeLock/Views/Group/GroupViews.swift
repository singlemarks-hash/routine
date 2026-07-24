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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                        .padding(.top, 6)

                    if locked && store.rooms.isEmpty {
                        lockedPanel
                    } else {
                        notices

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

    // MARK: 멤버십 잠금 패널 — 비구독자 & 참여 중인 방 없음

    private var lockedPanel: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(TL.raised)
                    .frame(width: 84, height: 84)
                    .overlay(Circle().strokeBorder(TL.hairline, lineWidth: 1))
                Image(systemName: "lock.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(TL.amber)
            }
            .padding(.top, 28)

            Text("멤버십 전용 기능이에요")
                .font(.tlTitle(20))
                .foregroundStyle(TL.paper)
            Text("초대코드로 친구들과 방을 만들고,\n같은 일정으로 상벌점 랭킹 대결을 해보세요.\n멤버십을 구독하면 바로 열립니다.")
                .font(.system(size: 14))
                .foregroundStyle(TL.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Button("멤버십 구독하고 시작하기") { showPaywall = true }
                .buttonStyle(TLPrimaryButtonStyle(tint: TL.jade))
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
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
            room.isFinished ? ("종료", TL.faint)
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

struct GroupCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = GroupStore.shared

    @State private var name = ""
    @State private var nickname = ""
    @State private var intensity: Intensity = .spicy
    @State private var startTime = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: .now)!
    @State private var minutes = 30
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    @State private var startDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
    @State private var endDay = Calendar.current.date(byAdding: .day, value: 28, to: Calendar.current.startOfDay(for: .now))!
    @State private var working = false
    @State private var errorMessage: String?
    @State private var createdRoom: GroupRoom?

    private var tomorrow: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
    }
    private var maxEndDay: Date {
        // 포함 일수 기준(안드로이드 통일): startDay 당일 포함 최대 maxDurationDays일 → +(N-1)
        Calendar.current.date(byAdding: .day, value: GroupPolicy.maxDurationDays - 1, to: startDay)!
    }
    private var formReady: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !nickname.trimmingCharacters(in: .whitespaces).isEmpty
            && !weekdays.isEmpty
    }

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
        }
        .preferredColorScheme(.dark)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                field("방 이름 (참여자 전원의 활동명이 됩니다)") {
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
                            Button {
                                intensity = candidate
                            } label: {
                                VStack(spacing: 3) {
                                    Text("\(candidate.emoji) \(candidate.title)")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                    Text(candidate == .spicy ? "긴급 용무 10분 허용" : "이탈 즉시 실패 · 점수 2배")
                                        .font(.system(size: 10))
                                }
                                .foregroundStyle(intensity == candidate ? TL.ink : TL.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                                        .fill(intensity == candidate ? TL.paper : TL.surface)
                                )
                            }
                        }
                    }
                }

                field("매일 몇 시에 시작하나요?") {
                    DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .colorScheme(.dark)
                }

                field("활동 길이") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(TimePolicy.durationOptionsMinutes, id: \.self) { option in
                                Button {
                                    minutes = option
                                } label: {
                                    Text(TLFormat.durationLabel(option))
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(minutes == option ? TL.ink : TL.muted)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Capsule().fill(minutes == option ? TL.paper : TL.surface))
                                }
                            }
                        }
                    }
                }

                field("반복 요일") {
                    HStack(spacing: 8) {
                        ForEach(1...7, id: \.self) { day in
                            let selected = weekdays.contains(day)
                            Button {
                                if selected { weekdays.remove(day) } else { weekdays.insert(day) }
                            } label: {
                                Text(GroupFormat.weekdayNames[day] ?? "")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(selected ? TL.ink : TL.muted)
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(selected ? TL.paper : TL.surface))
                            }
                        }
                    }
                }

                field("기간 — 시작은 1시간 뒤부터, 최대 3개월") {
                    VStack(spacing: 0) {
                        DatePicker("시작일", selection: $startDay,
                                   in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
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
        let start = GroupFormat.day(startDay)
        let end = GroupFormat.day(endDay)
        let time = GroupFormat.time(startMinute)
        let days = weekdays.isEmpty ? "요일 미선택"
            : "매주 " + weekdays.sorted().compactMap { GroupFormat.weekdayNames[$0] }.joined(separator: " ")
        return "\(start) ~ \(end)\n\(days) · \(time) 시작 · \(TLFormat.durationLabel(minutes)) · \(intensity.title)\n시작 \(GroupPolicy.joinCutoffMinutes)분 전까지만 참여할 수 있고, 시작 시각에 \(GroupPolicy.minMembersToStart)명 미만이면 방이 자동 삭제됩니다."
    }

    private var startMinute: Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private func create() {
        errorMessage = nil
        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .minute, value: startMinute,
                                      to: calendar.startOfDay(for: startDay))!
        // endDate = 종료일의 끝(23:59:59.999) — 안드로이드와 통일. 마지막 날 세션 시각이 아니라 그날 전체를 포함해
        // 다른 시간대 참여자가 자기 로컬 마지막 세션을 마칠 여유를 준다.
        let endDate = calendar.startOfDay(for: endDay).addingTimeInterval(86_400 - 0.001)
        // 종료일·기간 검증 (안드로이드와 동일 — 시작일 포함 일수 기준)
        guard endDay >= startDay else { errorMessage = "종료일이 시작일보다 빠를 수 없어요."; return }
        let inclusiveDays = (calendar.dateComponents([.day],
            from: calendar.startOfDay(for: startDay), to: calendar.startOfDay(for: endDay)).day ?? 0) + 1
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
                                            repeatWeekdays: weekdays.sorted(),
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
                    repeatWeekdays: weekdays.sorted(),
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
    let room: GroupRoom
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
    @State private var now = Date()
    // 시작 카운트다운은 '분' 단위 표시라 30초 폴링이면 충분(부하·불안감↓).
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var myUID: String { account.currentUserID }

    /// 시작까지 남은 시간 문구 — 예: "시작까지 6시간 18분 남음", "시작까지 42분 남음", "곧 시작".
    private func startRemainLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "곧 시작" }
        let m = seconds / 60
        let h = m / 60, mm = m % 60
        if h > 0 { return "시작까지 \(h)시간 \(mm)분 남음" }
        return "시작까지 \(mm)분 남음"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                infoCard

                // 시작 10분 이내인데 아직 2명 미만이면, 곧 폭파(자동 삭제)될 방임을 경고한다.
                if !room.hasStarted,
                   Int(room.startDate.timeIntervalSince(now)) <= 10 * 60,
                   room.memberCount < GroupPolicy.minMembersToStart {
                    disbandWarningCard
                }

                if room.status == "scheduled" && !room.hasStarted {
                    invitePreStartCard
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
        .task { await load() }
        .refreshable { await load() }
        .onReceive(clock) { now = $0 }
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
                    Text("• 시작 10분 전까지만 참여할 수 있어요.")
                    Text("• 초대는 방장만 가능해요.")
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
            Text("결과는 종료 후 \(GroupPolicy.resultRetentionDays)일 동안 보관됩니다.")
                .font(.system(size: 12)).foregroundStyle(TL.faint)
        }
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
            Button("방 나가기 (결과가 내 목록에서 사라져요)") {
                Task { await store.hideFinishedRoom(room: room); dismiss() }
            }
            .buttonStyle(TLGhostButtonStyle())
        } else if !room.hasStarted {
            if room.isHostMine {
                Button("방 해체하기") { confirmDisband = true }
                    .buttonStyle(TLGhostButtonStyle(tint: TL.rec))
                    .confirmationDialog("방을 해체할까요?", isPresented: $confirmDisband, titleVisibility: .visible) {
                        Button("해체하기", role: .destructive) {
                            Task { try? await store.disband(room: room); dismiss() }
                        }
                    } message: {
                        Text("참여자 전원에게 방이 사라지고, 되돌릴 수 없습니다.")
                    }
            } else {
                Button("탈퇴하기 (시작 전에는 벌점 없음)") { confirmLeave = true }
                    .buttonStyle(TLGhostButtonStyle())
                    .confirmationDialog("방에서 나갈까요?", isPresented: $confirmLeave, titleVisibility: .visible) {
                        Button("탈퇴하기", role: .destructive) {
                            Task { try? await store.leaveBeforeStart(room: room); dismiss() }
                        }
                    }
            }
        } else {
            Button("중도 포기하기 (벌점 \(ScoreRules.groupQuitPenalty)점)") { confirmQuit = true }
                .buttonStyle(TLGhostButtonStyle(tint: TL.rec))
                .confirmationDialog("정말 중도 포기할까요?", isPresented: $confirmQuit, titleVisibility: .visible) {
                    Button("포기하기 (벌점 \(ScoreRules.groupQuitPenalty)점)", role: .destructive) {
                        Task { try? await store.quitAfterStart(room: room); dismiss() }
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
        let days = "매주 " + room.repeatWeekdays.sorted()
            .compactMap { weekdayNames[$0] }.joined(separator: " ")
        return "\(days) · \(time(room.startMinute)) · \(TLFormat.durationLabel(room.durationMinutes))"
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
