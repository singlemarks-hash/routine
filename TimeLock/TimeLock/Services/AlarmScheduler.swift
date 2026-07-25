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

    // MARK: 스케줄링

    /// 모든 활성 예약의 알람/예고를 다시 스케줄한다. (예약 변경 시마다 호출)
    /// 메인 알람은 scheduleMainAlarms가 예약의 경계에 따라 두 방식 중 하나를 고른다 —
    /// 무기한 반복은 '주간 반복 트리거'(요일당 1건, 만료 없이 커버해 64개 상한 회피),
    /// 종료일·미래 시작일이 있으면 창 안의 발생분만 구체 예약(범위 밖 발화 원천 차단).
    /// 예고·재알림은 임박한 발생(다음 36시간)에만 구체 예약해 총량을 묶는다.
    func rescheduleAll(reservations: [Reservation]) {
        center.removeAllPendingNotificationRequests()
        let now = Date()
        let calendar = Calendar.current

        for reservation in reservations where reservation.isActive {
            scheduleMainAlarms(for: reservation, now: now, calendar: calendar)
            // 예고(10분 전)·재알림(2분 간격 4회)은 임박한 발생에만 구체 예약 —
            // 반복이 쌓여도 알림 총량이 폭증하지 않고, 앱을 열 때마다 갱신된다.
            for fire in upcomingOccurrences(of: reservation, within: 36 * 3600, now: now, calendar: calendar) {
                schedulePreAlert(for: reservation, at: fire)
                scheduleReAlarms(for: reservation, at: fire)
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
        content.title = "\(reservation.name) 시작"
        content.body = "알람을 끄는 방법은 하나뿐입니다 — \(TimePolicy.startWindowMinutes)분 안에 촬영을 시작하세요."
        content.sound = UNNotificationSound(named: UNNotificationSoundName("alarm.wav"))
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["reservationID": reservation.id.uuidString, "kind": "alarm"]
        content.categoryIdentifier = "TIMELOCK_ALARM"
        return content
    }

    /// 경계(종료일·미래 시작일)가 있는 예약을 구체 예약할 창 — 앱을 열 때마다 갱신되는 롤링 윈도우
    private static let boundedWindowDays = 14
    /// 예약 1건이 창 안에서 잡을 수 있는 메인 알람 최대 개수 (iOS 64개 대기 상한 보호)
    private static let boundedMaxAlarms = 10

    /// 메인 알람 스케줄 — 시작일(createdAt)·종료일(endDate) 게이트를 반드시 지킨다.
    ///
    /// 주간 무한 반복 트리거는 종료일을 표현할 수 없다. 예전엔 isRepeating이면 무조건
    /// 이 트리거를 써서, '하루짜리' 활동이 매일 영원히 울리고(그런데 occurrence는 nil이라
    /// 촬영으로 끌 수도 없었다) 아직 시작도 안 한 그룹 방이 미리 울렸다.
    /// → 무기한(종료일 없음) + 시작일이 이미 지난 반복 예약에만 무한 트리거를 쓰고,
    ///   그 외에는 창 안의 실제 발생분만 구체 예약한다. occurrence()가 두 게이트를
    ///   모두 적용하므로 범위 밖 알람이 원천적으로 생기지 않는다.
    private func scheduleMainAlarms(for reservation: Reservation, now: Date, calendar: Calendar) {
        let startedAlready = calendar.startOfDay(for: reservation.createdAt) <= calendar.startOfDay(for: now)
        if reservation.isRepeating, reservation.endDate == nil, startedAlready {
            for weekday in reservation.repeatWeekdays {
                scheduleRepeatingWeeklyAlarm(for: reservation, weekday: weekday)
            }
            return
        }
        var scheduled = 0
        for offset in 0..<Self.boundedWindowDays where scheduled < Self.boundedMaxAlarms {
            guard let day = calendar.date(byAdding: .day, value: offset,
                                          to: calendar.startOfDay(for: now)),
                  let fire = reservation.occurrence(on: day, calendar: calendar),
                  fire > now else { continue }
            scheduleMainAlarm(for: reservation, at: fire)
            scheduled += 1
        }
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
        rContent.body = "아직 시작하지 않았습니다. 5분이 지나면 탈락 처리됩니다."
        let rRequest = UNNotificationRequest(
            identifier: "alarm-r1-\(reservation.id.uuidString)-\(Int(fire.timeIntervalSince1970))",
            content: rContent, trigger: rTrigger)
        center.add(rRequest)
    }

    /// 앞으로 `within`초 안에 발생하는 예약 시각들 (반복은 요일 규칙으로 열거, 일회성은 그 날짜)
    private func upcomingOccurrences(of reservation: Reservation, within: TimeInterval,
                                     now: Date, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        if reservation.isRepeating {
            for offset in 0...2 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                      let fire = reservation.occurrence(on: day, calendar: calendar) else { continue }
                if fire > now, fire <= now.addingTimeInterval(within) { result.append(fire) }
            }
        } else if let day = reservation.oneOffDate,
                  let fire = reservation.occurrence(on: day, calendar: calendar),
                  fire > now, fire <= now.addingTimeInterval(within) {
            result.append(fire)
        }
        return result
    }

    private func schedulePreAlert(for reservation: Reservation, at fire: Date) {
        guard let pre = Calendar.current.date(byAdding: .minute, value: -10, to: fire), pre > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = "'\(reservation.name)' 시작 10분 전입니다"
        content.body = "촬영을 준비해주세요. \(TLFormat.clock(fire)) 정각에 알람이 울립니다."
        content.sound = .default
        content.userInfo = ["reservationID": reservation.id.uuidString, "kind": "prealert"]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: pre)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: "pre-\(reservation.id.uuidString)-\(Int(fire.timeIntervalSince1970))",
            content: content, trigger: trigger)
        center.add(request)
    }

    /// 특정 발생 건의 남은 알람(재알림·예고 포함)을 모두 취소 — 촬영 준비/일정 취소 시.
    /// 반복 예약의 주간 반복 트리거는 '다음 주'를 위해 유지하되, 지금 떠 있는 배너만 지운다.
    func cancelAlarmNotifications(reservationID: UUID, fireDate: Date) {
        let ts = Int(fireDate.timeIntervalSince1970)
        // r1 = 단일 재알림(+5분). r2~r4는 구버전 잔재 대비 함께 정리(없으면 무시).
        let ids = ["alarm-\(reservationID.uuidString)-\(ts)", "pre-\(reservationID.uuidString)-\(ts)"]
            + (1...4).map { "alarm-r\($0)-\(reservationID.uuidString)-\(ts)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        // 반복 메인 알람: 대기 트리거는 유지(다음 주 발화)하고, 이번에 배달된 배너만 제거
        let weekday = Calendar.current.component(.weekday, from: fireDate)
        center.removeDeliveredNotifications(
            withIdentifiers: ["alarm-rep-\(reservationID.uuidString)-\(weekday)"])
    }

    // MARK: 재촬영 창 알림 (긴급 용무 중단 · 매운맛)

    private static let breakNotificationIDs = ["break-open", "break-warn", "break-fail"]

    /// 중단 시점에 3건 예약: 즉시 안내 / 마감 2분 전 경고 / 마감 시 벌점 확정 안내
    func scheduleBreakNotifications(deadline: Date) {
        cancelBreakNotifications()

        // kind=break — 앱이 화면에 떠 있을 때는 중단 오버레이가 이미 안내하므로 배너를 숨긴다
        let open = UNMutableNotificationContent()
        open.title = "촬영 일시중단"
        open.body = "\(TimePolicy.resumeWindowMinutes)분 안에 돌아와 재촬영을 시작하면 벌점이 없습니다."
        open.sound = .default
        open.interruptionLevel = .timeSensitive
        open.userInfo = ["kind": "break"]
        center.add(UNNotificationRequest(
            identifier: "break-open", content: open,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)))

        let warnAt = deadline.addingTimeInterval(-120)
        if warnAt > .now {
            let warn = UNMutableNotificationContent()
            warn.title = "재촬영까지 2분"
            warn.body = "지금 돌아와 재촬영을 시작하세요. 시간이 지나면 벌점이 부과됩니다."
            warn.sound = UNNotificationSound(named: UNNotificationSoundName("alarm.wav"))
            warn.interruptionLevel = .timeSensitive
            warn.userInfo = ["kind": "break"]
            center.add(UNNotificationRequest(
                identifier: "break-warn", content: warn,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, warnAt.timeIntervalSinceNow), repeats: false)))
        }

        let fail = UNMutableNotificationContent()
        fail.title = "벌점 부과"
        fail.body = "\(TimePolicy.resumeWindowMinutes)분 안에 재촬영을 시작하지 않아 세션이 실패로 기록되었습니다."
        fail.sound = UNNotificationSound(named: UNNotificationSoundName("alarm.wav"))
        fail.interruptionLevel = .timeSensitive
        fail.userInfo = ["kind": "break"]
        center.add(UNNotificationRequest(
            identifier: "break-fail", content: fail,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, deadline.timeIntervalSinceNow), repeats: false)))
    }

    func cancelBreakNotifications() {
        center.removePendingNotificationRequests(withIdentifiers: Self.breakNotificationIDs)
        center.removeDeliveredNotifications(withIdentifiers: Self.breakNotificationIDs)
    }

    // MARK: 앱 실행 중 알람 오디오 (스누즈 없음, 촬영 시작 시점에만 정지)

    func startAlarmSound() {
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
        alarmPlayer?.stop()
        alarmPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

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
