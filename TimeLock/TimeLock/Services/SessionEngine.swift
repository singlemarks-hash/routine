//
//  SessionEngine.swift
//  TimeLock
//
//  세션 상태머신.
//  이벤트 소스: 백그라운드 전환·화면 잠금·앱 강제 종료·촬영 중단·통화 수신·배터리/저장공간.
//  강도 규칙: 매운맛 = 경고 + 10초 유예 / 미친 매운맛 = 즉시 실패 + 벌점 2배.
//  완주 판정: '순수 촬영 시간'이 목표에 도달하면 자동 종료 (통화 일시정지 시간은 제외 →
//  통화 시간만큼 종료가 자연히 뒤로 밀린다).
//

import Foundation
import SwiftUI
import SwiftData
import CallKit
import UIKit

@MainActor
final class SessionEngine: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording
        case pausedForCall
        case graceWarning(deadline: Date)   // 매운맛: 앱 안에서의 촬영 중단 경고
        case finished(SessionOutcome)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var recordedSeconds: Int = 0
    @Published var oneMinuteWarningFired = false
    @Published var lastFinishedSession: FocusSession?

    private(set) var session: FocusSession?
    private var modelContext: ModelContext?
    private var tick: Timer?
    private var graceTimer: Timer?
    private var callObserver: CXCallObserver?
    private var isCallActive = false
    private var safetyCheckCounter = 0

    private let graceSeconds = 10
    private let defaults = UserDefaults.standard

    // 킬/크래시 판별용 영속 플래그
    private enum Key {
        static let activeSessionID = "engine.activeSessionID"
        static let backgroundedAt  = "engine.backgroundedAt"   // 이탈로 백그라운드 간 시각
        static let callActive      = "engine.callActive"
    }

    func bind(context: ModelContext) {
        self.modelContext = context
    }

    var progress: Double {
        guard let s = session, s.targetSeconds > 0 else { return 0 }
        return Double(recordedSeconds) / Double(s.targetSeconds)
    }
    var remainingSeconds: Int {
        guard let s = session else { return 0 }
        return max(0, s.targetSeconds - recordedSeconds)
    }

    // MARK: 세션 시작 (알람 해제 = 촬영 시작)

    func start(session: FocusSession) {
        guard phase == .idle || isFinished else { return }
        guard let context = modelContext else { return }

        session.startedAt = .now
        context.insert(session)
        try? context.save()

        do {
            try CameraRecorder.shared.startRecording(sessionID: session.id)
        } catch {
            // 카메라 개시 실패 → 안전 종료로 기록
            finalize(session: session, outcome: .safetyEnded, note: "카메라 시작 실패")
            return
        }

        self.session = session
        recordedSeconds = 0
        oneMinuteWarningFired = false
        phase = .recording
        isCallActive = false
        safetyCheckCounter = 0

        defaults.set(session.id.uuidString, forKey: Key.activeSessionID)
        defaults.removeObject(forKey: Key.backgroundedAt)

        startCallObserver()
        startTick()
        UIApplication.shared.isIdleTimerDisabled = true   // 화면 자동 꺼짐 방지
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    private var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    // MARK: 틱 (1초)

    private func startTick() {
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func onTick() {
        guard let s = session, phase == .recording else { return }
        recordedSeconds = CameraRecorder.shared.frameCount   // 프레임 수 ≈ 순수 촬영 초

        // 종료 1분 전 예고
        if !oneMinuteWarningFired, remainingSeconds <= 60, remainingSeconds > 0 {
            oneMinuteWarningFired = true
            AlarmScheduler.shared.playChime()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        // 자동 종료 = 완주
        if recordedSeconds >= s.targetSeconds {
            Task { await self.finishCompleted() }
            return
        }
        // 30초마다 안전 점검 (배터리/저장공간)
        safetyCheckCounter += 1
        if safetyCheckCounter % 30 == 0 { checkSafety() }
    }

    // MARK: 완주

    private func finishCompleted() async {
        guard let s = session, phase == .recording else { return }
        phase = .finished(.completed)
        let result = await CameraRecorder.shared.stopRecording()
        applyRecording(result, to: s)
        finalize(session: s, outcome: .completed, note: nil)
    }

    // MARK: 이탈 이벤트 (백그라운드 / 화면 잠금)

    /// ScenePhase.background 또는 화면 잠금(protectedData) 시 호출
    func handleExitEvent() {
        guard let s = session, phase == .recording || phaseIsGrace else { return }
        guard !isCallActive else { return }   // 통화 중 백그라운드는 이탈이 아님

        switch s.intensity {
        case .spicy:
            // 유예 판정은 복귀 시각으로 한다. 지금은 시각만 기록 + 경고 알림.
            if defaults.object(forKey: Key.backgroundedAt) == nil {
                defaults.set(Date().timeIntervalSince1970, forKey: Key.backgroundedAt)
                AlarmScheduler.shared.sendGraceNotification(seconds: graceSeconds)
                CameraRecorder.shared.pause()
            }
        case .insane:
            // 즉시 실패 확정 — 되돌릴 수 없음
            phase = .finished(.exitFailed)
            Task {
                let result = await CameraRecorder.shared.stopPreservingFootage()
                self.applyRecording(result, to: s)
                self.finalize(session: s, outcome: .exitFailed, note: "이탈 즉시 실패")
            }
        }
    }

    /// 포그라운드 복귀 시 호출 — 매운맛 유예 판정
    func handleReturnEvent() {
        guard let s = session else { return }
        guard let exitTS = defaults.object(forKey: Key.backgroundedAt) as? Double else { return }
        defaults.removeObject(forKey: Key.backgroundedAt)
        let away = Date().timeIntervalSince1970 - exitTS

        if s.intensity == .spicy, phase == .recording {
            if away <= Double(graceSeconds) {
                // 무벌점 복귀
                CameraRecorder.shared.resume()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                phase = .finished(.exitFailed)
                Task {
                    let result = await CameraRecorder.shared.stopPreservingFootage()
                    self.applyRecording(result, to: s)
                    self.finalize(session: s, outcome: .exitFailed,
                                  note: "유예 \(graceSeconds)초 초과 (\(Int(away))초)")
                }
            }
        }
    }

    private var phaseIsGrace: Bool {
        if case .graceWarning = phase { return true }
        return false
    }

    // MARK: 긴급 종료

    func emergencyEnd(reason: String?) {
        guard let s = session, phase == .recording || phase == .pausedForCall else { return }
        phase = .finished(.emergency)
        s.emergencyReason = reason
        Task {
            let result = await CameraRecorder.shared.stopPreservingFootage()
            self.applyRecording(result, to: s)
            self.finalize(session: s, outcome: .emergency, note: reason)
        }
    }

    // MARK: 안전 종료 (배터리/저장공간)

    private func checkSafety() {
        let battery = UIDevice.current.batteryLevel
        let plugged = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        if battery >= 0, battery <= 0.05, !plugged {
            safetyEnd(note: "배터리 부족")
            return
        }
        if let values = try? SessionStorage.directory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage,
           free < 500_000_000 {
            safetyEnd(note: "저장 공간 부족")
        }
    }

    func safetyEnd(note: String) {
        guard let s = session, phase == .recording || phase == .pausedForCall else { return }
        phase = .finished(.safetyEnded)
        Task {
            let result = await CameraRecorder.shared.stopPreservingFootage()
            self.applyRecording(result, to: s)
            self.finalize(session: s, outcome: .safetyEnded, note: note)
        }
    }

    // MARK: 통화 수신 — 벌점 없는 일시정지 / 자동 재개

    private func startCallObserver() {
        let observer = CXCallObserver()
        observer.setDelegate(self, queue: .main)
        callObserver = observer
    }

    private func callBegan() {
        guard phase == .recording else { return }
        isCallActive = true
        defaults.set(true, forKey: Key.callActive)
        CameraRecorder.shared.pause()
        phase = .pausedForCall
        // recordedSeconds가 멈추므로 종료 시각은 통화 시간만큼 자연히 밀린다.
    }

    private func callEnded() {
        isCallActive = false
        defaults.removeObject(forKey: Key.callActive)
        guard phase == .pausedForCall else { return }
        CameraRecorder.shared.resume()
        phase = .recording
    }

    // MARK: 마무리 & 원장 기록

    private func applyRecording(_ result: CameraRecorder.RecordingResult?, to session: FocusSession) {
        if let r = result {
            session.videoFileName = r.videoFileName
            session.thumbnailFileName = r.thumbnailFileName
            session.recordedSeconds = r.frames
        } else {
            session.recordedSeconds = recordedSeconds
        }
    }

    private func finalize(session s: FocusSession, outcome: SessionOutcome, note: String?) {
        guard let context = modelContext else { return }
        s.outcome = outcome
        s.endedAt = .now
        if s.modelContext == nil { context.insert(s) }

        if let (type, points) = ScoreRules.points(for: outcome, intensity: s.intensity) {
            context.insert(ScoreEvent(type: type, points: points,
                                      sessionID: s.id, intensity: s.intensity, note: note))
        }
        try? context.save()

        lastFinishedSession = s
        phase = .finished(outcome)
        cleanupRuntime()
    }

    private func cleanupRuntime() {
        tick?.invalidate(); tick = nil
        graceTimer?.invalidate(); graceTimer = nil
        callObserver = nil
        isCallActive = false
        defaults.removeObject(forKey: Key.activeSessionID)
        defaults.removeObject(forKey: Key.backgroundedAt)
        defaults.removeObject(forKey: Key.callActive)
        UIApplication.shared.isIdleTimerDisabled = false
        session = nil
    }

    func reset() {
        phase = .idle
        recordedSeconds = 0
        lastFinishedSession = nil
    }

    // MARK: 노쇼 스위퍼 & 고아 세션 복구

    /// 지난 발생 중 시작되지 않은 예약을 탈락 처리한다. (앱 포그라운드/주기 호출)
    func sweepNoShows(reservations: [Reservation], intensity: Intensity, graceWindow: TimeInterval = 300) {
        guard let context = modelContext else { return }
        let calendar = Calendar.current
        let now = Date()

        var existing: Set<String> = []
        if let sessions = try? context.fetch(FetchDescriptor<FocusSession>()) {
            for s in sessions {
                if let rid = s.reservationID, let sched = s.scheduledAt {
                    existing.insert("\(rid.uuidString)-\(Int(sched.timeIntervalSince1970))")
                }
            }
        }

        for reservation in reservations where reservation.isActive {
            for offset in [-1, 0] {   // 어제~오늘 발생분 점검
                guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                      let fire = reservation.occurrence(on: day, calendar: calendar) else { continue }
                guard fire.addingTimeInterval(graceWindow) < now else { continue }   // 5분 창이 끝났고
                guard fire > now.addingTimeInterval(-86_400 * 2) else { continue }
                let key = "\(reservation.id.uuidString)-\(Int(fire.timeIntervalSince1970))"
                guard !existing.contains(key) else { continue }

                let noShow = FocusSession(activityName: reservation.name, tag: reservation.tag,
                                          intensity: intensity, scheduledAt: fire,
                                          targetSeconds: reservation.durationMinutes * 60,
                                          reservationID: reservation.id)
                noShow.outcome = .noShow
                noShow.endedAt = fire.addingTimeInterval(graceWindow)
                context.insert(noShow)
                if let (type, points) = ScoreRules.points(for: .noShow, intensity: intensity) {
                    context.insert(ScoreEvent(type: type, points: points,
                                              sessionID: noShow.id, intensity: intensity,
                                              note: "5분 내 미시작"))
                }
                existing.insert(key)
            }
        }
        try? context.save()
    }

    /// 앱 재실행 시, 종료되지 못한 세션(킬/크래시)을 판별해 기록한다.
    /// - 이탈로 백그라운드 간 뒤 종료됨 → 이탈 실패(강제 종료)
    /// - 포그라운드 도중 사라짐 → 크래시로 보고 안전 종료 (벌점 없음, 촬영분 보존)
    func recoverOrphanIfNeeded() {
        guard let context = modelContext,
              let idString = defaults.string(forKey: Key.activeSessionID),
              let id = UUID(uuidString: idString) else { return }

        let descriptor = FetchDescriptor<FocusSession>(predicate: #Predicate { $0.id == id })
        guard let orphan = try? context.fetch(descriptor).first, orphan.outcome == nil else {
            defaults.removeObject(forKey: Key.activeSessionID)
            return
        }
        let wasBackgrounded = defaults.object(forKey: Key.backgroundedAt) != nil
        let wasInCall = defaults.bool(forKey: Key.callActive)
        let outcome: SessionOutcome = (wasBackgrounded && !wasInCall) ? .exitFailed : .safetyEnded
        orphan.outcome = outcome
        orphan.endedAt = .now
        if let (type, points) = ScoreRules.points(for: outcome, intensity: orphan.intensity) {
            context.insert(ScoreEvent(type: type, points: points, sessionID: orphan.id,
                                      intensity: orphan.intensity,
                                      note: outcome == .exitFailed ? "앱 강제 종료" : "비정상 종료 복구"))
        }
        try? context.save()
        defaults.removeObject(forKey: Key.activeSessionID)
        defaults.removeObject(forKey: Key.backgroundedAt)
        defaults.removeObject(forKey: Key.callActive)
    }
}

// MARK: - CXCallObserverDelegate

extension SessionEngine: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor in
            if call.hasEnded {
                self.callEnded()
            } else if call.hasConnected || (!call.isOutgoing && !call.hasEnded) {
                self.callBegan()
            }
        }
    }
}
