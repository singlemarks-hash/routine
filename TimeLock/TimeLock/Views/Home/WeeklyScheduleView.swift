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
    /// 결과 표시등에 쓸 기록.
    ///
    /// 날짜 조건을 조회문에 넣으려면 옵셔널 Date를 비교해야 하는데, SwiftData가 그 술어를
    /// 실기기에서만 실패시키는 사례가 보고돼 있다. 실패하면 결과가 조용히 비어 표시등이
    /// 통째로 사라지고, 시뮬레이터 CI로는 잡을 수 없다. 그래서 조회는 '예약 세션'까지만
    /// 좁히고 날짜는 아래 todayOutcomes에서 한 번에 거른다 — 행마다 훑던 것이 1회로 줄어
    /// 실제 비용의 대부분은 이미 사라진다.
    @Query(filter: #Predicate<FocusSession> { $0.scheduledAt != nil })
    private var allSessions: [FocusSession]

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

    /// 1(일)~7(토) → 요일 전체 이름 — 로케일 심볼 (ko: 일요일 / en: Sunday)
    private let weekdayNames = Dictionary(uniqueKeysWithValues:
        (1...7).map { ($0, TLFormat.weekdayFullSymbol($0)) })

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
                        let outcomes = todayOutcomes   // 표를 한 번만 만들어 모든 칸이 나눠 쓴다
                        ForEach(Array(weekdayOrder.enumerated()), id: \.element) { offset, weekday in
                            daySection(weekday, date: date(forOffset: offset), outcomes: outcomes)
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
        /// 태그 왼쪽 표시등 색 — 성공은 초록, 그 외는 전부 빨강. 두 가지뿐이다.
        /// 긴급 종료(일정 취소 포함)는 물론, 안전 종료(기기 사정으로 무효 처리)도 빨강이다 —
        /// 무효는 '벌점화만 안 되는 것'이지 완주하지 못한 사실은 같다. 중간색·무표시를 두면
        /// '성공인지 실패인지 한눈에'라는 표시등의 목적이 흐려진다.
        var lightColor: Color? {
            switch self {
            case .upcoming, .missed: return nil
            case .done(let outcome):
                return outcome.isSuccess ? TL.jade : TL.rec
            }
        }
    }

    /// 오늘 확정된 결과를 '예약별로 한 번만' 표로 만든다.
    /// 행마다 전체 기록을 훑으면 행 수만큼 스캔이 반복되고, 그게 타이머마다 되풀이된다.
    /// 하루에 기록이 여럿 남을 수 있어(긴급 중단 후 재촬영) 가장 나중 것을 남긴다.
    private var todayOutcomes: [UUID: SessionOutcome] {
        let cal = Calendar.current
        let owner = account.currentUserID
        var map: [UUID: (at: Date, outcome: SessionOutcome)] = [:]
        for session in allSessions {
            guard session.ownerUserID == owner,
                  let rid = session.reservationID,
                  let outcome = session.outcome,
                  let scheduled = session.scheduledAt, cal.isDateInToday(scheduled) else { continue }
            let at = session.endedAt ?? session.startedAt ?? .distantPast
            if let existing = map[rid], existing.at >= at { continue }
            map[rid] = (at, outcome)
        }
        return map.mapValues { $0.outcome }
    }

    private func rowState(_ item: DayItem, on date: Date,
                          outcomes: [UUID: SessionOutcome]) -> RowState {
        // 미래 날짜는 판정 대상이 아니다 — 주간 표는 오늘부터 6일 뒤까지만 보여준다.
        guard Calendar.current.isDateInToday(date) else { return .upcoming }
        if let outcome = outcomes[item.reservation.id] { return .done(outcome) }
        // 결과 기록이 없어도 시작 창(10분)이 닫혔으면 더 이상 할 수 없는 일정이다.
        // 노쇼 기록은 앱을 켤 때 스윕이 채우므로, 그 전까지는 표시등 없이 흐리게만 둔다.
        return now > item.fire.addingTimeInterval(TimePolicy.startWindowSeconds) ? .missed : .upcoming
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

    /// 한 행의 표시 상태까지 확정한 값 — 범례 판정과 렌더가 같은 계산을 두 번 하지 않게 한다.
    private struct Row: Identifiable {
        let item: DayItem
        let state: RowState
        var id: UUID { item.id }
    }

    @ViewBuilder
    private func daySection(_ weekday: Int, date: Date,
                            outcomes: [UUID: SessionOutcome]) -> some View {
        let rows = items(on: weekday, date: date).map {
            Row(item: $0, state: rowState($0, on: date, outcomes: outcomes))
        }
        let isToday = weekday == todayWeekday

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(weekdayNames[weekday] ?? "")
                    .font(.tlTitle(16))
                    .foregroundStyle(isToday ? TL.rec : TL.paper)
                // 실제 날짜 병기 — 미래 단발성 예약도 어느 날인지 바로 확인. 예) "토요일 (7월 25일)"
                Text("(\(TLFormat.monthDay(date)))")
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
                if isToday, rows.contains(where: {
                    if case .done = $0.state { return true }
                    return false
                }) {
                    HStack(spacing: 8) {
                        legendDot(TL.jade, "완주")
                        legendDot(TL.rec, "실패")
                    }
                }
            }

            if rows.isEmpty {
                Text("일정 없음")
                    .font(.system(size: 12)).foregroundStyle(TL.faint)
                    .padding(.vertical, 6)
                    .padding(.leading, 2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        timetableRow(row.item.reservation, state: row.state)
                        if index < rows.count - 1 {
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

    /// 미친 매운맛만 표시 — 매운맛(기본값)은 무표기라 목록이 조용하다.
    private func isInsane(_ reservation: Reservation) -> Bool {
        (reservation.intensityOverride ?? app.intensity) == .insane
    }

    private func laterRow(_ item: DayItem) -> some View {
        let cal = Calendar.current
        let weekdayShort = TLFormat.weekdaySymbol(cal.component(.weekday, from: item.fire))
        let dday = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                      to: cal.startOfDay(for: item.fire)).day ?? 0
        return Button {
            open(item.reservation)
        } label: {
            // spacing 6 — 제목이 잘릴 때 이모지·아이콘과 태그 사이 최소 간격.
            // 한 글자라도 더 보이는 쪽을 택했다. 시각 칸은 74pt 고정 폭 왼쪽 정렬이라
            // 이 값이 줄어도 시각↔제목 간격은 체감 변화가 없다.
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TLFormat.monthDay(item.fire))
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(TL.paper)
                    Text(weekdayShort)
                        .font(.system(size: 11)).foregroundStyle(TL.muted)
                }
                .frame(width: 74, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(item.reservation.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TL.paper).lineLimit(1)
                        if isInsane(item.reservation) {
                            Text("🔥").font(.system(size: 12)).layoutPriority(1)
                        }
                        if item.reservation.isGroupReservation {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 10)).foregroundStyle(TL.amber)
                                .layoutPriority(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(timeLabel(item.reservation.startMinute)) · \(TLFormat.durationLabel(item.reservation.durationMinutes)) · \(item.reservation.repeatLabel())")
                        .font(.system(size: 11)).foregroundStyle(TL.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
            // spacing 6 — laterRow와 동일. 제목이 잘릴 때 이모지·아이콘과 태그 사이
            // 최소 간격을 좁혀 제목 글자를 한 자라도 더 보여준다.
            HStack(spacing: 6) {
                // 지나간 일정은 통째로 흐리게 — 오늘 남은 일정과 한눈에 구분된다.
                // 결과 표시등만 원래 밝기를 유지해 성공/실패를 바로 읽을 수 있게 한다.
                Group {
                    Text(timeLabel(reservation.startMinute))
                        .font(.tlTimer(14))
                        .foregroundStyle(TL.paper)
                        .frame(width: 74, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(reservation.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(TL.paper)
                                .lineLimit(1)
                            if isInsane(reservation) {
                                Text("🔥").font(.system(size: 12)).layoutPriority(1)
                            }
                            if reservation.isGroupReservation {
                                Image(systemName: "person.3.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(TL.amber)
                                    .layoutPriority(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(TLFormat.durationLabel(reservation.durationMinutes)) · \(reservation.repeatLabel())")
                            .font(.system(size: 11)).foregroundStyle(TL.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
