//
//  HomeView.swift
//  TimeLock
//
//  오늘의 예약 타임라인 + 다음 활동 카운트다운 + 지금 바로 시작.
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var account: AccountStore
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Reservation> { $0.isActive }, sort: \Reservation.startMinute)
    private var allActiveReservations: [Reservation]

    /// 현재 계정의 예약만
    private var reservations: [Reservation] {
        allActiveReservations.filter { $0.ownerUserID == account.currentUserID }
    }

    @State private var now = Date()
    @State private var showEditor = false
    @State private var editing: Reservation?
    @State private var showQuickStart = false

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var todayItems: [(reservation: Reservation, fire: Date)] {
        reservations
            .compactMap { r in r.occurrence(on: now).map { (r, $0) } }
            .sorted { $0.1 < $1.1 }
    }

    private var nextItem: (reservation: Reservation, fire: Date)? {
        // 오늘 남은 것 중 첫 번째, 없으면 다음 발생
        if let today = todayItems.first(where: { $0.fire > now }) { return today }
        return reservations
            .compactMap { r in r.nextOccurrence(after: now).map { (r, $0) } }
            .sorted { $0.1 < $1.1 }
            .first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nextActivityCard
                    timelineSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(TL.ink)
            .navigationTitle("오늘")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = nil
                        showEditor = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(TL.paper)
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                ReservationEditView(reservation: editing)
            }
            .sheet(isPresented: $showQuickStart) {
                QuickStartSheet()
                    .presentationDetents([.height(420)])
            }
            .onReceive(clock) { now = $0 }
        }
    }

    // MARK: 다음 활동 카운트다운

    @ViewBuilder
    private var nextActivityCard: some View {
        if let next = nextItem {
            let remaining = Int(next.fire.timeIntervalSince(now))
            TLCard(raised: true) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TLEyebrow(text: "다음 활동", color: remaining <= 600 ? TL.amber : TL.muted)
                        Spacer()
                        TagChip(name: next.reservation.tag)
                    }
                    Text(next.reservation.name)
                        .font(.tlTitle(22))
                        .foregroundStyle(TL.paper)
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(countdownText(remaining))
                            .font(.tlTimer(40))
                            .foregroundStyle(remaining <= 600 ? TL.amber : TL.paper)
                        Text("뒤 알람")
                            .font(.tlBody)
                            .foregroundStyle(TL.muted)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "bell.fill").font(.system(size: 11))
                        Text("\(TLFormat.clock(next.fire)) · \(TLFormat.durationLabel(next.reservation.durationMinutes)) · \(TimePolicy.startWindowMinutes)분 내 촬영 시작")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(TL.muted)
                }
            }
        } else {
            TLCard {
                VStack(alignment: .leading, spacing: 10) {
                    TLEyebrow(text: "예약 없음")
                    Text("첫 자기계약을 만들어 보세요")
                        .font(.tlTitle(19)).foregroundStyle(TL.paper)
                    Text("활동을 예약하면 정시에 알람이 울리고, 알람을 끄는 방법은 촬영 시작뿐입니다.")
                        .font(.system(size: 14)).foregroundStyle(TL.muted)
                    Button("활동 예약하기") {
                        editing = nil
                        showEditor = true
                    }
                    .buttonStyle(TLPrimaryButtonStyle())
                    .padding(.top, 6)
                }
            }
        }

        Button {
            showQuickStart = true
        } label: {
            HStack {
                Image(systemName: "record.circle")
                    .font(.system(size: 17, weight: .semibold))
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
    }

    private func countdownText(_ seconds: Int) -> String {
        if seconds >= 86_400 { return "\(seconds / 86_400)일 \((seconds % 86_400) / 3600)시간" }
        return TLFormat.hms(seconds)
    }

    // MARK: 타임라인

    @ViewBuilder
    private var timelineSection: some View {
        if !todayItems.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                TLEyebrow(text: "오늘의 예약 타임라인")
                VStack(spacing: 0) {
                    ForEach(Array(todayItems.enumerated()), id: \.element.reservation.id) { index, item in
                        TimelineRow(reservation: item.reservation, fire: item.fire, now: now,
                                    isLast: index == todayItems.count - 1) {
                            editing = item.reservation
                            showEditor = true
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 타임라인 행

private struct TimelineRow: View {
    let reservation: Reservation
    let fire: Date
    let now: Date
    let isLast: Bool
    var onTap: () -> Void

    private var isPast: Bool { fire.addingTimeInterval(TimeInterval(reservation.durationMinutes * 60)) < now }
    private var isLocked: Bool { fire.timeIntervalSince(now) <= 1800 && fire > now }   // 30분 전 편집 잠금

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                // 레일
                VStack(spacing: 0) {
                    Circle()
                        .fill(isPast ? TL.faint : (isLocked ? TL.amber : TL.rec))
                        .frame(width: 9, height: 9)
                        .padding(.top, 6)
                    if !isLast {
                        Rectangle().fill(TL.hairline).frame(width: 1.5)
                    }
                }
                .frame(width: 12)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(TLFormat.clock(fire))
                            .font(.tlTimer(15))
                            .foregroundStyle(isPast ? TL.faint : TL.paper)
                        TagChip(name: reservation.tag)
                        Spacer()
                        if isLocked {
                            Label("편집 잠금", systemImage: "lock.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(TL.amber)
                        }
                    }
                    Text(reservation.name)
                        .font(.tlTitle(17))
                        .foregroundStyle(isPast ? TL.faint : TL.paper)
                    Text("\(TLFormat.durationLabel(reservation.durationMinutes))\(reservation.isRepeating ? " · 매주 " + weekdayLabel(reservation.repeatWeekdays) : "")")
                        .font(.system(size: 13))
                        .foregroundStyle(TL.muted)
                }
                .padding(.bottom, isLast ? 0 : 22)
            }
        }
        .buttonStyle(.plain)
    }

    private func weekdayLabel(_ weekdays: [Int]) -> String {
        let names = ["", "일", "월", "화", "수", "목", "금", "토"]
        return weekdays.sorted().map { names[$0] }.joined(separator: " ")
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
