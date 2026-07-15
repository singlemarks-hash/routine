//
//  SessionView.swift
//  TimeLock
//
//  세션 진행 화면: 남은 시간 시계판, 촬영 중 셀피 프리뷰, 활동명.
//  화면 자동 꺼짐 방지. 통화 수신 시 벌점 없이 일시정지.
//  긴급 용무(매운맛): 촬영을 중단하고 10분 재촬영 창 — 창 안에 재촬영하면 벌점 없음.
//  방향: 구도 단계에서 고른 세로/가로로 잠긴 채 유지된다 (촬영 중 변경 불가).
//

import SwiftUI
import SwiftData

struct SessionView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: SessionEngine
    @EnvironmentObject private var alarm: AlarmScheduler
    @StateObject private var recorder = CameraRecorder.shared

    @State private var showEmergency = false

    /// 세션 방향은 구도 단계에서 확정 — 촬영 내내 고정
    private var isLandscape: Bool { app.sessionOrientation == .landscape }

    var body: some View {
        ZStack {
            TL.ink.ignoresSafeArea()

            if isLandscape {
                landscapeLayout
            } else {
                portraitLayout
            }

            // 통화 일시정지 오버레이
            if engine.phase == .pausedForCall {
                pauseOverlay
            }

            // 긴급 용무 중단 오버레이 — 재촬영 카운트다운
            if case .pausedForBreak(let deadline) = engine.phase {
                BreakOverlay(deadline: deadline)
            }
        }
        .interactiveDismissDisabled()
        .onDisappear { alarm.muteAllNotifications = false }
        .sheet(isPresented: $showEmergency) { insaneEmergencySheet }
    }

    // MARK: 세로 레이아웃 (피그마: Title → 시계 → 시간 → selfie → 버튼 2개)

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            titleHeader
                .padding(.top, 24)

            Spacer()

            FocusDial(remaining: 1 - engine.progress,
                      tint: engine.remainingSeconds <= 60 ? TL.jade : TL.rec)
                .frame(width: 230, height: 230)

            Text(TLFormat.hms(engine.remainingSeconds))
                .font(.tlTimer(36))
                .foregroundStyle(TL.paper)
                .padding(.top, 14)

            Spacer()

            selfieCard(width: 168, height: 224)

            Spacer()

            HStack(spacing: 14) {
                muteButton
                breakButton
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
    }

    // MARK: 가로 레이아웃 (피그마: 좌측 시계+시간 / 우측 상단 버튼, selfie)

    private var landscapeLayout: some View {
        HStack(spacing: 32) {
            VStack(spacing: 10) {
                titleHeader
                FocusDial(remaining: 1 - engine.progress,
                          tint: engine.remainingSeconds <= 60 ? TL.jade : TL.rec)
                    .frame(maxHeight: .infinity)
                Text(TLFormat.hms(engine.remainingSeconds))
                    .font(.tlTimer(28))
                    .foregroundStyle(TL.paper)
            }
            .padding(.vertical, 16)

            VStack(alignment: .trailing, spacing: 16) {
                HStack(spacing: 12) {
                    muteButton
                    breakButton
                }
                Spacer()
                selfieCard(width: 216, height: 148)
                Spacer()
            }
            .padding(.vertical, 16)
        }
        .padding(.horizontal, 28)
    }

    // MARK: 구성 요소

    private var titleHeader: some View {
        VStack(spacing: 4) {
            Text(engine.session?.activityName ?? "")
                .font(.tlTitle(22))
                .foregroundStyle(TL.paper)
                .lineLimit(1)
            if engine.oneMinuteWarningFired {
                Text("1분 뒤 자동 종료됩니다")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TL.jade)
            }
        }
    }

    /// selfie 영역 — 프리뷰 + REC 표시 (촬영 중이므로 카메라 전환은 없음)
    private func selfieCard(width: CGFloat, height: CGFloat) -> some View {
        CameraPreviewView(session: recorder.captureSession, orientation: app.sessionOrientation)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
                    .strokeBorder(TL.hairline, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                HStack(spacing: 5) {
                    Circle().fill(TL.rec).frame(width: 7, height: 7)
                    Text("REC")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(TL.paper)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Capsule().fill(TL.ink.opacity(0.55)))
                .padding(8)
            }
    }

    /// 알림차단 — 앱이 화면에 떠 있는 동안 모든 알림 배너를 숨긴다.
    /// 촬영 시작과 함께 자동으로 켜지며, 켜진 동안 '차단 중'으로 표시된다.
    private var muteButton: some View {
        squareButton(
            title: alarm.muteAllNotifications ? "차단 중" : "알림차단",
            symbol: alarm.muteAllNotifications ? "bell.slash.fill" : "bell.slash",
            active: alarm.muteAllNotifications
        ) {
            alarm.muteAllNotifications.toggle()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// 긴급중단 — 매운맛: 즉시 중단 + 10분 재촬영 창 / 미친 매운맛: 확인 후 즉시 종료
    private var breakButton: some View {
        squareButton(title: "긴급중단", symbol: "light.beacon.max.fill", active: false) {
            if engine.session?.intensity == .insane {
                showEmergency = true
            } else {
                engine.startBreak()
            }
        }
    }

    private func squareButton(title: String, symbol: String, active: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(active ? TL.ink : TL.paper)
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(active ? TL.ink : TL.muted)
            }
            .frame(width: 64, height: 64)
            .background(
                RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                    .fill(active ? TL.paper : TL.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                    .strokeBorder(TL.hairline, lineWidth: active ? 0 : 1)
            )
        }
    }

    private var pauseOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "phone.fill").font(.system(size: 34)).foregroundStyle(TL.amber)
            Text("통화 중 — 일시정지").font(.tlTitle(20)).foregroundStyle(TL.paper)
            Text("벌점 없이 멈춰 있습니다.\n통화가 끝나면 자동으로 재개되고,\n통화 시간만큼 종료가 뒤로 밀립니다.")
                .font(.system(size: 14)).foregroundStyle(TL.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TL.ink.opacity(0.96).ignoresSafeArea())
    }

    // MARK: 긴급 시트 (미친 매운맛 전용 — 되돌릴 수 없어 확인을 거친다)

    private var insaneEmergencySheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("미친 매운맛은 사유 없이 즉시 종료되며 '긴급'으로 구분 표시되고 벌점이 부과됩니다.")
                    .font(.tlBody)
                    .foregroundStyle(TL.muted)

                Button("긴급 종료") {
                    showEmergency = false
                    engine.emergencyEnd(reason: nil)
                }
                .buttonStyle(TLPrimaryButtonStyle())

                Button("계속 진행") { showEmergency = false }
                    .buttonStyle(TLGhostButtonStyle())

                Spacer()
            }
            .padding(20)
            .background(TL.ink)
            .navigationTitle("긴급 종료")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(280)])
        .preferredColorScheme(.dark)
    }
}

// MARK: - 긴급 용무 중단 오버레이 — 재촬영 카운트다운

private struct BreakOverlay: View {
    let deadline: Date

    @EnvironmentObject private var engine: SessionEngine
    @State private var now = Date()
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var remaining: Int { max(0, Int(deadline.timeIntervalSince(now))) }
    private var progress: Double { Double(remaining) / TimePolicy.resumeWindowSeconds }
    private var compact: Bool { verticalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            TLEyebrow(text: "촬영 일시중단", color: TL.amber)
            Text("긴급 용무 중")
                .font(.tlTitle(compact ? 18 : 24))
                .foregroundStyle(TL.paper)
                .padding(.top, 6)

            RECRingDial(progress: progress, live: false,
                        tint: remaining <= 60 ? TL.rec : TL.amber) {
                VStack(spacing: 2) {
                    Text(TLFormat.hms(remaining))
                        .font(.tlTimer(compact ? 30 : 48))
                        .foregroundStyle(TL.paper)
                    Text("안에 재촬영을 시작하세요")
                        .font(.system(size: compact ? 10 : 13, weight: .semibold))
                        .foregroundStyle(TL.muted)
                }
            }
            .frame(width: compact ? 130 : 230, height: compact ? 130 : 230)
            .padding(.top, compact ? 10 : 28)

            Text("창 안에 재촬영을 시작하면 벌점이 없습니다.\n시간이 지나면 벌점과 함께 세션이 종료됩니다.")
                .font(.system(size: compact ? 12 : 14))
                .foregroundStyle(TL.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, compact ? 8 : 22)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    engine.resumeFromBreak()
                } label: {
                    Label("지금 재촬영 시작", systemImage: "record.circle.fill")
                }
                .buttonStyle(TLPrimaryButtonStyle())

                Button("세션 포기 — 벌점 받기") {
                    engine.emergencyEnd(reason: "긴급 용무 지속")
                }
                .buttonStyle(TLGhostButtonStyle(tint: TL.muted))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TL.ink.opacity(0.97).ignoresSafeArea())
        .onReceive(clock) { now = $0 }
    }
}

// MARK: - 결과 화면 (완주 / 실패 / 긴급 / 안전 종료)

struct SessionResultView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: SessionEngine
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var subscription: SubscriptionManager
    @Environment(\.modelContext) private var context
    @Query private var scoreEvents: [ScoreEvent]

    @State private var saving = false
    @State private var saved = false
    @State private var saveError: String?
    @State private var removeWatermark = false

    /// 이 계정의 누적 벌점 횟수
    private var penaltyCount: Int {
        scoreEvents.filter { $0.ownerUserID == account.currentUserID && $0.points < 0 }.count
    }

    var body: some View {
        let session = engine.lastFinishedSession
        let outcome = session?.outcome ?? .completed

        ZStack {
            TL.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    RECRingDial(progress: 1, live: false,
                                tint: outcome.isSuccess ? TL.jade : (outcome.isFailure ? TL.rec : TL.amber)) {
                        Image(systemName: symbol(for: outcome))
                            .font(.system(size: 52, weight: .bold))
                            .foregroundStyle(outcome.isSuccess ? TL.jade : (outcome.isFailure ? TL.rec : TL.amber))
                    }
                    .frame(width: 180, height: 180)
                    .padding(.top, 46)

                    Text(title(for: outcome))
                        .font(.tlTitle(28))
                        .foregroundStyle(TL.paper)
                        .padding(.top, 24)

                    if let s = session {
                        VStack(spacing: 8) {
                            Text(s.activityName)
                                .font(.tlBody).foregroundStyle(TL.muted)
                            Text("순수 촬영 \(TLFormat.hms(s.recordedSeconds)) / 목표 \(TLFormat.hms(s.targetSeconds))")
                                .font(.tlTimer(17)).foregroundStyle(TL.paper)
                            if let (_, points) = ScoreRules.points(for: outcome, intensity: s.intensity) {
                                Text(points > 0 ? "+\(points)점 적립" : "\(points)점 벌점")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(points > 0 ? TL.jade : TL.rec)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Capsule().fill(TL.surface))
                                if points < 0 {
                                    Text("내 누적 벌점 \(penaltyCount)회")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(TL.rec)
                                }
                            } else {
                                Text("벌점 없음")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(TL.amber)
                            }
                        }
                        .padding(.top, 12)
                    }

                    Text(subtitle(for: outcome))
                        .font(.system(size: 14))
                        .foregroundStyle(TL.muted)
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                        .padding(.horizontal, 40)

                    if let s = session, s.videoFileName != nil {
                        downloadSection(session: s)
                            .padding(.top, 24)
                            .padding(.horizontal, 24)
                    }

                    Button("종료") {
                        app.dismissResult()
                    }
                    .buttonStyle(TLPrimaryButtonStyle(tint: outcome.isSuccess ? TL.jade : TL.rec))
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 24)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: 타임랩스 다운로드 — 지금 저장하지 않으면 자동 삭제

    private func downloadSection(session: FocusSession) -> some View {
        TLCard {
            VStack(alignment: .leading, spacing: 12) {
                TLEyebrow(text: "타임랩스")

                if subscription.isPro {
                    Toggle(isOn: $removeWatermark) {
                        Text("워터마크 제거 (타임락 프로)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TL.paper)
                    }
                    .tint(TL.jade)
                }

                Button {
                    save(session: session)
                } label: {
                    Label(saved ? "사진 앱에 저장됨" : (saving ? "저장 중…" : "타임랩스 저장"),
                          systemImage: saved ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                }
                .buttonStyle(TLPrimaryButtonStyle(tint: saved ? TL.jade : TL.paper))
                .disabled(saving || saved)

                if let saveError {
                    Text(saveError)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TL.rec)
                }

                Text(saved
                     ? "저장이 끝나 원본은 기기에서 삭제되었습니다."
                     : "지금 저장하지 않으면 이 화면을 닫을 때 촬영본이 삭제됩니다. 기록과 점수는 유지됩니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(TL.faint)
            }
        }
    }

    private func save(session: FocusSession) {
        guard let url = session.videoURL else { return }
        saveError = nil
        saving = true
        let watermarked = !(subscription.isPro && removeWatermark)
        Task {
            defer { saving = false }
            do {
                try await VideoDownloader.saveToPhotos(videoURL: url, watermarked: watermarked)
                // 정책: 다운로드 완료 즉시 원본 삭제
                try? FileManager.default.removeItem(at: url)
                session.videoFileName = nil
                try? context.save()
                saved = true
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func symbol(for outcome: SessionOutcome) -> String {
        switch outcome {
        case .completed:   return "checkmark"
        case .exitFailed:  return "xmark"
        case .noShow:      return "bell.slash.fill"
        case .emergency:   return "cross.circle"
        case .safetyEnded: return "battery.25percent"
        }
    }
    private func title(for outcome: SessionOutcome) -> String {
        switch outcome {
        case .completed:   return "완주했습니다"
        case .exitFailed:  return "이탈 — 실패"
        case .noShow:      return "노쇼 탈락"
        case .emergency:   return "긴급 종료됨"
        case .safetyEnded: return "안전 종료됨"
        }
    }
    private func subtitle(for outcome: SessionOutcome) -> String {
        switch outcome {
        case .completed:   return "완주가 성공캘린더에 기록되었습니다.\n내일도 같은 시간에 봅시다."
        case .exitFailed:  return "이탈로 세션이 실패했습니다.\n기록은 성공캘린더에서 확인할 수 있습니다."
        case .noShow:      return "알람 후 \(TimePolicy.startWindowMinutes)분 안에 시작하지 않았습니다."
        case .emergency:   return "긴급 상황으로 종료되었습니다."
        case .safetyEnded: return "배터리·저장 공간 등 안전 문제로 벌점 없이 종료되었습니다."
        }
    }
}
