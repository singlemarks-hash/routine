//
//  SessionView.swift
//  TimeLock
//
//  세션 진행 화면: 남은 시간 REC 링, 촬영 중 프리뷰(PiP), 활동명.
//  화면 자동 꺼짐 방지 + 밝기 자동 감소(탭 시 복원).
//  통화 수신 시 벌점 없이 일시정지. 긴급 버튼은 강도별 정책 적용.
//

import SwiftUI

struct SessionView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: SessionEngine
    @StateObject private var recorder = CameraRecorder.shared

    @State private var dimmed = false
    @State private var dimTask: Task<Void, Never>?
    @State private var showEmergency = false
    @State private var emergencyReason = ""

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
                Label("카메라 사용 중 · 기기에만 저장", systemImage: "lock.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TL.muted)
                Label("앱을 벗어나면 \(engine.session?.intensity == .insane ? "즉시 실패 · 벌점 2배" : "경고 후 10초 유예")",
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
                Label("긴급", systemImage: "cross.circle.fill")
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

    private var emergencySheet: some View {
        let intensity = engine.session?.intensity ?? .spicy
        return NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(intensity == .spicy
                     ? "긴급 종료에는 사유가 필요하며 벌점이 부과됩니다."
                     : "미친 매운맛은 사유 없이 즉시 종료되며 '긴급'으로 구분 표시됩니다.")
                    .font(.tlBody)
                    .foregroundStyle(TL.muted)

                if intensity == .spicy {
                    TextField("사유 (예: 갑작스러운 방문)", text: $emergencyReason)
                        .padding(14)
                        .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerM))
                }

                Button("긴급 종료") {
                    let reason = intensity == .spicy
                        ? emergencyReason.trimmingCharacters(in: .whitespaces)
                        : nil
                    showEmergency = false
                    engine.emergencyEnd(reason: reason)
                }
                .buttonStyle(TLPrimaryButtonStyle())
                .disabled(intensity == .spicy && emergencyReason.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("계속 진행") { showEmergency = false }
                    .buttonStyle(TLGhostButtonStyle())

                Spacer()
            }
            .padding(20)
            .background(TL.ink)
            .navigationTitle("긴급 종료")
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

// MARK: - 결과 화면 (완주 / 실패 / 긴급 / 안전 종료)

struct SessionResultView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: SessionEngine

    var body: some View {
        let session = engine.lastFinishedSession
        let outcome = session?.outcome ?? .completed

        ZStack {
            TL.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()

                RECRingDial(progress: 1, live: false,
                            tint: outcome.isSuccess ? TL.jade : (outcome.isFailure ? TL.rec : TL.amber)) {
                    Image(systemName: symbol(for: outcome))
                        .font(.system(size: 52, weight: .bold))
                        .foregroundStyle(outcome.isSuccess ? TL.jade : (outcome.isFailure ? TL.rec : TL.amber))
                }
                .frame(width: 190, height: 190)

                Text(title(for: outcome))
                    .font(.tlTitle(28))
                    .foregroundStyle(TL.paper)
                    .padding(.top, 28)

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
                        } else {
                            Text("벌점 없음 · 촬영분 보존됨")
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
                    .padding(.top, 18)
                    .padding(.horizontal, 40)

                Spacer()

                Button(outcome.isSuccess ? "성공캘린더에서 보기" : "확인") {
                    app.dismissResult()
                }
                .buttonStyle(TLPrimaryButtonStyle(tint: outcome.isSuccess ? TL.jade : TL.rec))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .interactiveDismissDisabled()
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
        case .completed:   return "타임랩스가 성공캘린더에 기록되었습니다.\n내일도 같은 시간에 봅시다."
        case .exitFailed:  return "촬영분은 보존되었습니다.\n기록은 성공캘린더에서 확인할 수 있습니다."
        case .noShow:      return "알람 후 5분 안에 시작하지 않았습니다."
        case .emergency:   return "긴급 상황으로 종료되었습니다. 촬영분은 보존됩니다."
        case .safetyEnded: return "배터리·저장 공간 등 안전 문제로 벌점 없이 종료되었습니다."
        }
    }
}
