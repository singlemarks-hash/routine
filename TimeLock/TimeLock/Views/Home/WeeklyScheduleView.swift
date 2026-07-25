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
    @Query private var allSessions: [FocusSession]

    @State private var editorTarget: EditorTarget?
    @State private var groupRoomToOpen: GroupRoom?
    /// 1분마다 갱신 — 시작 창이 닫히는 순간 행이 저절로 '지나감'으로 바뀌게 한다.
    /// 퍼블리셔를 let으로 두면 뷰가 재생성될 때마다 새로 만들어져 구독이 리셋되고,
    /// 상위(AppState)가 30초마다 갱신을 밀어넣는 이 화면에서는 60초 타이머가 영영 안 터진다.
    @State private var now = Date()
    @State private var clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

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
                        laterSection
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
            .onReceive(clock) { now = $0 }
        }
    }

    // MARK: 오늘 행 상태 (지나감 처리 + 결과 표시등)

    /// 오늘 칸의 한 행이 어떤 상태인지. 오늘이 아닌 날(내일 이후)은 항상 `.upcoming`이다.
    /// '촬영 중' 상태는 두지 않는다 — 촬영 중과 재촬영 창에서는 세션 화면이 전체를 덮어
    /// 이 화면에 올 수 없고, 앱이 죽어 남은 기록은 실행 즉시 고아 복구가 마감한다.
    private enum RowState {
        case upcoming            // 아직 시작 창이 열려 있거나 미래 날짜
        case done(SessionOutcome)
        case missed              // 시작 창이 닫혔는데 아직 결과 기록이 없음 (노쇼 확정 전)

        /// 지나간 일정으로 흐리게 처리할 것인가
        var isPast: Bool {
            switch self {
            case .upcoming:        return false
            case .done, .missed:   return true
            }
        }
        /// 태그 왼쪽 표시등 색 — 성공 초록 / 실패·노쇼 빨강 / 중립(긴급·안전 종료) 호박.
        /// 아직 결과가 확정되지 않은 상태는 표시등을 켜지 않는다.
        var lightColor: Color? {
            switch self {
            case .upcoming, .missed: return nil
            case .done(let outcome):
                if outcome.isSuccess { return TL.jade }
                if outcome.isFailure { return TL.rec }
                return TL.amber
            }
        }
    }

    /// 그 예약의 그 날짜에 확정된 결과. 하루에 기록이 여럿 남을 수 있어(긴급 중단 후 재촬영)
    /// 결과가 들어 있는 기록만 본다.
    private func outcome(for reservation: Reservation, on date: Date) -> SessionOutcome? {
        let cal = Calendar.current
        let rid = reservation.id
        let owner = account.currentUserID
        // @Query에 정렬이 없어 first를 쓰면 순서가 보장되지 않는다 —
        // 긴급 종료 뒤 재촬영해 완주한 날에 호박불이 뜰 수 있으므로 '가장 나중 기록'을 고른다.
        return allSessions.filter { s in
            s.ownerUserID == owner && s.reservationID == rid && s.outcome != nil &&
            (s.scheduledAt.map { cal.isDate($0, inSameDayAs: date) } ?? false)
        }
        .max { a, b in
            (a.endedAt ?? a.startedAt ?? .distantPast) < (b.endedAt ?? b.startedAt ?? .distantPast)
        }?.outcome
    }

    private func rowState(_ reservation: Reservation, on date: Date, fire: Date) -> RowState {
        // 미래 날짜는 판정 대상이 아니다 — 주간 표는 오늘부터 6일 뒤까지만 보여준다.
        guard Calendar.current.isDateInToday(date) else { return .upcoming }
        if let outcome = outcome(for: reservation, on: date) { return .done(outcome) }
        // 결과 기록이 없어도 시작 창(10분)이 닫혔으면 더 이상 할 수 없는 일정이다.
        // 노쇼 기록은 앱을 켤 때 스윕이 채우므로, 그 전까지는 표시등 없이 흐리게만 둔다.
        return now > fire.addingTimeInterval(TimePolicy.startWindowSeconds) ? .missed : .upcoming
    }

    // MARK: 요일 섹션

    /// 오늘로부터 offset일 뒤 날짜 (요일 순환 순서와 1:1).
    private func date(forOffset offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: .now)) ?? .now
    }

    /// 그 날 실제로 알람이 울리는 예약만 — 알람시계 로직(occurrence) 한 곳으로 판정한다.
    /// 요일/일회성 매칭 + 시작일(createdAt) 전·종료일(endDate) 후 자동 제외까지 여기서 함께 처리된다.
    /// 그룹 예약도 (참여자 미달로 폭파될 수 있어도) 활동 기간 안이면 일정에 넣어 계획을 관리하게 한다 —
    /// 실제 폭파되면 GroupStore가 예약을 DB에서 제거한다.
    private func items(on weekday: Int, date: Date) -> [DayItem] {
        reservations
            .compactMap { r in r.occurrence(on: date).map { DayItem(reservation: r, fire: $0) } }
            .sorted { $0.reservation.startMinute < $1.reservation.startMinute }
    }

    /// 한 날짜 칸의 행 하나 — 예약과 '그 날 울리는 시각'을 함께 들고 다닌다.
    /// (지나감 판정에 발생 시각이 필요해서 예약만으로는 부족하다)
    private struct DayItem: Identifiable {
        let reservation: Reservation
        let fire: Date
        var id: UUID { reservation.id }
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
                // 표시등이 하나라도 켜진 날에만 범례를 붙인다 — 색만 보고 헷갈리지 않게.
                if isToday, dayItems.contains(where: {
                    if case .done = rowState($0.reservation, on: date, fire: $0.fire) { return true }
                    return false
                }) {
                    HStack(spacing: 8) {
                        legendDot(TL.jade, "완주")
                        legendDot(TL.rec, "실패")
                    }
                }
            }

            if dayItems.isEmpty {
                Text("일정 없음")
                    .font(.system(size: 12)).foregroundStyle(TL.faint)
                    .padding(.vertical, 6)
                    .padding(.leading, 2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(dayItems.enumerated()), id: \.element.id) { index, item in
                        timetableRow(item.reservation,
                                     state: rowState(item.reservation, on: date, fire: item.fire))
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

    /// 행을 눌렀을 때 — 그룹 예약은 편집 대신 그 그룹방 상세로 이동
    private func open(_ reservation: Reservation) {
        if reservation.isGroupReservation {
            if let gid = reservation.groupID,
               let room = GroupStore.shared.rooms.first(where: { $0.id == gid }) {
                groupRoomToOpen = room
            }
        } else {
            editorTarget = .edit(reservation)
        }
    }

    // MARK: 이후 예정 — 주간 표(오늘~6일 뒤)에 한 번도 안 나오는 활동

    /// 시작일을 다음 주 이후로 잡은 활동은 주간 표 어디에도 안 뜨는데 슬롯은 차지한다.
    /// 그러면 "슬롯이 가득 찼다"거나 "이 활동과 시간이 겹친다"는 말만 듣고, 정작 그 활동을
    /// 찾아 고치거나 지울 방법이 없다. 여기에 모아 진입 경로를 만든다.
    private var laterItems: [DayItem] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let horizon = cal.date(byAdding: .day, value: 7, to: today) else { return [] }
        return reservations.compactMap { reservation -> DayItem? in
            for offset in 0..<7 {
                guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
                // 이번 주에 한 번이라도 발생하면 이미 위 표에 있다
                if reservation.occurrence(on: day) != nil { return nil }
            }
            // nextOccurrence는 'date보다 뒤'만 반환한다. horizon(=today+7의 자정)을 그대로 주면
            // 자정 정각(00:00) 발생이 걸러져, 주간 표에도 없고 여기에도 없는 활동이 생긴다.
            guard let fire = reservation.nextOccurrence(after: horizon.addingTimeInterval(-1))
            else { return nil }
            return DayItem(reservation: reservation, fire: fire)
        }
        .sorted { $0.fire < $1.fire }
    }

    @ViewBuilder
    private var laterSection: some View {
        let items = laterItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("이후 예정").font(.tlTitle(16)).foregroundStyle(TL.paper)
                    Text("이번 주에는 없어요")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(TL.muted)
                    Spacer()
                }
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        laterRow(item)
                        if index < items.count - 1 {
                            Divider().overlay(TL.hairline.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
                        .strokeBorder(TL.hairline.opacity(0.6), lineWidth: 1)
                )
            }
        }
    }

    private func laterRow(_ item: DayItem) -> some View {
        let cal = Calendar.current
        let month = cal.component(.month, from: item.fire)
        let day = cal.component(.day, from: item.fire)
        let weekday = weekdayNames[cal.component(.weekday, from: item.fire)] ?? ""
        let dday = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                      to: cal.startOfDay(for: item.fire)).day ?? 0
        return Button {
            open(item.reservation)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(month)월 \(day)일")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(TL.paper)
                    Text(String(weekday.prefix(1)))
                        .font(.system(size: 11)).foregroundStyle(TL.muted)
                }
                .frame(width: 74, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if item.reservation.isGroupReservation {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 10)).foregroundStyle(TL.amber)
                        }
                        Text(item.reservation.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TL.paper).lineLimit(1)
                    }
                    Text("\(timeLabel(item.reservation.startMinute)) · \(TLFormat.durationLabel(item.reservation.durationMinutes)) · \(item.reservation.repeatLabel())")
                        .font(.system(size: 11)).foregroundStyle(TL.muted)
                }
                Spacer()
                Text("D-\(dday)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(TL.ink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(TL.amber))
                TagChip(name: item.reservation.tag)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func timetableRow(_ reservation: Reservation, state: RowState) -> some View {
        Button {
            open(reservation)
        } label: {
            HStack(spacing: 12) {
                // 지나간 일정은 통째로 흐리게 — 오늘 남은 일정과 한눈에 구분된다.
                // 결과 표시등만 원래 밝기를 유지해 성공/실패를 바로 읽을 수 있게 한다.
                Group {
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
                        Text("\(TLFormat.durationLabel(reservation.durationMinutes)) · \(reservation.repeatLabel())")
                            .font(.system(size: 11)).foregroundStyle(TL.muted)
                    }
                    Spacer()
                }
                .opacity(state.isPast ? 0.42 : 1)

                if let color = state.lightColor {
                    outcomeLight(color)
                }
                TagChip(name: reservation.tag)
                    .opacity(state.isPast ? 0.55 : 1)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(TL.faint)
        }
    }

    /// 결과 표시등 — 태그 왼쪽의 작은 원. 흐려진 행에서도 눈에 들어오도록 옅은 후광을 준다.
    private func outcomeLight(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 4))
            .frame(width: 16, height: 16)
    }

    private func timeLabel(_ minute: Int) -> String {
        let h = minute / 60, m = minute % 60
        let isPM = h >= 12
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(isPM ? "오후" : "오전") \(h12):\(String(format: "%02d", m))"
    }

}
