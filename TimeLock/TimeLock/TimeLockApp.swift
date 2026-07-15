//
//  TimeLockApp.swift
//  TimeLock — 앵그리모티
//
//  알람을 끄는 유일한 방법, 촬영 시작.
//

import SwiftUI
import SwiftData
import UserNotifications
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@main
struct TimeLockApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let container: ModelContainer = {
        let schema = Schema([Reservation.self, FocusSession.self, ScoreEvent.self])
        let config = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("SwiftData 컨테이너 생성 실패: \(error)")
        }
    }()

    @StateObject private var app = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.engine)
                .environmentObject(AccountStore.shared)
                .environmentObject(SubscriptionManager.shared)
                .environmentObject(AlarmScheduler.shared)
                .preferredColorScheme(.dark)
                .tint(TL.rec)
                .onAppear {
                    app.bind(context: container.mainContext)
                }
                .onOpenURL { url in
                    // Google 로그인 콜백 (Info.plist의 REVERSED_CLIENT_ID 스킴)
                    #if canImport(GoogleSignIn)
                    GIDSignIn.sharedInstance.handle(url)
                    #endif
                }
        }
        .modelContainer(container)
    }
}

// MARK: - 알림 딜리게이트 (알람 탭 → 알람 화면 라우팅)

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// 화면 회전 정책 — 평소에는 세로 고정, 세션 관련 화면에서만 가로 허용 (AppState가 갱신)
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            AccountStore.shared.configureBackendIfAvailable()
        }
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }

    // 포그라운드에서도 알람 알림을 표시
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let kind = notification.request.content.userInfo["kind"] as? String
        if kind == "alarm" {
            // 앱이 떠 있으면 배너 대신 알람 화면을 직접 띄운다
            await MainActor.run { AppState.shared.checkDueAlarm() }
            return []
        }
        if kind == "break" {
            // 앱이 화면에 떠 있으면 중단 오버레이가 이미 안내 중 — 배너 생략
            return []
        }
        // 세션 중 '알림차단'이 켜져 있으면 화면에 뜨는 모든 배너를 숨긴다
        if await AlarmScheduler.shared.muteAllNotifications {
            return []
        }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if info["kind"] as? String == "alarm",
           let idString = info["reservationID"] as? String,
           let id = UUID(uuidString: idString) {
            await MainActor.run { AppState.shared.presentAlarm(reservationID: id) }
        }
    }
}

// MARK: - 전역 상태

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let engine = SessionEngine()

    // 라우팅
    enum Route: Equatable {
        case none
        case alarm(reservationID: UUID, fireDate: Date)
        case mountGuide(pending: PendingSession)
        case session
        case result
    }
    @Published var route: Route = .none {
        didSet { updateOrientationLock() }
    }

    /// 구도 단계에서 선택하는 촬영 방향. 세션 화면은 이 방향으로 잠긴다.
    @Published var sessionOrientation: SessionOrientation = .portrait {
        didSet { updateOrientationLock() }
    }

    /// 세션 화면 진입 후 카운트다운 '시작!'에 녹화를 개시할 대기 세션.
    private var armedPending: PendingSession?

    struct PendingSession: Equatable {
        var activityName: String
        var tag: String
        var targetSeconds: Int
        var scheduledAt: Date?
        var reservationID: UUID?
    }

    // 온보딩 & 강도 (앱 전역 단일 값)
    // 주의: ObservableObject 내부의 @AppStorage는 뷰 갱신을 트리거하지 않으므로
    // @Published + UserDefaults 백킹으로 구현한다.
    @Published var onboarded: Bool {
        didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") }
    }
    @Published private var intensityRaw: String {
        didSet { UserDefaults.standard.set(intensityRaw, forKey: "intensity") }
    }
    @Published private var pendingDowngrade: Bool {
        didSet { UserDefaults.standard.set(pendingDowngrade, forKey: "pendingDowngrade") }
    }
    @Published private var downgradeEffectiveDay: Double {
        didSet { UserDefaults.standard.set(downgradeEffectiveDay, forKey: "downgradeEffectiveDay") }
    }

    private init() {
        let d = UserDefaults.standard
        onboarded = d.bool(forKey: "onboarded")
        intensityRaw = d.string(forKey: "intensity") ?? Intensity.spicy.rawValue
        pendingDowngrade = d.bool(forKey: "pendingDowngrade")
        downgradeEffectiveDay = d.double(forKey: "downgradeEffectiveDay")
    }

    private var modelContext: ModelContext?
    private var sweepTimer: Timer?

    var intensity: Intensity {
        Intensity(rawValue: intensityRaw) ?? .spicy
    }

    /// 상향은 즉시, 하향은 다음날 0시 적용
    func requestIntensityChange(to target: Intensity) {
        if target == .insane {
            guard insaneUnlocked else { return }
            intensityRaw = target.rawValue
            pendingDowngrade = false
        } else {
            guard intensity == .insane else { return }
            let tomorrow = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: .now)!)
            pendingDowngrade = true
            downgradeEffectiveDay = tomorrow.timeIntervalSince1970
        }
    }

    var downgradePending: Bool { pendingDowngrade }
    var downgradeDate: Date? { pendingDowngrade ? Date(timeIntervalSince1970: downgradeEffectiveDay) : nil }

    private func applyPendingDowngradeIfDue() {
        if pendingDowngrade, Date().timeIntervalSince1970 >= downgradeEffectiveDay {
            intensityRaw = Intensity.spicy.rawValue
            pendingDowngrade = false
        }
    }

    /// 미친 매운맛 해금: 매운맛 완주 3회
    var insaneUnlocked: Bool { spicyCompletions >= 3 }
    @Published private(set) var spicyCompletions = 0

    // MARK: 바인딩 & 라이프사이클

    func bind(context: ModelContext) {
        guard modelContext == nil else { return }
        modelContext = context
        AccountStore.shared.bind(context: context)
        AccountStore.shared.onUserChanged = { [weak self] in
            self?.handleUserChanged()
        }
        engine.bind(context: context)
        engine.onFinalized = { [weak self] in
            self?.sessionFinished()
        }
        engine.recoverOrphanIfNeeded()
        purgeUnsavedVideos()
        refreshDerived()
        applyPendingDowngradeIfDue()
        sweepNoShows()
        checkDueAlarm()
        rescheduleAlarmsForCurrentUser()
        Task { await AlarmScheduler.shared.refreshAuthorizationStatus() }

        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sweepNoShows()
                self?.checkDueAlarm()
                self?.applyPendingDowngradeIfDue()
            }
        }
    }

    func onScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            engine.handleReturnEvent()
            applyPendingDowngradeIfDue()
            sweepNoShows()
            checkDueAlarm()
            refreshDerived()
        case .background:
            engine.handleExitEvent()
        default:
            break
        }
    }

    func refreshDerived() {
        guard let context = modelContext else { return }
        let spicyRaw = Intensity.spicy.rawValue
        let completedRaw = SessionOutcome.completed.rawValue
        let owner = AccountStore.shared.currentUserID
        let descriptor = FetchDescriptor<FocusSession>(
            predicate: #Predicate { $0.intensityRaw == spicyRaw && $0.outcomeRaw == completedRaw && $0.ownerUserID == owner })
        spicyCompletions = (try? context.fetchCount(descriptor)) ?? 0
    }

    // MARK: 화면 회전 정책

    /// 구도·세션·결과 화면은 '선택한 방향 하나로만' 잠근다.
    /// 단일 방향만 허용하므로 촬영 중 기기를 돌려도 UI가 요동치지 않고,
    /// 구도 단계에서 세로/가로를 고르면 그 방향으로 부드럽게 회전한다.
    private func updateOrientationLock() {
        let mask: UIInterfaceOrientationMask
        switch route {
        case .mountGuide, .session:
            mask = sessionOrientation.interfaceMask   // 촬영은 선택한 방향으로 잠금
        default:
            mask = .portrait   // 결과·홈 등 일반 화면은 세로 고정
        }
        guard AppDelegate.orientationLock != mask else { return }
        AppDelegate.orientationLock = mask

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    // MARK: 계정 전환

    private func handleUserChanged() {
        refreshDerived()
        rescheduleAlarmsForCurrentUser()
        sweepNoShows()
        checkDueAlarm()
    }

    func rescheduleAlarmsForCurrentUser() {
        AlarmScheduler.shared.rescheduleAll(reservations: activeReservations())
    }

    /// 결과 화면에서 저장하지 않고 남은 촬영본 정리 (정책: 다운로드하지 않으면 자동 삭제)
    private func purgeUnsavedVideos() {
        guard let context = modelContext else { return }
        let sessions = (try? context.fetch(FetchDescriptor<FocusSession>(
            predicate: #Predicate { $0.videoFileName != nil && $0.outcomeRaw != nil }))) ?? []
        guard !sessions.isEmpty else { return }
        for session in sessions {
            if let url = session.videoURL { try? FileManager.default.removeItem(at: url) }
            session.videoFileName = nil
        }
        try? context.save()
    }

    // MARK: 알람 라우팅

    private func activeReservations() -> [Reservation] {
        guard let context = modelContext else { return [] }
        let owner = AccountStore.shared.currentUserID
        return (try? context.fetch(FetchDescriptor<Reservation>(
            predicate: #Predicate { $0.isActive && $0.ownerUserID == owner }))) ?? []
    }

    /// 지금 알람 창(발생~+10분)에 들어와 있고 아직 시작 안 된 예약이 있으면 알람 화면 표시
    func checkDueAlarm() {
        guard route == .none, engine.session == nil else { return }
        let now = Date()
        let calendar = Calendar.current
        for reservation in activeReservations() {
            for offset in [-1, 0] {
                guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                      let fire = reservation.occurrence(on: day, calendar: calendar) else { continue }
                let window = fire...fire.addingTimeInterval(TimePolicy.startWindowSeconds)
                guard window.contains(now) else { continue }
                guard !sessionExists(reservationID: reservation.id, scheduledAt: fire) else { continue }
                route = .alarm(reservationID: reservation.id, fireDate: fire)
                AlarmScheduler.shared.startAlarmSound()
                return
            }
        }
    }

    func presentAlarm(reservationID: UUID) {
        checkDueAlarm()
    }

    private func sessionExists(reservationID: UUID, scheduledAt: Date) -> Bool {
        guard let context = modelContext else { return false }
        let sessions = (try? context.fetch(FetchDescriptor<FocusSession>(
            predicate: #Predicate { $0.reservationID == reservationID }))) ?? []
        return sessions.contains { s in
            guard let sched = s.scheduledAt else { return false }
            return abs(sched.timeIntervalSince(scheduledAt)) < 60
        }
    }

    func reservation(id: UUID) -> Reservation? {
        activeReservations().first { $0.id == id }
    }

    // MARK: 세션 흐름

    /// 알람 화면 → 거치 가이드
    func proceedToMountGuide(reservation: Reservation, fireDate: Date) {
        let pending = PendingSession(activityName: reservation.name, tag: reservation.tag,
                                     targetSeconds: reservation.durationMinutes * 60,
                                     scheduledAt: fireDate, reservationID: reservation.id)
        route = .mountGuide(pending: pending)
        // 알람은 촬영 시작 시점에만 정지 → 여기서는 계속 울린다
    }

    /// '지금 바로 시작' (예약 없는 즉시 세션)
    func startImmediate(name: String, tag: String, minutes: Int) {
        let pending = PendingSession(activityName: name, tag: tag,
                                     targetSeconds: minutes * 60,
                                     scheduledAt: nil, reservationID: nil)
        route = .mountGuide(pending: pending)
    }

    /// 거치 가이드 → 세션 화면 진입 (이 순간 알람 정지 = 알람 해제).
    /// 실제 녹화는 카운트다운 '시작!' 시점(commitRecording)에 개시하고,
    /// 그동안엔 라이브 프리뷰만 예열해 정지화면 없이 카운트다운을 보여준다.
    func beginRecording(pending: PendingSession) {
        AlarmScheduler.shared.stopAlarmSound()
        armedPending = pending
        route = .session
        CameraRecorder.shared.startPreview()   // 카운트다운 동안 프리뷰 예열(라이브)
    }

    /// 시작 카운트다운이 끝나는 순간 — 실제 녹화 개시.
    func commitRecording() {
        guard let pending = armedPending else { return }
        armedPending = nil
        let session = FocusSession(activityName: pending.activityName, tag: pending.tag,
                                   intensity: intensity,
                                   scheduledAt: pending.scheduledAt,
                                   targetSeconds: pending.targetSeconds,
                                   reservationID: pending.reservationID,
                                   ownerUserID: AccountStore.shared.currentUserID)
        // 카메라 시작이 실패하면 engine이 즉시 finalize → onFinalized가 .result로 덮어쓴다.
        engine.start(session: session, orientation: sessionOrientation)
    }

    /// 알람 화면의 긴급 버튼 — 세션 없이 알람만 종료, 노쇼는 스위퍼가 기록
    func emergencyDismissAlarm() {
        AlarmScheduler.shared.stopAlarmSound()
        route = .none
    }

    /// 알람 화면의 '일정 취소' — 사유와 함께 벌점을 기록하고 홈으로.
    /// 세션 기록이 남으므로 노쇼 스위퍼가 같은 발생 건을 중복 처리하지 않는다.
    func cancelSchedule(reservation: Reservation, fireDate: Date, reason: String) {
        guard let context = modelContext else { return }
        AlarmScheduler.shared.stopAlarmSound()
        AlarmScheduler.shared.cancelAlarmNotifications(reservationID: reservation.id, fireDate: fireDate)

        let session = FocusSession(activityName: reservation.name, tag: reservation.tag,
                                   intensity: intensity, scheduledAt: fireDate,
                                   targetSeconds: reservation.durationMinutes * 60,
                                   reservationID: reservation.id,
                                   ownerUserID: AccountStore.shared.currentUserID)
        session.outcome = .emergency
        session.emergencyReason = reason
        session.endedAt = .now
        context.insert(session)

        if let (type, points) = ScoreRules.points(for: .emergency, intensity: intensity) {
            let event = ScoreEvent(type: type, points: points, sessionID: session.id,
                                   intensity: intensity, note: reason,
                                   ownerUserID: AccountStore.shared.currentUserID)
            context.insert(event)
            AccountStore.shared.mirror(event: event)   // 사유+벌점 클라우드 백업
        }
        try? context.save()
        refreshDerived()
        route = .none
    }

    func sessionFinished() {
        route = .result
        refreshDerived()
    }

    func dismissResult() {
        // 정책: 결과 화면에서 저장하지 않은 촬영본은 여기서 삭제된다
        if let session = engine.lastFinishedSession, session.videoFileName != nil {
            if let url = session.videoURL { try? FileManager.default.removeItem(at: url) }
            session.videoFileName = nil
            try? modelContext?.save()
        }
        engine.reset()
        route = .none
    }

    // MARK: 노쇼

    func sweepNoShows() {
        engine.sweepNoShows(reservations: activeReservations(), intensity: intensity)
    }
}
