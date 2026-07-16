//
//  SessionEngine.swift
//  TimeLock
//
//  세션 상태머신.
//  이벤트 소스: 백그라운드 전환·화면 잠금·앱 강제 종료·촬영 중단·통화 수신·배터리/저장공간.
//  강도 규칙:
//    매운맛     = 긴급 용무 중단(버튼 또는 앱 이탈) 시 10분 재촬영 창.
//                 창 안에 재촬영 시작 = 벌점 없음 / 창 초과 또는 계속 이탈 = 벌점.
//    미친 매운맛 = 유예 없음. 이탈 즉시 실패 + 벌점 2배.
//  완주 판정: '순수 촬영 시간'이 목표에 도달하면 자동 종료 (통화·중단 시간은 제외 →
//  멈춘 시간만큼 종료가 자연히 뒤로 밀린다).
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
        case pausedForBreak(deadline: Date)   // 긴급 용무 중단 — 데드라인 안에 재촬영 시작
        case finished(SessionOutcome)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var recordedSeconds: Int = 0
    @Published var oneMinuteWarningFired = false
    @Published var lastFinishedSession: FocusSession?
    /// 이번 완주로 슬롯이 확장됐을 때의 축하 정보 (연속일, 보너스 점수) — 결과 화면이 파티클로 표시
    @Published private(set) var lastSlotBonus: (days: Int, points: Int)?
    /// 이번 완주로 미친 매운맛이 해제됐을 때의 보너스 점수 — 결과 화면이 배지+파티클로 표시
    @Published private(set) var lastUnlockBonus: Int?

    // 자리비움 감지 정책: 30초 연속 부재 → 경고 배너 + 카운트 +1 (복귀해도 카운트 유지).
    // 경고 3회 누적 또는 경고 후 2분 연속 부재 →
    // 매운맛: 자동 긴급 중단(남은 예산 창, 부재 자체엔 벌점 없음) / 미친 매운맛: 즉시 실패.
    // 벌점은 실패가 확정될 때만 이탈 벌점으로 부과된다.
    @Published private(set) var absenceWarning = false
    private var absencePenaltyApplied = false
    private let absenceWarnSeconds = 30
    private let absencePenaltySeconds = 120
    /// 한 활동에서 자리비움 '경고'가 뜬 누적 횟수 — 2분 내 복귀해도 되돌리지 않는다.
    /// 3번째 경고는 그 자체로 자동 긴급 중단(매운맛)/즉시 실패(미친 매운맛).
    /// 경고 배너가 "n/3" 카운트를 표시할 수 있도록 발행한다.
    @Published private(set) var absenceEpisodeCount = 0
    let absenceMaxEpisodes = 3

    /// finalize 완료 직후 호출 — 결과 화면 라우팅은 이 콜백이 보장한다.
    /// (phase 변화 관찰에만 의존하면 finalize 전 선(先)설정과 겹쳐 전환이 누락될 수 있다)
    var onFinalized: (() -> Void)?

    /// 종료 처리 진행 중 재진입 방지. phase는 finalize에서 단 한 번만 .finished로 바뀐다.
    private var isFinalizing = false

    private(set) var session: FocusSession?
    private var modelContext: ModelContext?
    private var tick: Timer?
    private var callObserver: CXCallObserver?
    private var isCallActive = false
    private var safetyCheckCounter = 0

    private let defaults = UserDefaults.standard

    // 킬/크래시 판별용 영속 플래그
    private enum Key {
        static let activeSessionID = "engine.activeSessionID"
        static let breakDeadline   = "engine.breakDeadline"   // 재촬영 창 마감 시각 (epoch)
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

    func start(session: FocusSession, orientation: SessionOrientation) {
        guard phase == .idle || isFinished else { return }
        guard let context = modelContext else { return }

        session.startedAt = .now
        context.insert(session)
        try? context.save()

        do {
            try CameraRecorder.shared.startRecording(sessionID: session.id, orientation: orientation,
                                                     plannedSeconds: Double(session.targetSeconds))
        } catch {
            // 카메라 개시 실패 → 안전 종료로 기록
            finalize(session: session, outcome: .safetyEnded, note: "카메라 시작 실패")
            return
        }

        self.session = session
        recordedSeconds = 0
        oneMinuteWarningFired = false
        absenceWarning = false
        absencePenaltyApplied = false
        absenceEpisodeCount = 0
        breakBudgetRemaining = TimePolicy.resumeWindowSeconds   // 세션마다 긴급 예산 리필
        phase = .recording
        isCallActive = false
        isFinalizing = false
        safetyCheckCounter = 0

        defaults.set(session.id.uuidString, forKey: Key.activeSessionID)
        defaults.removeObject(forKey: Key.breakDeadline)

        // 촬영 시작과 함께 '알림차단' 기본 활성화 (세션 화면 버튼으로 해제 가능)
        AlarmScheduler.shared.muteAllNotifications = true

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
        guard let s = session, !isFinalizing else { return }
        // 중단 중 — 재촬영 창이 닫히면 실패 확정
        if case .pausedForBreak(let deadline) = phase {
            if Date() >= deadline { failBreakExpired(session: s) }
            return
        }
        guard phase == .recording else { return }
        // 표시·완주 판정용 촬영 시간은 틱(1초)으로 센다.
        // 프레임 기반(프레임 수 × 캡처 간격)은 캡처 간격이 동적이라 표시가
        // 간격 단위로 점프한다 — 통화/중단 동안은 틱이 멈추므로 순수 촬영 시간과 일치.
        recordedSeconds += 1

        // 자리비움 감지 — 경고가 뜨는 순간 카운트(복귀해도 되돌리지 않음).
        // 3번째 경고는 그 자체로 자동 긴급 중단(매운맛) / 즉시 실패(미친 매운맛).
        // 경고 후 2분 안에 돌아오지 않아도 동일하게 중단/실패 처리.
        let absent = CameraRecorder.shared.absentSeconds
        if absent >= absenceWarnSeconds {
            if !absenceWarning {
                absenceWarning = true
                absenceEpisodeCount += 1
                AlarmScheduler.shared.playChime()
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                if absenceEpisodeCount >= absenceMaxEpisodes {
                    handleAbsenceEvent(session: s,
                                       insaneNote: "자리비움 경고 \(absenceMaxEpisodes)회 누적 — 즉시 실패")
                    return
                }
            }
            if absent >= absencePenaltySeconds, !absencePenaltyApplied {
                absencePenaltyApplied = true
                handleAbsenceEvent(session: s,
                                   insaneNote: "자리비움 \(absencePenaltySeconds / 60)분 — 즉시 실패")
                return
            }
        } else if absenceWarning {
            // 사람이 돌아옴 — 경고는 내리지만 누적 카운트는 유지된다
            absenceWarning = false
            absencePenaltyApplied = false
        }

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
        guard let s = session, phase == .recording, !isFinalizing else { return }
        isFinalizing = true
        let result = await CameraRecorder.shared.stopRecording()
        applyRecording(result, to: s)
        finalize(session: s, outcome: .completed, note: nil)
    }

    // MARK: 긴급 용무 중단 — 10분 재촬영 창 (매운맛)

    /// 세션당 긴급 용무 총 허용 시간(예산). 재촬영해도 리셋되지 않고 누적 차감된다.
    /// 예: 1분 쓰고 재촬영 → 다음 긴급 용무는 9분부터 시작.
    /// 소진되면 세션 화면이 긴급 버튼을 비활성화한다 (중단 중 00:00 도달은 틱이 자동 실패 처리).
    @Published private(set) var breakBudgetRemaining: TimeInterval = TimePolicy.resumeWindowSeconds

    /// 촬영을 잠시 중단한다. 데드라인 안에 재촬영을 시작하면 벌점이 없다.
    /// 세션 화면의 '긴급 용무' 버튼과 앱 이탈(백그라운드/화면 잠금)이 공통으로 사용한다.
    func startBreak() {
        guard let s = session, phase == .recording, s.intensity == .spicy else { return }
        // 남은 예산만큼만 창을 연다 — 총 10분을 다 썼으면 즉시 실패 처리
        guard breakBudgetRemaining >= 1 else {
            failBreakExpired(session: s)
            return
        }
        let deadline = Date().addingTimeInterval(breakBudgetRemaining)
        CameraRecorder.shared.pause()
        phase = .pausedForBreak(deadline: deadline)
        defaults.set(deadline.timeIntervalSince1970, forKey: Key.breakDeadline)
        AlarmScheduler.shared.scheduleBreakNotifications(deadline: deadline)
    }

    /// 재촬영 시작 — 창 안이면 벌점 없이 촬영이 이어진다.
    /// 사용한 만큼 예산에서 차감되어 다음 긴급 용무는 남은 시간부터 시작한다.
    func resumeFromBreak() {
        guard case .pausedForBreak(let deadline) = phase, let s = session, !isFinalizing else { return }
        guard Date() < deadline else {
            failBreakExpired(session: s)
            return
        }
        breakBudgetRemaining = max(0, deadline.timeIntervalSinceNow)
        CameraRecorder.shared.resume()
        // 재촬영 시작은 새 에피소드 — 남아 있던 부재 판정 상태를 비운다
        absenceWarning = false
        absencePenaltyApplied = false
        phase = .recording
        defaults.removeObject(forKey: Key.breakDeadline)
        AlarmScheduler.shared.cancelBreakNotifications()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 재촬영 창 초과 — 벌점과 함께 실패 확정
    private func failBreakExpired(session s: FocusSession) {
        guard !isFinalizing else { return }
        isFinalizing = true
        AlarmScheduler.shared.cancelBreakNotifications()
        Task {
            let result = await CameraRecorder.shared.stopPreservingFootage()
            self.applyRecording(result, to: s)
            self.finalize(session: s, outcome: .exitFailed,
                          note: "\(TimePolicy.resumeWindowMinutes)분 내 재촬영 없음")
        }
    }

    // MARK: 이탈 이벤트 (백그라운드 / 화면 잠금)

    /// ScenePhase.background 또는 화면 잠금(protectedData) 시 호출
    func handleExitEvent() {
        guard let s = session, !isFinalizing else { return }
        guard !isCallActive else { return }   // 통화 중 백그라운드는 이탈이 아님

        switch s.intensity {
        case .spicy:
            // 이탈 = 긴급 용무 중단과 동일 취급. 이미 중단 중이면 데드라인 유지.
            if phase == .recording { startBreak() }
        case .insane:
            guard phase == .recording else { return }
            // 즉시 실패 확정 — 되돌릴 수 없음
            isFinalizing = true
            Task {
                let result = await CameraRecorder.shared.stopPreservingFootage()
                self.applyRecording(result, to: s)
                self.finalize(session: s, outcome: .exitFailed, note: "이탈 즉시 실패")
            }
        }
    }

    /// 포그라운드 복귀 시 호출 — 창이 이미 닫혔으면 실패 확정,
    /// 아직 열려 있으면 세션 화면의 재촬영 오버레이가 이어받는다.
    func handleReturnEvent() {
        guard let s = session else { return }
        if case .pausedForBreak(let deadline) = phase, Date() >= deadline {
            failBreakExpired(session: s)
        }
    }

    private var phaseIsBreak: Bool {
        if case .pausedForBreak = phase { return true }
        return false
    }

    // MARK: 긴급 종료 (세션 포기 — 벌점)

    func emergencyEnd(reason: String?) {
        guard let s = session, !isFinalizing,
              phase == .recording || phase == .pausedForCall || phaseIsBreak else { return }
        isFinalizing = true
        AlarmScheduler.shared.cancelBreakNotifications()
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
        guard let s = session, !isFinalizing,
              phase == .recording || phase == .pausedForCall || phaseIsBreak else { return }
        isFinalizing = true
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
            session.recordedSeconds = r.recordedSeconds
        } else {
            session.recordedSeconds = recordedSeconds
        }
    }

    /// 연속 달성일이 슬롯 확장 단계를 '이번에' 넘었으면 보너스 상점 +5를 지급한다.
    /// 같은 연속 구간에서 같은 단계를 두 번 받지 않도록 계정별로 최고 지급 단계를 기억하고,
    /// 연속이 끊겨 처음부터 다시 쌓으면 단계 도달 시 다시 받을 수 있다.
    private func awardSlotBonusIfTierCrossed(session s: FocusSession, context: ModelContext) {
        let owner = s.ownerUserID
        let all = (try? context.fetch(FetchDescriptor<FocusSession>(
            predicate: #Predicate { $0.ownerUserID == owner }))) ?? []
        let streak = SlotPolicy.currentStreak(sessions: all)

        let key = "slotBonus.awardedTier.\(owner)"
        var awardedTier = defaults.integer(forKey: key)
        if streak < awardedTier { awardedTier = 0 }   // 연속이 끊겼다 다시 쌓는 중 → 초기화

        var totalBonus = 0
        var crossedDays = 0
        for tier in SlotPolicy.tiers where tier.days <= streak && tier.days > awardedTier {
            let event = ScoreEvent(type: .slotBonus, points: 5,
                                   sessionID: s.id, intensity: s.intensity,
                                   note: "연속 \(tier.days)일 달성 — 활동 슬롯 확장 보너스",
                                   ownerUserID: owner)
            context.insert(event)
            AccountStore.shared.mirror(event: event)
            totalBonus += 5
            crossedDays = tier.days
            awardedTier = tier.days
        }
        defaults.set(awardedTier, forKey: key)
        if totalBonus > 0 {
            lastSlotBonus = (days: crossedDays, points: totalBonus)
        }
    }

    /// 매운맛 완주 3회로 미친 매운맛이 '이번 완주로' 해제됐으면 보너스 상점 +5를 지급한다.
    /// 해제는 되돌아가지 않으므로 계정별로 평생 1회만 지급한다.
    private func awardUnlockBonusIfJustUnlocked(session s: FocusSession, context: ModelContext) {
        guard s.intensity == .spicy else { return }   // 해제 조건은 '매운맛' 완주만 센다
        let owner = s.ownerUserID
        let key = "unlockBonus.awarded.\(owner)"
        guard !defaults.bool(forKey: key) else { return }

        let spicyRaw = Intensity.spicy.rawValue
        let completedRaw = SessionOutcome.completed.rawValue
        let count = (try? context.fetchCount(FetchDescriptor<FocusSession>(
            predicate: #Predicate {
                $0.ownerUserID == owner && $0.intensityRaw == spicyRaw && $0.outcomeRaw == completedRaw
            }))) ?? 0
        guard count >= 3 else { return }

        let event = ScoreEvent(type: .unlockBonus, points: 5,
                               sessionID: s.id, intensity: s.intensity,
                               note: "매운맛 완주 3회 — 미친 매운맛 잠금 해제 보너스",
                               ownerUserID: owner)
        context.insert(event)
        AccountStore.shared.mirror(event: event)
        defaults.set(true, forKey: key)
        lastUnlockBonus = 5
    }

    /// 부재 확정 처리 (경고 3회 누적 또는 2분 연속 부재) — 부재 자체엔 벌점 없음.
    /// 매운맛: 긴급 용무 버튼을 누른 것과 동일하게 자동 중단(남은 예산만큼 재촬영 창).
    ///         반복될수록 예산이 닳아 결국 창 만료/예산 소진으로 실패에 수렴한다.
    /// 미친 매운맛: 긴급 용무가 없으므로 즉시 실패(이탈 벌점).
    private func handleAbsenceEvent(session s: FocusSession, insaneNote: String) {
        if s.intensity == .insane {
            failFromAbsence(session: s, note: insaneNote)
            return
        }
        AlarmScheduler.shared.playChime()
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        absenceWarning = false
        startBreak()   // 자동 긴급 용무 — 남은 예산만큼 10분 창이 열린다
    }

    /// 부재로 인한 실패 확정 (미친 매운맛 즉시 / 매운맛 3회 반복)
    private func failFromAbsence(session s: FocusSession, note: String) {
        guard !isFinalizing else { return }
        isFinalizing = true
        Task {
            let result = await CameraRecorder.shared.stopPreservingFootage()
            self.applyRecording(result, to: s)
            self.finalize(session: s, outcome: .exitFailed, note: note)
        }
    }

    private func finalize(session s: FocusSession, outcome: SessionOutcome, note: String?) {
        guard let context = modelContext else { return }
        s.outcome = outcome
        s.endedAt = .now
        if s.modelContext == nil { context.insert(s) }

        if let (type, points) = ScoreRules.points(for: outcome, intensity: s.intensity,
                                                  durationMinutes: s.targetSeconds / 60) {
            let event = ScoreEvent(type: type, points: points,
                                   sessionID: s.id, intensity: s.intensity, note: note,
                                   ownerUserID: s.ownerUserID)
            context.insert(event)
            AccountStore.shared.mirror(event: event)
        }
        // 이번 완주로 연속 달성일이 슬롯 확장 단계(3·5·7·10·30일)를 넘었으면 보너스 상점 +5
        // 매운맛 완주 3회째라면 미친 매운맛 해제 보너스 +5 (평생 1회)
        lastSlotBonus = nil
        lastUnlockBonus = nil
        if outcome == .completed {
            awardSlotBonusIfTierCrossed(session: s, context: context)
            awardUnlockBonusIfJustUnlocked(session: s, context: context)
        }
        try? context.save()

        // 결과 데이터를 모두 준비한 뒤에 딱 한 번 phase를 바꾸고, 라우팅 콜백을 쏜다.
        lastFinishedSession = s
        phase = .finished(outcome)
        cleanupRuntime()
        onFinalized?()
    }

    private func cleanupRuntime() {
        tick?.invalidate(); tick = nil
        callObserver = nil
        isCallActive = false
        isFinalizing = false
        AlarmScheduler.shared.muteAllNotifications = false   // 세션 종료 시 알림차단 해제
        defaults.removeObject(forKey: Key.activeSessionID)
        defaults.removeObject(forKey: Key.breakDeadline)
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
    func sweepNoShows(reservations: [Reservation], intensity: Intensity,
                      graceWindow: TimeInterval = TimePolicy.startWindowSeconds) {
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
                guard fire.addingTimeInterval(graceWindow) < now else { continue }   // 10분 창이 끝났고
                guard fire > now.addingTimeInterval(-86_400 * 2) else { continue }
                let key = "\(reservation.id.uuidString)-\(Int(fire.timeIntervalSince1970))"
                guard !existing.contains(key) else { continue }

                let noShow = FocusSession(activityName: reservation.name, tag: reservation.tag,
                                          intensity: intensity, scheduledAt: fire,
                                          targetSeconds: reservation.durationMinutes * 60,
                                          reservationID: reservation.id,
                                          ownerUserID: reservation.ownerUserID)
                noShow.outcome = .noShow
                noShow.endedAt = fire.addingTimeInterval(graceWindow)
                context.insert(noShow)
                if let (type, points) = ScoreRules.points(for: .noShow, intensity: intensity,
                                                          durationMinutes: reservation.durationMinutes) {
                    let event = ScoreEvent(type: type, points: points,
                                           sessionID: noShow.id, intensity: intensity,
                                           note: "\(TimePolicy.startWindowMinutes)분 내 미시작",
                                           ownerUserID: reservation.ownerUserID)
                    context.insert(event)
                    AccountStore.shared.mirror(event: event)
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
        let wasOnBreak = defaults.object(forKey: Key.breakDeadline) != nil
        let wasInCall = defaults.bool(forKey: Key.callActive)
        let outcome: SessionOutcome = (wasOnBreak && !wasInCall) ? .exitFailed : .safetyEnded
        orphan.outcome = outcome
        orphan.endedAt = .now
        if let (type, points) = ScoreRules.points(for: outcome, intensity: orphan.intensity,
                                                  durationMinutes: orphan.targetSeconds / 60) {
            let event = ScoreEvent(type: type, points: points, sessionID: orphan.id,
                                   intensity: orphan.intensity,
                                   note: outcome == .exitFailed ? "이탈 후 앱 종료" : "비정상 종료 복구",
                                   ownerUserID: orphan.ownerUserID)
            context.insert(event)
            AccountStore.shared.mirror(event: event)
        }
        try? context.save()
        defaults.removeObject(forKey: Key.activeSessionID)
        defaults.removeObject(forKey: Key.breakDeadline)
        defaults.removeObject(forKey: Key.callActive)
        AlarmScheduler.shared.cancelBreakNotifications()
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
