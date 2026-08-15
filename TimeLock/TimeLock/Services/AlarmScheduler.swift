//
//  AlarmScheduler.swift
//  TimeLock
//
//  예약 시각의 강제 알람과 10분 전 예고 알림을 스케줄한다.
//  - 지원 OS(iOS 26+)에서는 AlarmKit 풀스크린 알람을 사용하도록 어댑터 지점을 제공한다.
//    (ENABLE_ALARMKIT 컴파일 플래그 + AlarmKit capability 추가 후 활성화 — README 참조)
//  - 그 외에는 타임센서티브 로컬 알림 + 앱 실행 중 오디오 알람으로 폴백한다.
//

import Foundation
import UserNotifications
import AVFoundation
import AudioToolbox   // 무음 모드에서도 울리는 진동

@MainActor
final class AlarmScheduler: NSObject, ObservableObject {
    static let shared = AlarmScheduler()

    @Published var notificationsAuthorized = false

    /// 세션 중 '알림차단' — 앱이 화면에 떠 있는 동안 모든 알림 배너를 숨긴다.
    /// (iOS 정책상 다른 앱/시스템 알림까지 끄는 것은 불가능 — 방해금지 모드는 사용자만 켤 수 있다)
    @Published var muteAllNotifications = false

    private let center = UNUserNotificationCenter.current()
    private var alarmPlayer: AVAudioPlayer?

    // MARK: 권한

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            notificationsAuthorized = granted
            return granted
        } catch {
            notificationsAuthorized = false
            return false
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        notificationsAuthorized = settings.authorizationStatus == .authorized
    }

    /// 지연 요청 결과. 호출부가 '설정으로 보내야 하는 상태'를 구분할 수 있어야 한다.
    enum PromptOutcome {
        /// 알림을 받을 수 있는 상태 (원래 허용이었거나 방금 허용함)
        case authorized
        /// 방금 시스템 창에서 거부함 — 사용자가 막 선택한 직후라 또 안내하면 잔소리가 된다
        case justDeclined
        /// 이미 거부된 상태 — 시스템 창이 뜨지 않으므로 iOS 설정으로 유도해야 한다
        case blocked
    }

    /// 아직 한 번도 묻지 않았을 때만 시스템 창을 띄운다 (지연 요청).
    ///
    /// 온보딩의 권한 화면은 '계속'을 눌러야만 요청이 나가고, 그냥 '다음'으로 넘기면
    /// 요청 자체가 없었던 게 된다. 그러면 iOS 설정 → 알림 목록에 앱이 아예 나타나지
    /// 않아(요청 이력이 있어야 등록된다) 사용자가 수동으로 켤 수도 없고, 알람은
    /// 조용히 안 울린다. 그래서 '알람을 실제로 쓰겠다'고 선언하는 시점(예약 저장)에
    /// 다시 묻는다 — 업데이트로 넘어온 기존 사용자도 이 경로로 구제된다.
    ///
    /// 이미 거부한 사용자에게는 시스템 창이 다시 뜨지 않으므로(iOS는 평생 1회)
    /// `.blocked`를 돌려준다 — 호출부가 iOS 설정으로 안내해야 한다.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> PromptOutcome {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return await requestAuthorization() ? .authorized : .justDeclined
        case .authorized, .provisional, .ephemeral:
            notificationsAuthorized = true
            return .authorized
        default:
            notificationsAuthorized = false
            return .blocked
        }
    }

    // MARK: 스케줄링

    /// 모든 활성 예약의 알람/예고를 다시 스케줄한다. (예약 변경 시마다 호출)
    ///
    /// iOS는 앱당 대기 알림을 64개로 제한하고, **넘치는 요청은 에러 없이 조용히 버린다.**
    /// 예전에는 예약마다 독립적으로 최대 10건(+예고·경고)을 걸어, 활동이 대여섯 개만 돼도
    /// 뒤쪽 예약은 메인 알람조차 등록되지 않고 매일 확정 노쇼가 됐다. 그래서 예약별 한도가
    /// 아니라 **전역 예산**을 쓰고, 아래 순서로 배분한다.
    ///
    /// 1. 무기한 반복 → 주간 반복 트리거(요일당 1건, 만료 없음). 앱을 안 열어도 영원히 울린다.
    ///    요일 수가 적은 예약부터 배정하되, 남은 예약이 각자 1건씩 쓸 자리는 반드시 남긴다.
    /// 2. 나머지 예약 → **가장 가까운 발생 1건을 먼저 확보**. 두 달 뒤 시작이든 1년 뒤든
    ///    첫 알람은 반드시 걸린다(앱을 한 번도 안 열어도 그날 울린다).
    /// 3. 남은 예산 → 전체 발생을 시간순으로 줄 세워 가까운 것부터. 한 예약이 독식하지 않는다.
    /// 4. 남은 예산 → 임박한 발생의 예고(-10분)·마지막 경고(+5분).
    ///
    /// 이 전체가 앱을 열 때마다 다시 계산되는 롤링 윈도우다.
    /// 이미 소비된 발생 (촬영을 시작했거나 취소해 기록이 남은 건) — 여기 있는 발생에는
    /// 예고·마지막 경고를 다시 걸지 않는다. 키는 "예약ID-발생시각(초)".
    func rescheduleAll(reservations: [Reservation], consumed: Set<String> = []) {
        center.removeAllPendingNotificationRequests()
        // 위 한 줄이 재촬영 창(긴급 용무 중단) 알림까지 함께 지운다 — 진행 중이면 즉시 복구한다.
        reArmBreakNotificationsIfNeeded()
        let now = Date()
        let cal = Calendar.current
        let active = reservations.filter { $0.isActive }

        var budget = Self.pendingBudget
        var uncovered = active.count        // 아직 알람이 한 건도 없는 예약 수
        var weeklyCovered = Set<UUID>()

        // 1) 무기한 반복 — 주간 트리거로 만료 없이 커버
        let indefinite = active
            .filter { $0.isRepeating && $0.endDate == nil
                && cal.startOfDay(for: $0.createdAt) <= cal.startOfDay(for: now) }
            .sorted { $0.repeatWeekdays.count < $1.repeatWeekdays.count }
        for reservation in indefinite {
            let need = reservation.repeatWeekdays.count
            guard need > 0, budget - need >= uncovered - 1 else { continue }
            for weekday in reservation.repeatWeekdays {
                scheduleRepeatingWeeklyAlarm(for: reservation, weekday: weekday)
            }
            budget -= need
            uncovered -= 1
            weeklyCovered.insert(reservation.id)
        }

        // 2) 나머지 예약 — 첫 발생 1건씩 확보
        var pool: [(reservation: Reservation, fire: Date)] = []
        for reservation in active where !weeklyCovered.contains(reservation.id) {
            guard budget > 0 else { break }
            let fires = occurrences(of: reservation, from: now,
                                    withinDays: Self.rollingWindowDays, calendar: cal)
            if let first = fires.first {
                scheduleMainAlarm(for: reservation, at: first)
                pool.append(contentsOf: fires.dropFirst().map { (reservation, $0) })
            } else if let far = reservation.nextOccurrence(after: now, calendar: cal) {
                // 창(14일) 밖에서 시작하는 예약 — 멀어도 첫 건은 반드시 건다.
                scheduleMainAlarm(for: reservation, at: far)
            } else {
                continue   // 남은 발생이 없는 예약은 예산을 쓰지 않는다
            }
            budget -= 1
            uncovered -= 1
        }

        // 3) 남은 예산을 시간순으로
        for item in pool.sorted(by: { $0.fire < $1.fire }) {
            guard budget > 0 else { break }
            scheduleMainAlarm(for: item.reservation, at: item.fire)
            budget -= 1
        }

        // 4) 예고·마지막 경고 — 임박한 발생에만, 가까운 순으로
        var imminent: [(reservation: Reservation, fire: Date)] = []
        for reservation in active {
            for fire in imminentOccurrences(of: reservation, within: 36 * 3600, now: now, calendar: cal) {
                // 이미 시작했거나 취소한 발생은 건너뛴다. 재무장 하한을 '지금 - 시작창'으로
                // 넓힌 탓에, 그러지 않으면 방금 취소하고 벌점까지 받은 발생에
                // "아직 시작하지 않았습니다"라는 경고가 5분 뒤 다시 뜬다.
                let key = "\(reservation.id.uuidString)-\(Int(fire.timeIntervalSince1970))"
                guard !consumed.contains(key) else { continue }
                imminent.append((reservation, fire))
            }
        }
        for (index, item) in imminent.sorted(by: { $0.fire < $1.fire }).enumerated() {
            guard budget >= 2 else { break }
            schedulePreAlert(for: item.reservation, at: item.fire)
            scheduleReAlarms(for: item.reservation, at: item.fire)   // +5분 마지막 경고
            budget -= 2
            // 1분 간격 연타는 가장 임박한 발생 하나에만 — 모든 예약에 걸면 예산이 터진다.
            if index == 0 {
                budget -= scheduleMinuteBanners(for: item.reservation, at: item.fire, limit: budget)
            }
        }

        #if ENABLE_ALARMKIT
        if #available(iOS 26.0, *) {
            AlarmKitBridge.sync(reservations: reservations)
        }
        #endif
    }

    /// 알람 본문 콘텐츠 (구체·반복 공통). 라우팅은 kind·reservationID만 사용하며,
    /// 실제 발생 시각은 앱이 checkDueAlarm에서 예약으로부터 재계산하므로 fireDate를 담지 않는다.
    private func makeAlarmContent(for reservation: Reservation) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(format: String(localized: "%@ Starting"), reservation.name)
        content.body = String(format: String(localized: "The only way to stop this alarm is to start recording within %ld minutes."), TimePolicy.startWindowMinutes)
        // iOS는 커스텀 알림음을 30초까지 재생한다. 5초짜리를 쓰면 그 여섯 배를 버리는 셈이라
        // 배너 하나가 순식간에 조용해진다. 25초짜리를 써서 한 발이 오래 울리게 한다.
        content.sound = UNNotificationSound(named: UNNotificationSoundName("alarm-long.wav"))
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["reservationID": reservation.id.uuidString, "kind": "alarm"]
        content.categoryIdentifier = "TIMELOCK_ALARM"
        return content
    }

    /// 시작 창 안에서 1분 간격으로 다시 울리는 배너.
    ///
    /// 앱이 꺼져 있으면 우리가 코드를 돌릴 방법이 없어 배너가 유일한 수단이다.
    /// 예전에는 정각 1발 + 5분 뒤 1발이 전부라 "알람이 온 줄 몰랐다"는 말이 나왔다.
    /// +5분은 '마지막 경고' 전용 문구가 따로 있으므로 여기서는 건너뛴다.
    /// 반환값 = 실제로 건 개수 (예산 차감용)
    private func scheduleMinuteBanners(for reservation: Reservation, at fire: Date, limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        let total = TimePolicy.startWindowMinutes      // 10분 창
        var scheduled = 0
        for minute in 1..<total where minute != 5 {
            guard scheduled < limit else { break }
            guard let at = Calendar.current.date(byAdding: .minute, value: minute, to: fire),
                  at > .now else { continue }
            let content = makeAlarmContent(for: reservation).mutableCopy() as! UNMutableNotificationContent
            content.body = String(format: String(localized: "You haven't started yet. You'll be marked as a no-show in %ld minutes."), total - minute)
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: at)
            let request = UNNotificationRequest(
                identifier: "alarm-m\(minute)-\(reservation.id.uuidString)-\(Int(fire.timeIntervalSince1970))",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            center.add(request)
            scheduled += 1
        }
        return scheduled
    }

    /// 앱을 열 때마다 다시 계산되는 롤링 윈도우 길이
    private static let rollingWindowDays = 14
    /// 대기 알림 전역 예산. iOS 상한 64건에서 재촬영 창 알림 3건과 여유분을 뺀 값.
    /// 넘치는 요청은 iOS가 조용히 버리므로, 우리가 먼저 세어서 중요한 것부터 채운다.
    private static let pendingBudget = 56

    /// 창 안에서 이 예약이 실제로 발생하는 시각들 (이른 순).
    /// 시작일·종료일 게이트는 occurrence()가 적용하므로 범위 밖 알람이 생기지 않는다.
    private func occurrences(of reservation: Reservation, from now: Date,
                             withinDays days: Int, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset,
                                          to: calendar.startOfDay(for: now)),
                  let fire = reservation.occurrence(on: day, calendar: calendar),
                  fire > now else { continue }
            result.append(fire)
        }
        return result
    }

    /// 일회성 메인 알람 1건 (구체 시각, 반복 없음)
    private func scheduleMainAlarm(for reservation: Reservation, at fire: Date) {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: "alarm-\(reservation.id.uuidString)-\(Int(fire.timeIntervalSince1970))",
            content: makeAlarmContent(for: reservation), trigger: trigger)
        center.add(request)
    }

    /// 반복 예약의 주간 반복 메인 알람 (요일당 1건, 만료 없음 → 64개 상한 걱정 없이 무한 커버)
    private func scheduleRepeatingWeeklyAlarm(for reservation: Reservation, weekday: Int) {
        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour = reservation.startMinute / 60
        comps.minute = reservation.startMinute % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(
            identifier: "alarm-rep-\(reservation.id.uuidString)-\(weekday)",
            content: makeAlarmContent(for: reservation), trigger: trigger)
        center.add(request)
    }

    /// 알람 무시 대비 재알림 1회 — 예정 5분 후(= 노쇼 5분 전) 마지막 배너. 임박한 발생에만 건다.
    /// (예전 2분 간격 4회는 과했음: -10분 예고 / 0분 메인 / +5분 마지막 3단계로 단순화)
    private func scheduleReAlarms(for reservation: Reservation, at fire: Date) {
        guard let repeatFire = Calendar.current.date(byAdding: .minute, value: 5, to: fire),
              repeatFire > .now else { return }
        let rComps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: repeatFire)
        let rTrigger = UNCalendarNotificationTrigger(dateMatching: rComps, repeats: false)
        let rContent = makeAlarmContent(for: reservation).mutableCopy() as! UNMutableNotificationContent
        rContent.body = String(localized: "You haven't started yet. You'll be marked as a no-show in 5 minutes.")
        let rRequest = UNNotificationRequest(
            identifier: "alarm-r1-\(reservation.id.uuidString)-\(Int(fire.timeIntervalSince1970))",
            content: rContent, trigger: rTrigger)
        center.add(rRequest)
    }

    /// 예고·마지막 경고를 걸 대상 발생들.
    ///
    /// 하한이 `now`가 아니라 `now - 시작창(10분)`인 것이 핵심이다. rescheduleAll은 맨 먼저
    /// 대기 알림을 전부 지우는데, 앞으로 올 것만 다시 걸면 **지금 진행 중인 발생의 +5분
    /// 마지막 경고가 지워진 채 복구되지 않는다.** 알람 배너를 눌러 앱을 여는 것만으로
    /// 3단 에스컬레이션의 마지막 단계가 사라지던 원인이다.
    /// (이미 지나간 예고·경고는 schedulePreAlert/scheduleReAlarms가 각자 걸러낸다)
    private func imminentOccurrences(of reservation: Reservation, within: TimeInterval,
                                     now: Date, calendar: Calendar) -> [Date] {
        let floor = now.addingTimeInterval(-TimePolicy.startWindowSeconds)
        let ceiling = now.addingTimeInterval(within)
        var result: [Date] = []
        for offset in -1...2 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let fire = reservation.occurrence(on: day, calendar: calendar) else { continue }
            if fire > floor, fire <= ceiling { result.append(fire) }
        }
        return result
    }

    private func schedulePreAlert(for reservation: Reservation, at fire: Date) {
        guard let pre = Calendar.current.date(byAdding: .minute, value: -10, to: fire), pre > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = String(format: String(localized: "'%@' starts in 10 minutes"), reservation.name)
        content.body = String(format: String(localized: "Get your camera ready. The alarm goes off at %@."), TLFormat.clock(fire))
        content.sound = .default
        // 준비하라고 보내는 알림인데 집중 모드를 못 뚫으면, 방해금지를 켜둔 사람은
        // 예고 없이 정각 알람부터 맞는다. 정작 준비 시간이 필요한 쪽이 못 받는 셈이다.
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["reservationID": reservation.id.uuidString, "kind": "prealert"]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: pre)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: "pre-\(reservation.id.uuidString)-\(Int(fire.timeIntervalSince1970))",
            content: content, trigger: trigger)
        center.add(request)
    }

    /// 이 예약의 '이미 배달된' 알림만 걷어낸다 (유령 알람 정리용).
    ///
    /// 대기 알림은 건드리지 않는다. 조회가 완료 핸들러라 즉시 끝나지 않는데, 호출부는
    /// 바로 뒤에서 rescheduleAll을 돌린다. 그러면 뒤늦게 도착한 콜백이 방금 새로 건
    /// 알람을 같은 식별자로 지워버려, 그 예약의 알람이 통째로 사라진다.
    /// 어차피 rescheduleAll이 첫 줄에서 대기 알림을 전부 지우고 유효한 것만 다시 걸므로,
    /// 유령의 대기분은 그 과정에서 자연히 사라진다.
    nonisolated func purgeDeliveredNotifications(reservationID: UUID) {
        let key = reservationID.uuidString
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map { $0.request.identifier }.filter { $0.contains(key) }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// 특정 발생 건의 남은 알람(재알림·예고 포함)을 모두 취소 — 촬영 준비/일정 취소 시.
    /// 반복 예약의 주간 반복 트리거는 '다음 주'를 위해 유지하되, 지금 떠 있는 배너만 지운다.
    func cancelAlarmNotifications(reservationID: UUID, fireDate: Date) {
        let ts = Int(fireDate.timeIntervalSince1970)
        // r1 = 단일 재알림(+5분). r2~r4는 구버전 잔재 대비 함께 정리(없으면 무시).
        let ids = ["alarm-\(reservationID.uuidString)-\(ts)", "pre-\(reservationID.uuidString)-\(ts)"]
            + (1...4).map { "alarm-r\($0)-\(reservationID.uuidString)-\(ts)" }
            // 1분 간격 연타도 함께 — 촬영을 시작했는데 계속 울리면 안 된다
            + (1..<TimePolicy.startWindowMinutes).map { "alarm-m\($0)-\(reservationID.uuidString)-\(ts)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        // 반복 메인 알람: 대기 트리거는 유지(다음 주 발화)하고, 이번에 배달된 배너만 제거
        let weekday = Calendar.current.component(.weekday, from: fireDate)
        center.removeDeliveredNotifications(
            withIdentifiers: ["alarm-rep-\(reservationID.uuidString)-\(weekday)"])
    }

    // MARK: 재촬영 창 알림 (긴급 용무 중단 · 매운맛)

    private static let breakNotificationIDs = ["break-open", "break-warn", "break-fail"]

    /// 진행 중인 재촬영 창의 마감 시각. rescheduleAll이 대기 알림을 전부 지우므로,
    /// 지운 뒤 이 값으로 경고·마감 알림을 다시 걸어야 한다. (없으면 nil)
    private var activeBreakDeadline: Date?

    /// 중단 시점에 3건 예약: 즉시 안내 / 마감 2분 전 경고 / 마감 시 벌점 확정 안내
    func scheduleBreakNotifications(deadline: Date) {
        cancelBreakNotifications()          // activeBreakDeadline도 함께 비워진다
        activeBreakDeadline = deadline      // 그래서 취소 뒤에 설정해야 한다
        armBreakNotifications(deadline: deadline, includeOpen: true)
    }

    /// rescheduleAll이 대기 알림을 전부 날린 뒤 재촬영 창 알림만 복구한다.
    /// 이게 없으면 중단 중에 앱을 잠깐 열었다 나가는 것만으로 '2분 전 경고'와
    /// '벌점 부과' 알림이 사라져, 사용자가 아무 경고 없이 벌점을 맞는다.
    private func reArmBreakNotificationsIfNeeded() {
        guard let deadline = activeBreakDeadline else { return }
        guard deadline > .now else { activeBreakDeadline = nil; return }
        // 'break-open'은 중단 순간의 1회성 안내라 다시 띄우지 않는다 —
        // 복구할 때마다 '촬영 일시중단' 배너가 또 뜨면 오히려 혼란스럽다.
        armBreakNotifications(deadline: deadline, includeOpen: false)
    }

    private func armBreakNotifications(deadline: Date, includeOpen: Bool) {
        // kind=break — 앱이 화면에 떠 있을 때는 중단 오버레이가 이미 안내하므로 배너를 숨긴다
        if includeOpen {
            let open = UNMutableNotificationContent()
            open.title = String(localized: "Recording Paused")
            open.body = String(format: String(localized: "Come back and resume within %ld minutes — no penalty."), TimePolicy.resumeWindowMinutes)
            open.sound = .default
            open.interruptionLevel = .timeSensitive
            open.userInfo = ["kind": "break"]
            center.add(UNNotificationRequest(
                identifier: "break-open", content: open,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)))
        }

        let warnAt = deadline.addingTimeInterval(-120)
        if warnAt > .now {
            let warn = UNMutableNotificationContent()
            warn.title = String(localized: "2 Minutes to Resume")
            warn.body = String(localized: "Come back now and resume recording. A penalty applies if time runs out.")
            warn.sound = UNNotificationSound(named: UNNotificationSoundName("alarm-long.wav"))
            warn.interruptionLevel = .timeSensitive
            warn.userInfo = ["kind": "break"]
            center.add(UNNotificationRequest(
                identifier: "break-warn", content: warn,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, warnAt.timeIntervalSinceNow), repeats: false)))
        }

        let fail = UNMutableNotificationContent()
        fail.title = String(localized: "Penalty Applied")
        fail.body = String(format: String(localized: "You didn't resume within %ld minutes, so the session was recorded as failed."), TimePolicy.resumeWindowMinutes)
        fail.sound = UNNotificationSound(named: UNNotificationSoundName("alarm-long.wav"))
        fail.interruptionLevel = .timeSensitive
        fail.userInfo = ["kind": "break"]
        center.add(UNNotificationRequest(
            identifier: "break-fail", content: fail,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, deadline.timeIntervalSinceNow), repeats: false)))
    }

    func cancelBreakNotifications() {
        activeBreakDeadline = nil   // 복구 대상에서도 빼야 rescheduleAll이 되살리지 않는다
        center.removePendingNotificationRequests(withIdentifiers: Self.breakNotificationIDs)
        center.removeDeliveredNotifications(withIdentifiers: Self.breakNotificationIDs)
    }

    // MARK: 앱 실행 중 알람 오디오 (스누즈 없음, 촬영 시작 시점에만 정지)

    func startAlarmSound() {
        startAlarmVibration()   // 소리와 한 몸으로 — 무음 모드에서는 이쪽만 살아남는다
        guard alarmPlayer == nil else { return }
        guard let url = Bundle.main.url(forResource: "alarm", withExtension: "wav") else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 1.0
            player.play()
            alarmPlayer = player
        } catch { }
    }

    func stopAlarmSound() {
        stopAlarmVibration()
        alarmPlayer?.stop()
        alarmPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: 알람 진동 — 무음 모드에서 유일하게 남는 감각

    /// 벨소리를 꺼둔 사람에게는 소리가 한 톨도 나가지 않는다(타임센서티브 등급으로도
    /// 무음 스위치는 못 뚫는다). 그러면 알람 화면만 조용히 떠 있고 아무 일도 일어나지 않는다.
    /// 진동은 벨소리와 별개 경로라 무음에서도 울리므로, 알람이 울리는 동안 계속 반복한다.
    ///
    /// 한계: 앱이 화면에 떠 있을 때만 가능하다. 백그라운드·종료 상태에서는 우리 코드가 돌지
    /// 않아 직접 진동시킬 수 없다. 그 구간은 1분 간격 배너가 맡고(알림마다 시스템이 진동시킨다),
    /// 진동 세기·길이는 우리가 정할 수 없다.
    private func startAlarmVibration() {
        guard vibrationTimer == nil else { return }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        // 한 번의 진동이 약 0.4초 — 2초 간격이면 끊기지 않게 이어지면서 과하지 않다
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        RunLoop.main.add(timer, forMode: .common)   // 스크롤 중에도 멈추지 않게
        vibrationTimer = timer
    }

    private func stopAlarmVibration() {
        vibrationTimer?.invalidate()
        vibrationTimer = nil
    }

    private var vibrationTimer: Timer?

    func playChime() {
        guard let url = Bundle.main.url(forResource: "chime", withExtension: "wav") else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0.9
            player.play()
            chimePlayer = player
        } catch { }
    }
    private var chimePlayer: AVAudioPlayer?
}

#if ENABLE_ALARMKIT
import AlarmKit

/// iOS 26+ AlarmKit 풀스크린 알람 브리지.
/// Xcode에서 AlarmKit capability와 SWIFT_ACTIVE_COMPILATION_CONDITIONS에
/// ENABLE_ALARMKIT을 추가하면 활성화된다. (README의 'AlarmKit 활성화' 절 참조)
@available(iOS 26.0, *)
enum AlarmKitBridge {
    static func sync(reservations: [Reservation]) {
        // AlarmKit의 AlarmManager로 예약별 풀스크린 알람을 등록한다.
        // 알람 UI의 유일한 액션은 앱 열기(촬영 시작 동선)로 구성한다.
        // 프로젝트 정책상 API 시그니처는 SDK 문서에 맞춰 이 지점에서 구현한다.
    }
}
#endif
