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
    @State private var isRepeating = false
    @State private var weekdays: Set<Int> = []
    @State private var oneOffDate = Date()
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false
    @State private var showSlotPolicy = false

    private let weekdaySymbols = [(1, "일"), (2, "월"), (3, "화"), (4, "수"), (5, "목"), (6, "금"), (7, "토")]
    private let durations = TimePolicy.durationOptionsMinutes

    /// 시작 30분 전 편집 잠금
    private var isLocked: Bool {
        guard let r = reservation, let next = r.nextOccurrence() else { return false }
        return next.timeIntervalSinceNow <= 1800
    }

    /// 활동 슬롯 현황 (원띵 — 신규 생성 화면에만). 탭하면 정책 표 팝업.
    private var slotPolicyNotice: some View {
        let used = allReservations.count
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
                    if isLocked {
                        lockNotice
                    }
                    if reservation == nil {
                        slotPolicyNotice
                    }
                    nameSection
                    tagSection
                    timeSection
                    repeatSection
                    if reservation != nil {
                        Button("예약 삭제") { showDeleteConfirm = true }
                            .buttonStyle(TLGhostButtonStyle(tint: TL.rec))
                            .disabled(isLocked)
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
                    Button("저장") { save() }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(isLocked ? TL.faint : TL.rec)
                        .disabled(isLocked)
                }
            }
            .confirmationDialog("이 예약을 삭제할까요?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("삭제", role: .destructive) { delete() }
            }
            .sheet(isPresented: $showSlotPolicy) {
                SlotPolicySheet(currentStreak: currentStreak, usedSlots: allReservations.count,
                                isMember: subscription.isPro)
                    .presentationDetents([.medium, .large])
            }
            .onAppear(perform: load)
            }   // ScrollViewReader
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 섹션

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

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TLEyebrow(text: "활동명 (필수)")
            TextField("예: 기출문제 3회분", text: $name)
                .font(.tlBody)
                .padding(14)
                .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerM))
                .disabled(isLocked)
        }
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TLEyebrow(text: "태그")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ActivityTag.presets, id: \.self) { preset in
                        Button { tag = preset; customTag = "" } label: {
                            TagChip(name: preset, selected: tag == preset && customTag.isEmpty)
                        }
                        .disabled(isLocked)
                    }
                }
            }
            TextField("직접 입력", text: $customTag)
                .font(.system(size: 14))
                .padding(10)
                .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerS))
                .disabled(isLocked)
                .onChange(of: customTag) { _, newValue in
                    if !newValue.trimmingCharacters(in: .whitespaces).isEmpty { tag = newValue }
                }
        }
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TLEyebrow(text: "시작 시각 · 활동 시간")
            TLCard {
                VStack(spacing: 4) {
                    DatePicker("시작 시각", selection: $startTime, displayedComponents: .hourAndMinute)
                        .font(.tlBody).foregroundStyle(TL.paper)
                        .disabled(isLocked)
                    Divider().overlay(TL.hairline)
                    HStack(spacing: 10) {
                        Picker("활동 시간", selection: $durationMinutes) {
                            ForEach(durations, id: \.self) { Text(TLFormat.durationLabel($0)).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(TL.paper)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(isLocked)
                        // 선택한 길이의 완주 상점 미리 보기
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

    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TLEyebrow(text: "반복")
            TLCard {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $isRepeating) {
                        Text("요일 반복").font(.tlBody).foregroundStyle(TL.paper)
                    }
                    .tint(TL.rec)
                    .disabled(isLocked)

                    if isRepeating {
                        HStack(spacing: 8) {
                            ForEach(weekdaySymbols, id: \.0) { (value, label) in
                                Button {
                                    if weekdays.contains(value) { weekdays.remove(value) }
                                    else { weekdays.insert(value) }
                                } label: {
                                    Text(label)
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(weekdays.contains(value) ? TL.ink : TL.muted)
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(weekdays.contains(value) ? TL.paper : TL.surface))
                                        .overlay(Circle().strokeBorder(weekdays.contains(value) ? .clear : TL.hairline))
                                }
                                .disabled(isLocked)
                            }
                        }
                    } else {
                        DatePicker("날짜", selection: $oneOffDate, in: Date()..., displayedComponents: .date)
                            .font(.tlBody).foregroundStyle(TL.paper)
                            .disabled(isLocked)
                    }
                }
            }
        }
    }

    // MARK: 로직

    private func load() {
        guard let r = reservation else { return }
        name = r.name
        tag = r.tag
        if !ActivityTag.presets.contains(r.tag) { customTag = r.tag }
        durationMinutes = r.durationMinutes
        let base = Calendar.current.startOfDay(for: .now)
        startTime = Calendar.current.date(byAdding: .minute, value: r.startMinute, to: base) ?? .now
        isRepeating = r.isRepeating
        weekdays = Set(r.repeatWeekdays)
        oneOffDate = r.oneOffDate ?? .now
    }

    private func save() {
        errorMessage = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        // 검증: 활동 슬롯 정책 (신규 생성만) — 연속 달성일 사다리. 기존 예약은 영향 없음.
        if reservation == nil, let allowed = allowedSlots, allReservations.count >= allowed {
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
        // 검증: 반복이면 요일 최소 1개
        if isRepeating && weekdays.isEmpty {
            errorMessage = "반복할 요일을 선택하세요."
            return
        }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        let startMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        // 검증: 일회성이면 미래 시각
        if !isRepeating {
            let dayStart = Calendar.current.startOfDay(for: oneOffDate)
            let fire = Calendar.current.date(byAdding: .minute, value: startMinute, to: dayStart) ?? .now
            guard fire > .now else {
                errorMessage = "이미 지난 시각입니다. 미래의 시각을 선택하세요."
                return
            }
        }
        // 검증: 겹치는 시간대 차단
        let targetWeekdays: Set<Int> = isRepeating
            ? weekdays
            : [Calendar.current.component(.weekday, from: oneOffDate)]
        for other in allReservations where other.id != reservation?.id {
            let otherWeekdays: Set<Int> = other.isRepeating
                ? Set(other.repeatWeekdays)
                : Set([other.oneOffDate.map { Calendar.current.component(.weekday, from: $0) } ?? -1])
            // 일회성끼리는 같은 날짜일 때만 충돌
            if !isRepeating && !other.isRepeating {
                guard let d = other.oneOffDate,
                      Calendar.current.isDate(d, inSameDayAs: oneOffDate) else { continue }
            } else {
                guard !targetWeekdays.isDisjoint(with: otherWeekdays) else { continue }
            }
            if other.overlaps(startMinute: startMinute, duration: durationMinutes) {
                errorMessage = "\(TLFormat.clock(clockDate(other.startMinute))) '\(other.name)' 예약과 시간이 겹칩니다."
                return
            }
        }

        let finalTag = customTag.trimmingCharacters(in: .whitespaces).isEmpty ? tag : customTag
        if let r = reservation {
            r.name = trimmedName
            r.tag = finalTag
            r.startMinute = startMinute
            r.durationMinutes = durationMinutes
            r.repeatWeekdays = isRepeating ? Array(weekdays) : []
            r.oneOffDate = isRepeating ? nil : Calendar.current.startOfDay(for: oneOffDate)
        } else {
            let r = Reservation(name: trimmedName, tag: finalTag,
                                startMinute: startMinute, durationMinutes: durationMinutes,
                                repeatWeekdays: isRepeating ? Array(weekdays) : [],
                                oneOffDate: isRepeating ? nil : Calendar.current.startOfDay(for: oneOffDate),
                                ownerUserID: account.currentUserID)
            context.insert(r)
        }
        try? context.save()
        rescheduleAlarms()
        dismiss()
    }

    private func delete() {
        guard let r = reservation, !isLocked else { return }
        r.isActive = false
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

// MARK: - 활동 슬롯 정책 팝업 (단계표)

private struct SlotPolicySheet: View {
    let currentStreak: Int
    let usedSlots: Int
    let isMember: Bool
    @Environment(\.dismiss) private var dismiss

    /// 표 행: (라벨, 연속일 하한, 슬롯 표기)
    private let rows: [(label: String, minDays: Int, slots: String)] = [
        ("기본",       0,  "2개"),
        ("연속 3일",   3,  "3개"),
        ("연속 5일",   5,  "4개"),
        ("연속 7일",   7,  "5개"),
        ("연속 10일", 10,  "10개"),
        ("연속 30일", 30,  "무제한")
    ]

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
