//
//  SessionView.swift
//  TimeLock
//
//  세션 진행 화면: 남은 시간 REC 링, 촬영 중 프리뷰(PiP), 활동명.
//  화면 자동 꺼짐 방지 + 밝기 자동 감소(탭 시 복원).
//  통화 수신 시 벌점 없이 일시정지.
//  긴급 용무(매운맛): 촬영을 중단하고 10분 재촬영 창 — 창 안에 재촬영하면 벌점 없음.
//

import SwiftUI
import SwiftData

struct SessionView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: SessionEngine
    @StateObject private var recorder = CameraRecorder.shared

    @State private var dimmed = false
    @State private var dimTask: Task<Void, Never>?
    @State private var showEmergency = false

    var body: some View {
        ZStack {
            TL.ink.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()
                dial
                Spacer()
                previewStrip
                footer
            }

            // 통화 일시정지 오버레이
            if engine.phase == .pausedForCall {
                pauseOverlay
            }

            // 긴급 용무 중단 오버레이 — 재촬영 카운트다운
            if case .pausedForBreak(let deadline) = engine.phase {
                BreakOverlay(deadline: deadline)
            }

            // 밝기 감소 커튼 (탭 시 복원)
            if dimmed {
                Color.black.opacity(0.92)
                    .ignoresSafeArea()
                    .overlay(
                        VStack(spacing: 10) {
                            Circle().fill(TL.rec).frame(width: 10, height: 10)
                            Text(TLFormat.hms(engine.remainingSeconds))
                                .font(.tlTimer(34))
                                .foregroundStyle(TL.paper.opacity(0.5))
                            Text("탭하여 화면 켜기")
                                .font(.system(size: 12))
                                .foregroundStyle(TL.faint)
                        }
                    )
                    .onTapGesture { wake() }
                    .transition(.opacity)
            }
        }
        .interactiveDismissDisabled()
        .statusBarHidden(dimmed)
        .onAppear { scheduleDim() }
        .onDisappear { dimTask?.cancel() }
        .onTapGesture { wake() }
        .sheet(isPresented: $showEmergency) { emergencySheet }
    }

    // MARK: 상단

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(TL.rec).frame(width: 8, height: 8)
                TLEyebrow(text: "REC · 촬영 중", color: TL.rec)
            }
            Text(engine.session?.activityName ?? "")
                .font(.tlTitle(22))
                .foregroundStyle(TL.paper)
            if engine.oneMinuteWarningFired {
                Text("1분 뒤 자동 종료됩니다")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TL.jade)
            }
        }
        .padding(.top, 28)
    }

    // MARK: 다이얼

    private var dial: some View {
        RECRingDial(progress: engine.progress, live: true,
                    tint: engine.remainingSeconds <= 60 ? TL.jade : TL.rec) {
            VStack(spacing: 4) {
                Text(TLFormat.hms(engine.remainingSeconds))
                    .font(.tlTimer(56))
                    .foregroundStyle(TL.paper)
                Text("남음 · 순수 촬영 시간 기준")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TL.muted)
            }
        }
        .frame(width: 270, height: 270)
    }

    // MARK: 프리뷰 (자기감시)

    private var previewStrip: some View {
        HStack(spacing: 12) {
            CameraPreviewView(session: recorder.captureSession)
                .frame(width: 84, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                        .strokeBorder(TL.rec, lineWidth: 1.5)
                )
            VStack(alignment: .leading, spacing: 5) {
                Label("카메라 사용 중 · 촬영본은 종료 시 저장/삭제 선택", systemImage: "lock.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TL.muted)
                Label(engine.session?.intensity == .insane
                      ? "앱을 벗어나면 즉시 실패 · 벌점 2배"
                      : "중단해도 \(TimePolicy.resumeWindowMinutes)분 안에 재촬영하면 벌점 없음",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TL.amber)
                Label("전화가 오면 벌점 없이 일시정지", systemImage: "phone.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TL.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    // MARK: 하단

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation { dimmed = true }
            } label: {
                Label("화면 어둡게", systemImage: "moon.fill")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(TL.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: TL.cornerM).strokeBorder(TL.hairline))
            }
            Button {
                showEmergency = true
            } label: {
                Label(engine.session?.intensity == .insane ? "긴급" : "긴급 용무", systemImage: "cross.circle.fill")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(TL.rec)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: TL.cornerM).strokeBorder(TL.rec.opacity(0.5)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
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

    // MARK: 긴급 시트 (강도별 정책)
    //  매운맛: 촬영 중단 → 10분 재촬영 창 (창 안에 재촬영하면 벌점 없음)
    //  미친 매운맛: 사유 없는 즉시 종료 · 벌점

    private var emergencySheet: some View {
        let intensity = engine.session?.intensity ?? .spicy
        return NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if intensity == .spicy {
                    Text("촬영이 멈추고 \(TimePolicy.resumeWindowMinutes)분의 재촬영 창이 열립니다. 창 안에 재촬영을 시작하면 벌점이 없습니다. 시작하지 않으면 벌점과 함께 세션이 종료됩니다.")
                        .font(.tlBody)
                        .foregroundStyle(TL.muted)

                    Button("촬영 중단 — \(TimePolicy.resumeWindowMinutes)분 창 열기") {
                        showEmergency = false
                        engine.startBreak()
                    }
                    .buttonStyle(TLPrimaryButtonStyle(tint: TL.amber))
                } else {
                    Text("미친 매운맛은 사유 없이 즉시 종료되며 '긴급'으로 구분 표시되고 벌점이 부과됩니다.")
                        .font(.tlBody)
                        .foregroundStyle(TL.muted)

                    Button("긴급 종료") {
                        showEmergency = false
                        engine.emergencyEnd(reason: nil)
                    }
                    .buttonStyle(TLPrimaryButtonStyle())
                }

                Button("계속 진행") { showEmergency = false }
                    .buttonStyle(TLGhostButtonStyle())

                Spacer()
            }
            .padding(20)
            .background(TL.ink)
            .navigationTitle(intensity == .spicy ? "긴급 용무" : "긴급 종료")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(320)])
        .preferredColorScheme(.dark)
    }

    // MARK: 밝기 감소

    private func scheduleDim() {
        guard app.dimModeEnabled else { return }
        dimTask?.cancel()
        dimTask = Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if !Task.isCancelled {
                await MainActor.run { withAnimation { dimmed = true } }
            }
        }
    }

    private func wake() {
        if dimmed { withAnimation { dimmed = false } }
        scheduleDim()
    }
}

// MARK: - 긴급 용무 중단 오버레이 — 재촬영 카운트다운

private struct BreakOverlay: View {
    let deadline: Date

    @EnvironmentObject private var engine: SessionEngine
    @State private var now = Date()
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var remaining: Int { max(0, Int(deadline.timeIntervalSince(now))) }
    private var progress: Double { Double(remaining) / TimePolicy.resumeWindowSeconds }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            TLEyebrow(text: "촬영 일시중단", color: TL.amber)
            Text("긴급 용무 중")
                .font(.tlTitle(24))
                .foregroundStyle(TL.paper)
                .padding(.top, 8)

            RECRingDial(progress: progress, live: false,
                        tint: remaining <= 60 ? TL.rec : TL.amber) {
                VStack(spacing: 4) {
                    Text(TLFormat.hms(remaining))
                        .font(.tlTimer(48))
                        .foregroundStyle(TL.paper)
                    Text("안에 재촬영을 시작하세요")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TL.muted)
                }
            }
            .frame(width: 230, height: 230)
            .padding(.top, 28)

            Text("창 안에 재촬영을 시작하면 벌점이 없습니다.\n시간이 지나면 벌점과 함께 세션이 종료됩니다.")
                .font(.system(size: 14))
                .foregroundStyle(TL.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 22)

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
