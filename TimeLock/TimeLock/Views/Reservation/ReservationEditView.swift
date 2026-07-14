//
//  ReservationEditView.swift
//  TimeLock
//
//  활동 예약 생성/조회/수정/삭제.
//  - 활동명(필수)/태그/시작 시각/지속 시간(10분~8시간)/반복(요일·일회성)
//  - 겹치는 시간대 예약은 저장 차단 + 충돌 메시지
//  - 시작 30분 전부터 수정/삭제 잠금
//

import SwiftUI
import SwiftData

struct ReservationEditView: View {
    let reservation: Reservation?   // nil = 생성

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var account: AccountStore
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Reservation> { $0.isActive }) private var allActiveReservations: [Reservation]

    /// 겹침 검사는 현재 계정의 예약끼리만
    private var allReservations: [Reservation] {
        allActiveReservations.filter { $0.ownerUserID == account.currentUserID }
    }

    @State private var name = ""
    @State private var tag = ActivityTag.presets[0]
    @State private var customTag = ""
    @State private var startTime = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
    @State private var durationMinutes = 60
    @State private var isRepeating = false
    @State private var weekdays: Set<Int> = []
    @State private var oneOffDate = Date()
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false

    private let weekdaySymbols = [(1, "일"), (2, "월"), (3, "화"), (4, "수"), (5, "목"), (6, "금"), (7, "토")]
    private let durations = [10, 15, 25, 30, 45, 60, 90, 120, 150, 180, 240, 300, 360, 480]

    /// 시작 30분 전 편집 잠금
    private var isLocked: Bool {
        guard let r = reservation, let next = r.nextOccurrence() else { return false }
        return next.timeIntervalSinceNow <= 1800
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if isLocked {
                        lockNotice
                    }
                    nameSection
                    tagSection
                    timeSection
                    repeatSection
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TL.rec)
                    }
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
            .onAppear(perform: load)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 섹션

    private var lockNotice: some View {
        TLCard {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(TL.amber)
                Text("시작 30분 전입니다. 자기계약을 지키기 위해 이 예약은 더 이상 수정하거나 삭제할 수 없습니다.")
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
            TLEyebrow(text: "시작 시각 · 지속 시간")
            TLCard {
                VStack(spacing: 4) {
                    DatePicker("시작 시각", selection: $startTime, displayedComponents: .hourAndMinute)
                        .font(.tlBody).foregroundStyle(TL.paper)
                        .disabled(isLocked)
                    Divider().overlay(TL.hairline)
                    Picker("지속 시간", selection: $durationMinutes) {
                        ForEach(durations, id: \.self) { Text(TLFormat.durationLabel($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(TL.paper)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(isLocked)
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
