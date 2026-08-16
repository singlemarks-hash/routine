//
//  CalendarView.swift
//  TimeLock
//
//  월간 성공캘린더: 날짜에 실패/노쇼가 하나라도 있으면 빨강, 모두 완주면 초록.
//  날짜 상세: 세션 기록(썸네일)·점수 내역·태그별 시간.
//  누적 대시보드: 총점, 완주율/노쇼율, 태그 분포, 스트릭.
//  정책: 타임랩스 원본은 세션 종료 화면에서 저장하지 않으면 삭제되므로
//  캘린더에는 재생·공유가 없고 기록만 남는다. 모든 데이터는 현재 계정 것만 보인다.
//

import SwiftUI
import SwiftData

struct CalendarView: View {
    @EnvironmentObject private var account: AccountStore
    @Query private var everySession: [FocusSession]
    @Query private var everyScoreEvent: [ScoreEvent]

    @State private var monthAnchor = Date()
    @State private var selectedDay: Date?

    private var calendar: Calendar { Calendar.current }

    /// 현재 계정의 기록만
    private var allSessions: [FocusSession] {
        everySession.filter { $0.ownerUserID == account.currentUserID }
    }
    private var scoreEvents: [ScoreEvent] {
        everyScoreEvent.filter { $0.ownerUserID == account.currentUserID }
    }

    // 홈 우상단 누적시간 배지에서 푸시되는 화면 — 자체 NavigationStack 없음
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StreakHeaderCard(sessions: allSessions)
                monthGrid
                DashboardSection(sessions: allSessions, scoreEvents: scoreEvents)
            }
            .padding(.horizontal, 20)
            // 하단 [활동|일정|그룹] 토글이 이 화면 위에도 떠 있다 — 여백이 모자라면
            // 누적 대시보드 끝이 토글에 가려 끝까지 스크롤되지 않는다 (홈과 동일한 116)
            .padding(.bottom, 116)
        }
        .background(TL.ink)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(
            get: { selectedDay.map(DayBox.init) },
            set: { selectedDay = $0?.date })) { box in
            DayDetailView(day: box.date,
                          sessions: sessions(on: box.date),
                          scoreEvents: scoreEvents)
        }
    }

    private struct DayBox: Identifiable {
        let date: Date
        var id: Date { date }
    }

    private func sessions(on day: Date) -> [FocusSession] {
        // 미종결(outcome nil — 크래시 직후 미복구 고아·동기화로 온 미종결 기록)은 제외한다.
        // 상세 성적표가 outcome을 완주로 폴백해 '지급된 적 없는 +10'을 그리는 사고 방지 —
        // 고아 복구가 곧 확정하면 그때 정상 표시된다.
        allSessions.filter { $0.outcome != nil && calendar.isDate($0.anchorDate, inSameDayAs: day) }
    }

    // MARK: 월간 그리드

    private var monthGrid: some View {
        VStack(spacing: 14) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left").foregroundStyle(TL.muted)
                        .frame(width: 32, height: 32)
                }
                .pressableStyle()
                Spacer()
                Text(monthTitle)
                    .font(.tlTitle(18))
                    .foregroundStyle(TL.paper)
                Spacer()
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right").foregroundStyle(TL.muted)
                        .frame(width: 32, height: 32)
                }
                .pressableStyle()
            }
            .padding(.horizontal, 4)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(TLFormat.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(TL.faint)
                }
                // 앞쪽 빈칸 nil이 여럿이라 값 기반 ID는 중복된다(SwiftUI 미정의 동작) — 위치 ID 사용
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
    }

    private func dayCell(_ day: Date) -> some View {
        let daySessions = sessions(on: day).filter { $0.outcome != nil }
        // 그날의 성취 아이콘 — 홈 연속달성 스트립과 같은 판정(DayOutcomeIcon) 하나를 쓴다.
        // 캘린더에서는 미시작/미래(notStarted)를 굳이 그리지 않는다 — 기록 있는 날만 아이콘.
        let judged = DayOutcomeIcon.judge(daySessions: daySessions, day: day)
        let icon: DayOutcomeIcon? = (judged == .notStarted) ? nil : judged
        let isToday = calendar.isDateInToday(day)

        return Button {
            if !daySessions.isEmpty { selectedDay = day }
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.tlTimer(14))
                    .foregroundStyle(isToday ? TL.paper : TL.muted)
                if let icon {
                    Image(icon.assetName)
                        .resizable().scaledToFit()
                        .frame(width: 17, height: 17)
                } else {
                    Circle().fill(TL.hairline.opacity(0.4)).frame(width: 4, height: 4)
                        .padding(.vertical, 6.5)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: TL.cornerS)
                    .fill(isToday ? TL.raised : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var monthTitle: String {
        let f = DateFormatter()
        if TLFormat.isKorean {
            f.locale = Locale(identifier: "ko_KR")
            f.dateFormat = "yyyy년 M월"   // l10n:ko-literal — ko 전용 날짜 패턴, 영원히 한글
        } else {
            f.locale = .autoupdatingCurrent
            f.setLocalizedDateFormatFromTemplate("yMMMM")   // "August 2026"
        }
        return f.string(from: monthAnchor)
    }

    private var monthDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let dayCount = calendar.range(of: .day, in: .month, for: monthAnchor)?.count ?? 30
        var days: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for offset in 0..<dayCount {
            days.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        return days
    }

    private func shiftMonth(_ delta: Int) {
        monthAnchor = calendar.date(byAdding: .month, value: delta, to: monthAnchor) ?? monthAnchor
    }
}

// MARK: - 날짜 상세

// 성적표 스타일: 시간순 내역 리스트 + 항목별 토글로 상세(썸네일·사유·순수 촬영시간) 열람.
// 상점·벌점은 운영자 평가 수단 — 회원이 삭제/수정할 수 없다(조회 전용).
struct DayDetailView: View {
    let day: Date
    let sessions: [FocusSession]
    let scoreEvents: [ScoreEvent]

    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<UUID> = []

    /// 시간순 정렬
    private var ordered: [FocusSession] {
        sessions.sorted { $0.anchorDate < $1.anchorDate }
    }

    private var dayReward: Int {
        ordered.compactMap { pts($0) }.filter { $0 > 0 }.reduce(0, +)
    }
    private var dayPenalty: Int {
        ordered.compactMap { pts($0) }.filter { $0 < 0 }.reduce(0, +)
    }
    private var allOpen: Bool { !ordered.isEmpty && expanded.count == ordered.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if ordered.isEmpty {
                        TLCard {
                            Text("No records for this day.")
                                .font(.system(size: 14)).foregroundStyle(TL.muted)
                        }
                    } else {
                        summaryHeader
                        TLCard {
                            VStack(spacing: 0) {
                                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, session in
                                    reportRow(session)
                                    if index < ordered.count - 1 {
                                        Divider().overlay(TL.hairline.opacity(0.5))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(TL.ink)
            .navigationTitle(TLFormat.dayTitle(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !ordered.isEmpty {
                        // 고정 폭 — '모두 접기'↔'모두 펼치기' 글자 수 차이로 버튼이 움직이지 않게.
                        // 전체 전환은 애니메이션 없이 즉시 (개별 토글만 부드럽게).
                        Button {
                            expanded = allOpen ? [] : Set(ordered.map(\.id))
                        } label: {
                            // 가장 긴 라벨로 폭을 잡고 가운데 정렬한다 — 고정 폭 + 왼쪽 정렬은
                            // 짧은 문구('모두 접기')일 때 오른쪽에 빈 자리가 남아 버튼이 비뚤어 보였다.
                            ZStack {
                                Text("Expand All").hidden()   // 폭 기준(보이지 않음)
                                Text(allOpen ? "Collapse All" : "Expand All")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TL.muted)
                            .lineLimit(1)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.foregroundStyle(TL.muted)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 상단 합계 (성적표 헤더)

    private var summaryHeader: some View {
        HStack(spacing: 10) {
            summaryChip(value: "+\(dayReward)", label: String(localized: "Points"), tint: TL.jade)
            summaryChip(value: "\(dayPenalty)", label: String(localized: "Penalty"), tint: TL.rec)
            summaryChip(value: "\(dayReward + dayPenalty)", label: String(localized: "Total"),
                        tint: dayReward + dayPenalty >= 0 ? TL.paper : TL.rec)
        }
    }

    private func summaryChip(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.tlTimer(20)).foregroundStyle(tint)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(TL.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous).fill(TL.surface))
    }

    // MARK: 내역 행 (접힘: 원·시간·활동·점수 / 펼침: 썸네일·사유·순수촬영)

    private func reportRow(_ session: FocusSession) -> some View {
        let outcome = session.outcome ?? .completed
        let isOpen = expanded.contains(session.id)
        let points = pts(session)

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                // 성취 원 — 성공 초록 / 실패 빨강 / 그 외(긴급·안전) 앰버
                Circle()
                    .fill(circleColor(outcome))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(circleColor(outcome).opacity(0.35), lineWidth: 3))
                Text(TLFormat.clock(session.anchorDate))
                    .font(.tlTimer(14)).foregroundStyle(TL.paper)
                    .frame(width: 70, alignment: .leading)
                Text(session.activityName)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(TL.paper)
                    .lineLimit(1)
                Spacer()
                if let points {
                    Text(points > 0 ? "+\(points)" : "\(points)")
                        .font(.tlTimer(14))
                        .foregroundStyle(points > 0 ? TL.jade : TL.rec)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TL.faint)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
            .onTapGesture { toggle(session.id) }

            if isOpen {
                detail(session, outcome: outcome)
                    .padding(.bottom, 13)
            }
        }
    }

    /// 탭 시점의 현재 상태를 직접 읽어 토글 — 캡처된 값에 의존하지 않는다
    private func toggle(_ id: UUID) {
        withAnimation(TLMotion.snappy) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    @ViewBuilder
    private func detail(_ session: FocusSession, outcome: SessionOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(outcome.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(outcome.isSuccess ? TL.jade : (outcome.isFailure ? TL.rec : TL.amber))
                Text("· \(session.intensity.title)")
                    .font(.system(size: 12)).foregroundStyle(TL.muted)
            }

            if let thumbURL = session.thumbnailURL,
               let image = UIImage(contentsOfFile: thumbURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))
                    // fill로 넘친 이미지는 clipShape로 잘라도 '터치 영역'은 그대로 남아
                    // 위 헤더 행의 탭(접기)을 가로챈다 — 장식 이미지이므로 히트 테스트 제외
                    .allowsHitTesting(false)
            }

            if let reason = reason(for: session), !reason.isEmpty {
                Label(reason, systemImage: "text.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TL.amber)
            }

            Text(String(format: String(localized: "Recorded %@ / Target %@"),
                       TLFormat.hms(session.recordedSeconds), TLFormat.hms(session.targetSeconds)))
                .font(.system(size: 12)).foregroundStyle(TL.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 28)
    }

    // MARK: 보조

    private func pts(_ session: FocusSession) -> Int? {
        ScoreRules.points(for: session.outcome ?? .completed, intensity: session.intensity,
                          durationMinutes: session.targetSeconds / 60)?.1
    }

    private func circleColor(_ outcome: SessionOutcome) -> Color {
        outcome.isSuccess ? TL.jade : (outcome.isFailure ? TL.rec : TL.amber)
    }

    /// 실패/긴급 사유 — 점수 원장의 note 우선, 없으면 세션의 긴급 사유.
    /// 사유가 실리는 이벤트(이탈·노쇼·긴급·취소·자리비움)는 전부 음수 점수다 — 양수까지 보면
    /// 같은 세션에 note를 달고 저장되는 슬롯 확장 보너스 문구가 사유 자리에 끼어든다.
    private func reason(for session: FocusSession) -> String? {
        if let note = scoreEvents.first(where: { $0.sessionID == session.id && $0.points < 0 })?.note,
           !note.isEmpty {
            return ScoreNote.label(note)   // 정본 토큰·레거시 한글 모두 표시 문구로
        }
        return session.emergencyReason.map(ScoreNote.label)
    }
}

// MARK: - 연속달성 헤더 카드 (+ 태그별 시간 분포 도넛 토글)

struct StreakHeaderCard: View {
    let sessions: [FocusSession]
    /// 도넛은 기본 접힘 — 펼치지 않는 한 캘린더가 아래로 밀리지 않는다
    @State private var showTagDonut = false

    private var detail: (days: Int, successes: Int) { SlotPolicy.streakDetail(sessions: sessions) }
    private var best: Int { SlotPolicy.bestStreak(sessions: sessions) }

    /// 누적 완주 시간(초) — 홈 상단 배지와 같은 정의
    private var totalSuccessSeconds: Int {
        sessions.filter { $0.outcome?.isSuccess == true }
            .reduce(0) { $0 + $1.recordedSeconds }
    }

    /// 평균 일정 = 현재 연속달성 기간에 성공한 일정 수 ÷ 연속일수.
    /// (예: 월 3개·화 1개·수 2개 성공으로 3일 연속이면 6÷3 = 2.0개)
    private var averageLabel: String {
        let d = detail
        guard d.days > 0 else { return "0.0" }
        return String(format: "%.1f", Double(d.successes) / Double(d.days))
    }

    private var byTag: [(String, Int)] {
        Dictionary(grouping: sessions.filter { $0.outcome?.isSuccess == true },
                   by: { CanonicalTag.canonical($0.tag) })   // 레거시 한글·키가 한 조각으로 합쳐지게
            .mapValues { $0.reduce(0) { $0 + $1.recordedSeconds } }
            // 동률 시 태그명 2차 정렬 — Dictionary 순서가 비결정이라 상위 4개/'그 외' 구성이
            // 실행·플랫폼마다 달라지는 것을 막는다 (안드로이드 동일).
            // (삼항식 한 줄은 튜플 추론과 겹쳐 타입체커가 터진다 — 명시적 분기로)
            .sorted { (a: (key: String, value: Int), b: (key: String, value: Int)) -> Bool in
                if a.value != b.value { return a.value > b.value }
                return a.key < b.key
            }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text("Streak")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(TL.muted)
                            .fixedSize()   // 좁은 기기에서 두 줄로 꺾이지 않게 (홈 카드와 동일)
                        Image("fire").resizable().scaledToFit().frame(width: 15, height: 15)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(detail.days)")
                            .font(.tlTimer(36))
                            .foregroundStyle(TL.jade)
                        Text("days")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(TL.muted)
                    }
                    // "You've logged N hr n min total!" — under 1 hour shows minutes only, not "0h"
                    (Text("You've logged ").font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(TL.muted)
                     + styledHourMinute(
                        seconds: totalSuccessSeconds,
                        numberFont: .system(size: 13, weight: .semibold, design: .rounded),
                        unitFont: .system(size: 13, weight: .semibold, design: .rounded))
                     + Text(" total!").font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(TL.muted))
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 12) {
                    // 아이콘 배정: 최고기록 = 별(average.svg), 평균 일정 = 깃발(record.svg).
                    // 에셋 파일명과 화면 배정이 어긋나 있으니 이름만 보고 되돌리지 말 것.
                    sideStat(label: String(localized: "Best Streak"), icon: "average", value: "\(best)", unit: String(localized: "days"))
                    sideStat(label: String(localized: "Avg per Day"), icon: "record", value: averageLabel, unit: "")
                }
            }

            if showTagDonut, !byTag.isEmpty {
                TagDonutView(byTag: byTag)
                    .padding(.top, 18)
                    // 제자리에서 밝아지기만 한다. 위에서 미끄러져 내려오는 전환(.move)은
                    // 헤더 숫자 위를 훑고 지나가 어수선했다 — 카드가 아래로 자라며
                    // 드러나는 것처럼 보이도록 이동 없이 페이드만.
                    .transition(.opacity.animation(.easeInOut(duration: 0.22)))
            }

            // 토글 손잡이 — 태그별 시간 분포 열기/닫기
            if !byTag.isEmpty {
                Button {
                    // 높이는 부드러운 스프링으로 자라고(카드가 열리는 느낌),
                    // 내용은 위 transition의 짧은 페이드로 뒤따라 나타난다
                    withAnimation(TLMotion.smooth) { showTagDonut.toggle() }
                } label: {
                    Image(systemName: showTagDonut ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(TL.faint)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // 접힘/펼침과 무관하게 카드가 항상 화면 폭을 꽉 채운다 —
        // 내용 크기에 폭을 맡기면 도넛을 여는 순간 카드 좌우 폭이 널뛴다
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
        // 펼쳐지는 내용이 카드 밖(이웃 요소 위)으로 새어 그려지지 않게 잘라낸다 —
        // 카드 높이가 자라는 만큼만 도넛이 드러나 '열린다'는 느낌이 정확해진다
        .clipShape(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous))
    }

    private func sideStat(label: String, icon: String, value: String, unit: String) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(TL.muted)
                Image(icon).resizable().scaledToFit().frame(width: 14, height: 14)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.tlTimer(19)).foregroundStyle(TL.paper)
                Text(unit)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(TL.muted)
            }
        }
    }
}

// MARK: - 태그별 시간 분포 도넛

struct TagDonutView: View {
    /// (태그, 완주 촬영 초) — 점유율 내림차순
    let byTag: [(String, Int)]

    /// 프리셋 태그가 아닌 것(그룹·직접 입력·'그 외')용 폴백 — 서로 구분되는 무채색 계열.
    /// 프리셋 6개는 앱 전역의 태그 색(tagTint)을 그대로 써서 칩과 도넛이 같은 색을 말한다.
    private static let fallbackPalette: [Color] = [
        Color(hex: 0x9AA0A6),   // 라이트 그레이
        Color(hex: 0x6E7681),   // 스틸
        Color(hex: 0x4D555E),   // 다크 스틸
    ]

    private var totalSeconds: Int { max(1, byTag.reduce(0) { $0 + $1.1 }) }
    private var totalMinutesLabel: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: totalSeconds / 60)) ?? "\(totalSeconds / 60)"
    }

    /// 상위 4개 + '그 외' 묶음 — 팔레트/범례가 무한히 늘어나지 않게.
    /// 색은 시스템 태그 색(tagTint) 그대로, 프리셋이 아닌 태그만 무채색 폴백을 순환 배정.
    private var segments: [(name: String, seconds: Int, color: Color)] {
        var rows: [(String, Int)] = Array(byTag.prefix(4))
        let restSeconds = byTag.dropFirst(4).reduce(0) { $0 + $1.1 }
        if restSeconds > 0 { rows.append((String(localized: "Other"), restSeconds)) }
        var fallbackIndex = 0
        return rows.map { row in
            let color: Color
            if let tint = tagTint(row.0) {
                color = tint
            } else {
                color = Self.fallbackPalette[fallbackIndex % Self.fallbackPalette.count]
                fallbackIndex += 1
            }
            return (row.0, row.1, color)
        }
    }

    /// 시:분 표기 — "655:24" = 655시간 24분 (모든 활동이 5·10분 단위라 초는 표시하지 않는다)
    private func hoursMinutes(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Time by Tag")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(TL.paper)
                Text("(h : m)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(TL.faint)
            }

            // 폭이 넘치지 않는 구조여야 한다 — 넘치면 스크롤 내용 전체가 그 폭에 맞춰
            // 늘어나 이웃 카드(캘린더)까지 함께 넓어진다. 그래서 도넛은 고정 크기,
            // 범례는 한 줄에 하나씩(칩은 최대 폭 제한 + 말줄임)으로 항상 압축 가능하게 둔다.
            // (2열 LazyVGrid는 가로 컨텍스트에서 필요 이상으로 폭을 요구해 이 사고를 냈다)
            HStack(alignment: .center, spacing: 14) {
                donut
                    .frame(width: 150, height: 150)

                // 범례 — 태그 칩(앱 전역과 동일) + 시:분
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(segments, id: \.name) { seg in
                        HStack(spacing: 8) {
                            // 도넛 조각도 같은 tagTint를 쓰므로 칩과 조각이 같은 색으로 짝지어진다
                            TagChip(name: seg.name)
                                .lineLimit(1)
                                .frame(maxWidth: 96, alignment: .leading)
                            Spacer(minLength: 2)
                            Text(hoursMinutes(seg.seconds))
                                .font(.tlTimer(13))
                                .foregroundStyle(TL.muted)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var donut: some View {
        // 세그먼트 사이 미세 간격으로 조각을 분리해 읽기 쉽게 한다
        let gap = segments.count > 1 ? 0.008 : 0.0
        var running = 0.0
        // 시작/끝 각도를 먼저 계산해 두고 그린다 (뷰 빌더 안에서 누적 변수를 못 쓰므로)
        let arcs: [(seg: (name: String, seconds: Int, color: Color), from: Double, to: Double)] =
            segments.map { seg in
                let fraction = Double(seg.seconds) / Double(totalSeconds)
                let from = running
                running += fraction
                return (seg, from, running)
            }

        return ZStack {
            ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                Circle()
                    .trim(from: arc.from + gap / 2, to: max(arc.from + gap / 2, arc.to - gap / 2))
                    .stroke(arc.seg.color, style: StrokeStyle(lineWidth: 24, lineCap: .butt))
                    .frame(width: 116, height: 116)   // 선 두께까지 150 프레임 안에 들어오는 크기
                    .rotationEffect(.degrees(-90))
            }

            // 점유율 라벨 — 조각 중앙 각도에 배치 (7% 미만 조각은 생략해 겹침 방지)
            ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                let fraction = arc.to - arc.from
                if fraction >= 0.07 {
                    let mid = (arc.from + arc.to) / 2 * 2 * .pi - .pi / 2
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1.5)
                        .offset(x: cos(mid) * 58, y: sin(mid) * 58)   // 링 중심선 위
                }
            }

            // 중앙 — 총 n분. 천 단위를 넘으면 한 줄로는 링 안쪽(78pt)을 넘겨 글자가
            // 뭉개진다("Total 1,234m") → 라벨과 숫자를 두 줄로 나눈다.
            VStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TL.faint)
                VStack(spacing: 0) {
                    if totalSeconds / 60 >= 1000 {
                        // 'Total '의 끝 공백은 한 줄일 때 숫자와 띄우려던 것 — 줄을 나누면 군더더기다.
                        // 같은 카탈로그 키를 쓰되 공백만 떼어 쓴다(ko "총 " → "총").
                        Text(String(localized: "Total ").trimmingCharacters(in: .whitespaces))
                            .foregroundStyle(TL.muted)
                        (Text(totalMinutesLabel).foregroundStyle(TL.jade)
                         + Text("m").foregroundStyle(TL.muted))
                    } else {
                        (Text("Total ").foregroundStyle(TL.muted)
                         + Text(totalMinutesLabel).foregroundStyle(TL.jade)
                         + Text("m").foregroundStyle(TL.muted))
                    }
                }
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            .frame(width: 78)
        }
    }
}

// MARK: - 누적 대시보드

struct DashboardSection: View {
    let sessions: [FocusSession]
    let scoreEvents: [ScoreEvent]

    private var finished: [FocusSession] { sessions.filter { $0.outcome != nil } }
    private var completions: Int { finished.filter { $0.outcome?.isSuccess == true }.count }
    private var noShows: Int { finished.filter { $0.outcome == .noShow }.count }
    private var started: Int { finished.filter { $0.startedAt != nil }.count }

    private var totalReward: Int { scoreEvents.filter { $0.points > 0 }.reduce(0) { $0 + $1.points } }
    private var totalPenalty: Int { scoreEvents.filter { $0.points < 0 }.reduce(0) { $0 + $1.points } }

    private var completionRate: Int {
        guard started > 0 else { return 0 }
        return Int(Double(completions) / Double(started) * 100)
    }
    private var noShowRate: Int {
        guard !finished.isEmpty else { return 0 }
        return Int(Double(noShows) / Double(finished.count) * 100)
    }

    // 카드 1장 — 좌측 큰 총점, 우측 2×2 (상점/완주율 · 벌점/노쇼율).
    // 연속달성·태그 분포는 상단 헤더 카드로 이사했다.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TLEyebrow(text: String(localized: "Cumulative Dashboard"))

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Score")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(TL.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(totalReward + totalPenalty)")
                            .font(.tlTimer(36))
                            .foregroundStyle(totalReward + totalPenalty >= 0 ? TL.jade : TL.rec)
                        Text("pts")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(TL.muted)
                    }
                }

                Spacer(minLength: 12)

                // Grid로 묶어야 위아래 행의 열 폭이 같아진다. HStack 두 개로 두면 행마다
                // 폭이 따로 정해져 '완주율'과 '노쇼율'의 오른쪽 끝이 세로로 어긋난다.
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        miniStat(label: String(localized: "Total Points"), value: "\(totalReward)", tint: TL.jade)
                        miniStat(label: String(localized: "Completion Rate"), value: "\(completionRate)%", tint: TL.jade)
                    }
                    GridRow {
                        // 벌점은 빨간색이 이미 '깎였다'를 말하므로 절대값으로 표기
                        miniStat(label: String(localized: "Total Penalty"), value: "\(abs(totalPenalty))", tint: TL.rec)
                        miniStat(label: String(localized: "No-show Rate"), value: "\(noShowRate)%",
                                 tint: noShowRate > 0 ? TL.rec : TL.muted)
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
        }
    }

    private func miniStat(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            // 영어 라벨은 한국어보다 길다("완주율" ↔ "Completion Rate"). 폭이 모자라면
            // SwiftUI가 단어 중간을 끊어버리므로("Completio / n Rate") 글자를 조금
            // 줄여서라도 단어를 지키게 한다. 줄바꿈된 라벨도 값과 같이 오른쪽 정렬.
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(TL.muted)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.tlTimer(16))
                .foregroundStyle(tint)
        }
        .frame(minWidth: 52, alignment: .trailing)
    }
}
