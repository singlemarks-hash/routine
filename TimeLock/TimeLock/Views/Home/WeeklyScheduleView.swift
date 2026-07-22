//
//  WeeklyScheduleView.swift
//  TimeLock
//
//  일정 탭 — 월~일 주간 타임테이블. 요일별로 예약된 루틴을 시간순으로 보여준다.
//  반복 예약은 해당 요일마다, 일회성 예약은 그 날짜의 요일 칸에 표시된다.
//

import SwiftUI
import SwiftData

struct WeeklyScheduleView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var account: AccountStore
    @Query(filter: #Predicate<Reservation> { $0.isActive }, sort: \Reservation.startMinute)
    private var allActiveReservations: [Reservation]

    @State private var showEditor = false
    @State private var editing: Reservation?
    @State private var groupRoomToOpen: GroupRoom?

    private var reservations: [Reservation] {
        allActiveReservations.filter { $0.ownerUserID == account.currentUserID }
    }

    /// 월~일 표시 순서 (Calendar.weekday: 1=일 … 7=토)
    private let weekdayOrder: [Int] = [2, 3, 4, 5, 6, 7, 1]
    private let weekdayNames = [1: "일요일", 2: "월요일", 3: "화요일", 4: "수요일",
                                5: "목요일", 6: "금요일", 7: "토요일"]

    private var todayWeekday: Int { Calendar.current.component(.weekday, from: .now) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if reservations.isEmpty {
                        TLCard {
                            Text("아직 예약된 루틴이 없습니다. 우측 상단 +로 주간 루틴을 만들어 보세요.")
                                .font(.system(size: 13)).foregroundStyle(TL.muted)
                        }
                    } else {
                        ForEach(weekdayOrder, id: \.self) { weekday in
                            daySection(weekday)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 116)   // 하단 토글 자리
            }
            .background(TL.ink)
            .navigationTitle("주간 일정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = nil
                        showEditor = true
                    } label: {
                        // 아이콘만이 아니라 '+ 추가' 라벨 (안드로이드와 통일)
                        HStack(spacing: 3) {
                            Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                            Text("추가").font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(TL.paper)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(TL.surface))
                        .overlay(Capsule().strokeBorder(TL.hairline, lineWidth: 1))
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                ReservationEditView(reservation: editing)
            }
            .navigationDestination(item: $groupRoomToOpen) { room in
                GroupRoomDetailView(room: room)
            }
        }
    }

    // MARK: 요일 섹션

    private func items(on weekday: Int) -> [Reservation] {
        reservations.filter { r in
            if r.isRepeating { return r.repeatWeekdays.contains(weekday) }
            if let date = r.oneOffDate {
                return Calendar.current.component(.weekday, from: date) == weekday
            }
            return false
        }
        .sorted { $0.startMinute < $1.startMinute }
    }

    @ViewBuilder
    private func daySection(_ weekday: Int) -> some View {
        let dayItems = items(on: weekday)
        let isToday = weekday == todayWeekday

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(weekdayNames[weekday] ?? "")
                    .font(.tlTitle(16))
                    .foregroundStyle(isToday ? TL.rec : TL.paper)
                if isToday {
                    Text("오늘")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(TL.ink)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(TL.rec))
                }
                Spacer()
            }

            if dayItems.isEmpty {
                Text("일정 없음")
                    .font(.system(size: 12)).foregroundStyle(TL.faint)
                    .padding(.vertical, 6)
                    .padding(.leading, 2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(dayItems.enumerated()), id: \.element.id) { index, r in
                        timetableRow(r)
                        if index < dayItems.count - 1 {
                            Divider().overlay(TL.hairline.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
                        .fill(isToday ? TL.raised : TL.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
                        .strokeBorder(isToday ? TL.rec.opacity(0.35) : TL.hairline.opacity(0.6), lineWidth: 1)
                )
            }
        }
    }

    private func timetableRow(_ reservation: Reservation) -> some View {
        Button {
            if reservation.isGroupReservation {
                // 그룹 예약은 편집 대신 그 그룹방 상세로 이동
                if let gid = reservation.groupID,
                   let room = GroupStore.shared.rooms.first(where: { $0.id == gid }) {
                    groupRoomToOpen = room
                }
            } else {
                editing = reservation
                showEditor = true
            }
        } label: {
            HStack(spacing: 12) {
                Text(timeLabel(reservation.startMinute))
                    .font(.tlTimer(14))
                    .foregroundStyle(TL.paper)
                    .frame(width: 74, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if reservation.isGroupReservation {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(TL.amber)
                        }
                        Text(reservation.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TL.paper)
                            .lineLimit(1)
                    }
                    Text("\(TLFormat.durationLabel(reservation.durationMinutes))\(oneOffLabel(reservation))")
                        .font(.system(size: 11)).foregroundStyle(TL.muted)
                }
                Spacer()
                TagChip(name: reservation.tag)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func timeLabel(_ minute: Int) -> String {
        let h = minute / 60, m = minute % 60
        let isPM = h >= 12
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(isPM ? "오후" : "오전") \(h12):\(String(format: "%02d", m))"
    }

    private func oneOffLabel(_ r: Reservation) -> String {
        guard !r.isRepeating, let date = r.oneOffDate else { return " · 매주" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return " · \(f.string(from: date)) 하루"
    }
}
