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
            // 유휴(홈) 상태일 때만 알람 화면을 직접 띄우거나 배너로 폴백한다. 세션 촬영·거치·결과
            // 화면 등 이미 몰입 중이면 방해하지 않고 억제한다(무음). 배달만으로 영구 pending을 남기지
            // 않도록 라우팅 자체도 유휴일 때만 시도한다. [P2-2 + audit: 세션 중 알람 방해·강제진입 방지]
            return await MainActor.run { () -> UNNotificationPresentationOptions in
                let app = AppState.shared
                guard app.isIdleForAlarm else { return [] }
                if let idStr = notification.request.content.userInfo["reservationID"] as? String,
                   let id = UUID(uuidString: idStr) {
                    app.presentAlarm(reservationID: id)
                } else {
                    app.checkDueAlarm()
                }
                // 유휴인데도 못 띄운 경우(계정 동기화 지연 등)에만 배너·소리로 폴백
                return app.isShowingAlarm ? [] : [.banner, .sound]
            }
        }
        if kind == "break" {
            // 앱이 화면에 떠 있으면 중단 오버레이가 이미 안내 중 — 배너 생략
            return []
        }
        // 세션 중 '알림차단'이 켜져 있으면 화면에 뜨는 모든 배너를 숨긴다
        if AlarmScheduler.shared.muteAllNotifications {
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
        /// 그룹 예약은 방의 강도를 전역 설정 대신 사용
        var intensityOverride: Intensity? = nil
        /// 알람 화면에서 진입했는가 — 취소 시 알람으로 되돌릴지(true) 홈/방으로 나갈지(false) 결정. [P3-4]
        var enteredFromAlarm: Bool = false
    }

    // 온보딩은 '앱/기기 최초 안내'라 기기 전역이 맞다 (계정별 아님).
    // 강도·하향예약은 계정별(#19) — 공유 기기에서 A의 미친맛 설정이 B에게 새지 않도록 owner로 분리.
    // 주의: ObservableObject 내부의 @AppStorage는 뷰 갱신을 트리거하지 않으므로
    // @Published + UserDefaults 백킹으로 구현한다.
    @Published var onboarded: Bool {
        didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") }
    }
    @Published private var intensityRaw: String {
        didSet { UserDefaults.standard.set(intensityRaw, forKey: "intensity.\(AccountStore.shared.currentUserID)") }
    }
    @Published private var pendingDowngrade: Bool {
        didSet { UserDefaults.standard.set(pendingDowngrade, forKey: "pendingDowngrade.\(AccountStore.shared.currentUserID)") }
    }
    @Published private var downgradeEffectiveDay: Double {
        didSet { UserDefaults.standard.set(downgradeEffectiveDay, forKey: "downgradeEffectiveDay.\(AccountStore.shared.currentUserID)") }
    }

    private init() {
        let d = UserDefaults.standard
        let owner = AccountStore.shared.currentUserID
        onboarded = d.bool(forKey: "onboarded")
        intensityRaw = d.string(forKey: "intensity.\(owner)") ?? Intensity.spicy.rawValue
        pendingDowngrade = d.bool(forKey: "pendingDowngrade.\(owner)")
        downgradeEffectiveDay = d.double(forKey: "downgradeEffectiveDay.\(owner)")
    }

    /// 계정 전환(로그인·로그아웃) 시 그 계정의 강도·하향예약을 다시 불러온다 (#19 — 강도 계정별)
    func reloadForAccount() {
        let d = UserDefaults.standard
        let owner = AccountStore.shared.currentUserID
        intensityRaw = d.string(forKey: "intensity.\(owner)") ?? Intensity.spicy.rawValue
        pendingDowngrade = d.bool(forKey: "pendingDowngrade.\(owner)")
        downgradeEffectiveDay = d.double(forKey: "downgradeEffectiveDay.\(owner)")
        applyPendingDowngradeIfDue()
    }

    private var modelContext: ModelContext?
    private var sweepTimer: Timer?

    /// 알림 탭으로 진입한 알람. 콜드 스타트에서 modelContext·계정 로딩이 늦어 즉시 라우팅에
    /// 실패할 수 있으므로, 준비될 때까지(창이 끝날 때까지) 재시도하기 위해 보관한다.
    private var pendingAlarmTapID: UUID?
    private var pendingAlarmTapAt: Date?

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

    /// 미친 매운맛 잠금 해제: 매운맛 완주 3회 — 멤버십 회원은 조건 없이 즉시 사용 가능
    var insaneUnlocked: Bool { spicyCompletions >= 3 || SubscriptionManager.shared.isPro }
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
        GroupStore.shared.bind(context: context)
        Task {
            await AccountStore.shared.syncFromCloud()   // 다른 기기 예약·점수·멤버십 병합
            await GroupStore.shared.refresh()
            refreshDerived()
            rescheduleAlarmsForCurrentUser()
        }
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
            Task {
                await AccountStore.shared.syncFromCloud()   // 다른 기기 예약·점수·멤버십 병합
                await GroupStore.shared.refresh()
                refreshDerived()
                rescheduleAlarmsForCurrentUser()
            }
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
        reloadForAccount()   // #19 — 전환된 계정의 강도·하향예약 반영 (기기 전역 누수 차단)
        refreshDerived()
        rescheduleAlarmsForCurrentUser()
        Task {
            await AccountStore.shared.syncFromCloud()   // 로그인 직후 다른 기기 예약·점수·멤버십 병합
            await GroupStore.shared.refresh()
            refreshDerived()
            rescheduleAlarmsForCurrentUser()
        }
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

    /// 지금 알람 창(발생~+10분)에 들어와 있고 아직 시작 안 된 예약이 있으면 알람 화면 표시.
    /// 알림 탭으로 보류된 알람이 있으면 그것을 '먼저·직접' 라우팅한다(경쟁 상태·계정 필터 회피).
    func checkDueAlarm() {
        routePendingAlarmTapIfPossible()
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

    /// 알림(배너)을 탭해 진입 — 그 예약을 보류로 걸고 즉시 라우팅을 시도한다.
    /// 콜드 스타트로 준비가 안 됐으면 이후 bind·활성화·타이머·계정변경 때 재시도된다.
    func presentAlarm(reservationID: UUID) {
        pendingAlarmTapID = reservationID
        pendingAlarmTapAt = Date()
        routePendingAlarmTapIfPossible()
    }

    /// 탭한 알람을 해당 예약으로 '직접' 라우팅. 준비 전이면 보류를 유지해 다음 기회에 재시도.
    /// 사용자가 명시적으로 탭한 알람이므로 소유 계정 필터 없이 ID로 조회한다(계정 로딩 경쟁 회피).
    private func routePendingAlarmTapIfPossible() {
        guard let id = pendingAlarmTapID, let tappedAt = pendingAlarmTapAt else { return }
        // 탭 후 창(10분)을 넉넉히 지난 보류는 폐기 — 무한 재시도 방지
        if Date().timeIntervalSince(tappedAt) > TimePolicy.startWindowSeconds + 120 {
            pendingAlarmTapID = nil; pendingAlarmTapAt = nil
            return
        }
        guard route == .none, engine.session == nil else { return }   // 다른 화면 중이면 대기
        guard modelContext != nil else { return }                     // 컨텍스트 준비 전 — 재시도
        guard let reservation = reservationByID(id) else { return }   // 계정·동기화 대기 — 재시도
        let now = Date()
        let calendar = Calendar.current
        for offset in [-1, 0] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let fire = reservation.occurrence(on: day, calendar: calendar) else { continue }
            let window = fire...fire.addingTimeInterval(TimePolicy.startWindowSeconds)
            guard window.contains(now) else { continue }
            pendingAlarmTapID = nil; pendingAlarmTapAt = nil
            guard !sessionExists(reservationID: id, scheduledAt: fire) else { return }
            route = .alarm(reservationID: id, fireDate: fire)
            AlarmScheduler.shared.startAlarmSound()
            return
        }
        // 예약은 찾았으나 어떤 창에도 안 들어옴 = 이미 창이 지남 → 보류 폐기
        pendingAlarmTapID = nil; pendingAlarmTapAt = nil
    }

    /// 알림 탭 대상 예약을 소유 계정 무관하게 ID로 조회 (탭한 알람은 계정보다 우선).
    private func reservationByID(_ id: UUID) -> Reservation? {
        guard let context = modelContext else { return nil }
        return (try? context.fetch(FetchDescriptor<Reservation>(
            predicate: #Predicate { $0.id == id && $0.isActive })))?.first
    }

    // MARK: 그룹 활동 시작 (알람을 놓쳤을 때의 보조 진입)

    /// 그룹 방에 연결된 내 활성 예약 (groupID 매칭)
    func groupReservation(roomID: String) -> Reservation? {
        guard let context = modelContext else { return nil }
        let owner = AccountStore.shared.currentUserID
        return (try? context.fetch(FetchDescriptor<Reservation>(
            predicate: #Predicate { $0.groupID == roomID && $0.ownerUserID == owner && $0.isActive })))?.first
    }

    /// '활동 시작하기'가 가능한 발생 시각 — 지금이 창[발생~+10분] 안이고 아직 미시작이면 그 시각, 아니면 nil.
    func startableWindowFire(for reservation: Reservation) -> Date? {
        let now = Date()
        let calendar = Calendar.current
        for offset in [-1, 0] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let fire = reservation.occurrence(on: day, calendar: calendar) else { continue }
            let window = fire...fire.addingTimeInterval(TimePolicy.startWindowSeconds)
            guard window.contains(now), !sessionExists(reservationID: reservation.id, scheduledAt: fire) else { continue }
            return fire
        }
        return nil
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

    /// 지금 알람 화면을 띄우고 있는가 — willPresent 폴백 판정용. [P2-2]
    var isShowingAlarm: Bool {
        if case .alarm = route { return true }
        return false
    }

    /// 알람을 새로 띄워도 되는 유휴 상태인가 (세션·거치·결과·알람 진행 중이 아님).
    /// 세션 중엔 새 알람 배너·소리로 방해하지 않고, 포그라운드 배달이 영구 pending을 남기지 않게 한다. [audit]
    var isIdleForAlarm: Bool {
        route == .none && engine.session == nil
    }

    // MARK: 세션 흐름

    /// 알람 화면(fromAlarm=true) 또는 그룹 카드 등(false) → 거치 가이드.
    /// fromAlarm은 취소 시 되돌아갈 화면을 정한다(알람으로 vs 홈/방으로). [P3-4]
    func proceedToMountGuide(reservation: Reservation, fireDate: Date, fromAlarm: Bool = true) {
        let pending = PendingSession(activityName: reservation.name, tag: reservation.tag,
                                     targetSeconds: reservation.durationMinutes * 60,
                                     scheduledAt: fireDate, reservationID: reservation.id,
                                     intensityOverride: reservation.intensityOverride,
                                     enteredFromAlarm: fromAlarm)
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

    /// 거치 가이드 '취소하기' — 아직 시작 전이므로 아무 기록 없이 되돌아간다.
    /// 알람에서 진입했으면 알람 화면으로(계속 울리는 중), 그룹 카드·즉시 세션이면 홈/방으로. [P3-4]
    func cancelMountGuide(pending: PendingSession) {
        if pending.enteredFromAlarm, let id = pending.reservationID, let fire = pending.scheduledAt {
            route = .alarm(reservationID: id, fireDate: fire)
        } else {
            route = .none
        }
    }

    /// 거치 가이드 '촬영 시작' — 알람 정지 + 세션 무장.
    /// 카운트다운(3·2·1)은 거치 가이드가 자기 라이브 프리뷰 위에서 진행한다
    /// (프리뷰 레이어가 항상 1개라 화면 멈춤·검은 화면이 구조적으로 불가능).
    func beginRecording(pending: PendingSession) {
        AlarmScheduler.shared.stopAlarmSound()
        // 예약 세션이면 이 발생 건의 남은 알림(메인·예고·+5분 재알림)을 여기서 취소한다.
        // 공통 경로라 알람 화면·그룹 카드 등 어느 진입점으로 시작해도 잔여 알림이 안 뜬다. [P2-1]
        if let id = pending.reservationID, let fire = pending.scheduledAt {
            AlarmScheduler.shared.cancelAlarmNotifications(reservationID: id, fireDate: fire)
        }
        armedPending = pending
    }

    /// 카운트다운 '3' 시점 — 녹화를 미리 개시해 준비 시간을 카운트다운이 흡수하게 한다.
    /// (화면 전환은 아직 안 함 — '시작!'에서 enterSessionIfRecording이 담당)
    func startArmedRecording() {
        guard let pending = armedPending else { return }
        armedPending = nil
        let session = FocusSession(activityName: pending.activityName, tag: pending.tag,
                                   intensity: pending.intensityOverride ?? intensity,
                                   scheduledAt: pending.scheduledAt,
                                   targetSeconds: pending.targetSeconds,
                                   reservationID: pending.reservationID,
                                   ownerUserID: AccountStore.shared.currentUserID)
        engine.start(session: session, orientation: sessionOrientation)
    }

    /// 카운트다운 '시작!' — 녹화가 정상 개시됐으면 세션 화면으로 전환.
    /// (카메라 시작 실패로 이미 finalize됐으면 결과 화면 라우팅을 존중해 건드리지 않는다)
    func enterSessionIfRecording() {
        if case .finished = engine.phase { return }
        route = .session
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

        let effectiveIntensity = reservation.intensityOverride ?? intensity
        let session = FocusSession(activityName: reservation.name, tag: reservation.tag,
                                   intensity: effectiveIntensity, scheduledAt: fireDate,
                                   targetSeconds: reservation.durationMinutes * 60,
                                   reservationID: reservation.id,
                                   ownerUserID: AccountStore.shared.currentUserID)
        session.outcome = .emergency
        session.emergencyReason = reason
        session.endedAt = .now
        context.insert(session)

        if let (type, points) = ScoreRules.points(for: .emergency, intensity: effectiveIntensity,
                                                  durationMinutes: reservation.durationMinutes) {
            let event = ScoreEvent(type: type, points: points, sessionID: session.id,
                                   intensity: effectiveIntensity, note: reason,
                                   ownerUserID: AccountStore.shared.currentUserID)
            context.insert(event)
            AccountStore.shared.mirror(event: event)   // 사유+벌점 클라우드 백업
            GroupStore.shared.reportScore(reservation: reservation, points: points)
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
