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

    @State private var editorTarget: EditorTarget?
    @State private var groupRoomToOpen: GroupRoom?

    /// 편집 시트 대상 — .sheet(item:)으로 열어 항상 정확한 예약을 전달한다.
    /// (.sheet(isPresented:)+별도 @State는 시트가 옛 값(nil)을 캡처해 '새 예약 빈 폼'으로
    ///  뜨는 SwiftUI 타이밍 버그가 있었다.)
    private enum EditorTarget: Identifiable {
        case new
        case edit(Reservation)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let r): return r.id.uuidString
            }
        }
        var reservation: Reservation? {
            if case .edit(let r) = self { return r }
            return nil
        }
    }

    private var reservations: [Reservation] {
        allActiveReservations.filter { $0.ownerUserID == account.currentUserID }
    }

    private let weekdayNames = [1: "일요일", 2: "월요일", 3: "화요일", 4: "수요일",
                                5: "목요일", 6: "금요일", 7: "토요일"]

    private var todayWeekday: Int { Calendar.current.component(.weekday, from: .now) }

    /// 표시 순서 — 오늘 요일을 맨 위에 두고 요일 순으로 순환.
    /// (Calendar.weekday: 1=일 … 7=토) 예) 오늘이 토(7)면 토·일·월·화·수·목·금, 화(3)면 화·수·목·금·토·일·월.
    private var weekdayOrder: [Int] {
        (0..<7).map { ((todayWeekday - 1 + $0) % 7) + 1 }
    }

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
                        ForEach(Array(weekdayOrder.enumerated()), id: \.element) { offset, weekday in
                            daySection(weekday, date: date(forOffset: offset))
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
                    // 시스템 기본 툴바 버튼 하나만 — 커스텀 캡슐을 얹으면 iOS가 씌우는
                    // 툴바 배경(iOS 26 글래스)과 겹쳐 '프레임 2겹'으로 보인다. 네이티브 칩 하나로 간다.
                    Button {
                        editorTarget = .new
                    } label: {
                        Label("추가", systemImage: "plus")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .tint(TL.paper)
                }
            }
            .sheet(item: $editorTarget) { target in
                ReservationEditView(reservation: target.reservation)
            }
            .navigationDestination(item: $groupRoomToOpen) { room in
                GroupRoomDetailView(room: room)
            }
        }
    }

    // MARK: 요일 섹션

    /// 오늘로부터 offset일 뒤 날짜 (요일 순환 순서와 1:1).
    private func date(forOffset offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: .now)) ?? .now
    }

    /// 반복 예약은 요일 매칭, 일회성 예약은 그 날짜(date)와 정확히 같은 날만 — 미래 단발성도 제 날짜에 표시.
    private func items(on weekday: Int, date: Date) -> [Reservation] {
        reservations.filter { r in
            if r.isRepeating { return r.repeatWeekdays.contains(weekday) }
            if let d = r.oneOffDate { return Calendar.current.isDate(d, inSameDayAs: date) }
            return false
        }
        .sorted { $0.startMinute < $1.startMinute }
    }

    @ViewBuilder
    private func daySection(_ weekday: Int, date: Date) -> some View {
        let dayItems = items(on: weekday, date: date)
        let isToday = weekday == todayWeekday

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(weekdayNames[weekday] ?? "")
                    .font(.tlTitle(16))
                    .foregroundStyle(isToday ? TL.rec : TL.paper)
                // 실제 날짜 병기 — 미래 단발성 예약도 어느 날인지 바로 확인. 예) "토요일 (7월 25일)"
                Text("(\(Calendar.current.component(.month, from: date))월 \(Calendar.current.component(.day, from: date))일)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TL.muted)
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
                editorTarget = .edit(reservation)
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
