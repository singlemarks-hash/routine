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
    func rescheduleAll(reservations: [Reservation]) {
        center.removeAllPendingNotificationRequests()
        let calendar = Calendar.current
        let now = Date()

        for reservation in reservations where reservation.isActive {
            // 향후 14일치 발생 시각을 개별 예약 (반복 규칙 갱신 포함)
            for offset in 0..<14 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                      let fire = reservation.occurrence(on: day, calendar: calendar),
                      fire > now else { continue }
                scheduleAlarm(for: reservation, at: fire)
                schedulePreAlert(for: reservation, at: fire)
            }
        }

        #if ENABLE_ALARMKIT
        if #available(iOS 26.0, *) {
            AlarmKitBridge.sync(reservations: reservations)
        }
        #endif
    }

    private func scheduleAlarm(for reservation: Reservation, at fire: Date) {
        let content = UNMutableNotificationContent()
        content.title = "\(reservation.name) 시작"
        content.body = "알람을 끄는 방법은 하나뿐입니다 — \(TimePolicy.startWindowMinutes)분 안에 촬영을 시작하세요."
        content.sound = UNNotificationSound(named: UNNotificationSoundName("alarm.wav"))
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["reservationID": reservation.id.uuidString,
                            "fireDate": fire.timeIntervalSince1970,
                            "kind": "alarm"]
        content.categoryIdentifier = "TIMELOCK_ALARM"

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: "alarm-\(reservation.id.uuidString)-\(Int(fire.timeIntervalSince1970))",
            content: content, trigger: trigger)
        center.add(request)

        // 알람 무시 대비 2분 간격 재알림 4회 (10분 창 내)
        for repeatIndex in 1...4 {
            guard let repeatFire = Calendar.current.date(byAdding: .second, value: repeatIndex * 120, to: fire) else { continue }
            let rComps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: repeatFire)
            let rTrigger = UNCalendarNotificationTrigger(dateMatching: rComps, repeats: false)
            let rContent = content.mutableCopy() as! UNMutableNotificationContent
            rContent.body = "아직 시작하지 않았습니다. \(TimePolicy.startWindowMinutes)분이 지나면 탈락 처리됩니다."
            let rRequest = UNNotificationRequest(
                identifier: "alarm-r\(repeatIndex)-\(reservation.id.uuidString)-\(Int(fire.timeIntervalSince1970))",
                content: rContent, trigger: rTrigger)
            center.add(rRequest)
        }
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

    /// 특정 발생 건의 남은 알람(재알림 포함)을 모두 취소 — 촬영 준비/일정 취소 시
    func cancelAlarmNotifications(reservationID: UUID, fireDate: Date) {
        let ts = Int(fireDate.timeIntervalSince1970)
        var ids = ["alarm-\(reservationID.uuidString)-\(ts)"]
        for repeatIndex in 1...4 {
            ids.append("alarm-r\(repeatIndex)-\(reservationID.uuidString)-\(ts)")
        }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
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
