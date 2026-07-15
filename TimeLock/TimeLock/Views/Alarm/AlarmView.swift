//
//  AlarmView.swift
//  TimeLock
//
//  알람 화면 최소화 규칙:
//  활동명 · 10분 경고 · [촬영 시작] · [긴급] — 그 외 동선 없음. 스누즈 없음.
//  알람 오디오는 촬영 시작 시점에만 멈춘다.
//

import SwiftUI

struct AlarmView: View {
    let reservation: Reservation
    let fireDate: Date

    @EnvironmentObject private var app: AppState
    @State private var now = Date()
    @State private var showEmergencyConfirm = false
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var deadline: Date { fireDate.addingTimeInterval(TimePolicy.startWindowSeconds) }
    private var remaining: Int { max(0, Int(deadline.timeIntervalSince(now))) }
    private var progress: Double { Double(remaining) / TimePolicy.startWindowSeconds }

    var body: some View {
        ZStack {
            TL.ink.ignoresSafeArea()
            // 배경 맥동 — 알람의 긴박감
            RadialGradient(colors: [TL.rec.opacity(0.16), .clear],
                           center: .center, startRadius: 40, endRadius: 420)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 36)
                TLEyebrow(text: "알람 · \(TLFormat.clock(fireDate))", color: TL.rec)
                Text(reservation.name)
                    .font(.tlTitle(30))
                    .foregroundStyle(TL.paper)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 32)
                Text("\(TLFormat.durationLabel(reservation.durationMinutes)) · \(reservation.tag)")
                    .font(.tlBody)
                    .foregroundStyle(TL.muted)
                    .padding(.top, 4)

                Spacer()

                // 시그니처 REC 링 = 남은 시작 창(10분)
                RECRingDial(progress: progress, live: true, tint: remaining <= 60 ? TL.rec : TL.amber) {
                    VStack(spacing: 4) {
                        Text(TLFormat.hms(remaining))
                            .font(.tlTimer(52))
                            .foregroundStyle(TL.paper)
                        Text("안에 촬영을 시작하세요")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TL.muted)
                    }
                }
                .frame(width: 250, height: 250)

                Text("시작하지 않으면 탈락으로 기록되고 벌점이 부과됩니다.")
                    .font(.system(size: 13))
                    .foregroundStyle(TL.muted)
                    .padding(.top, 24)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        app.proceedToMountGuide(reservation: reservation, fireDate: fireDate)
                    } label: {
                        Label("촬영 시작", systemImage: "record.circle.fill")
                    }
                    .buttonStyle(TLPrimaryButtonStyle())

                    Button("긴급") { showEmergencyConfirm = true }
                        .buttonStyle(TLGhostButtonStyle(tint: TL.muted))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .interactiveDismissDisabled()
        .onReceive(clock) { time in
            now = time
            if remaining == 0 {
                // 10분 경과 → 알람 자동 종료, 노쇼는 스위퍼가 벌점과 함께 기록
                AlarmScheduler.shared.stopAlarmSound()
                app.sweepNoShows()
                app.route = .none
            }
        }
        .onAppear { AlarmScheduler.shared.startAlarmSound() }
        .confirmationDialog("긴급 상황인가요?", isPresented: $showEmergencyConfirm, titleVisibility: .visible) {
            Button("알람 종료 (탈락으로 기록됨)", role: .destructive) {
                app.emergencyDismissAlarm()
                app.sweepNoShows()
            }
            Button("계속 진행", role: .cancel) { }
        } message: {
            Text("긴급 종료해도 이 예약은 \(TimePolicy.startWindowMinutes)분 규칙에 따라 탈락으로 기록됩니다.")
        }
    }
}

// MARK: - 거치 가이드

struct MountGuideView: View {
    let pending: AppState.PendingSession

    @EnvironmentObject private var app: AppState
    @StateObject private var recorder = CameraRecorder.shared
    @State private var checkedMount = false
    @State private var checkedFrame = false
    @State private var showFocusGuide = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// 가로 거치 시 구도 가이드도 가로 프레임으로
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack {
            CameraPreviewView(session: recorder.captureSession)
                .ignoresSafeArea()
            LinearGradient(colors: [TL.ink.opacity(0.85), .clear, TL.ink.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack {
                VStack(spacing: 6) {
                    TLEyebrow(text: "거치 가이드", color: TL.amber)
                    Text(pending.activityName)
                        .font(.tlTitle(22))
                        .foregroundStyle(TL.paper)
                    Text("알람은 촬영을 시작해야 멈춥니다")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TL.rec)
                }
                .padding(.top, 24)

                Spacer()

                // 구도 프레임 가이드 (거치 방향에 맞춰 가로/세로)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(TL.paper.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    .frame(width: isLandscape ? 300 : 240, height: isLandscape ? 180 : 320)
                    .overlay(
                        Text("얼굴과 책상이 프레임 안에")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TL.paper.opacity(0.85))
                            .padding(.top, 8), alignment: .top)

                Spacer()

                VStack(spacing: 10) {
                    checkRow("거치대에 폰을 고정했어요", isOn: $checkedMount)
                    checkRow("구도 안에 내가 보여요", isOn: $checkedFrame)

                    Button {
                        showFocusGuide = true   // 촬영 전 집중 모드 안내 → '확인' 후 시작
                    } label: {
                        Label("촬영 시작 · 알람 해제", systemImage: "record.circle.fill")
                    }
                    .buttonStyle(TLPrimaryButtonStyle())
                    .disabled(!(checkedMount && checkedFrame))
                    .opacity(checkedMount && checkedFrame ? 1 : 0.4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .interactiveDismissDisabled()
        .onAppear { recorder.startPreview() }
        .task { _ = await recorder.requestAuthorization() }
        .sheet(isPresented: $showFocusGuide) {
            FocusModeGuideSheet {
                showFocusGuide = false
                app.beginRecording(pending: pending)
            }
        }
    }

    private func checkRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn.wrappedValue ? TL.jade : TL.muted)
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(TL.paper)
                Spacer()
            }
            .padding(14)
            .background(TL.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: TL.cornerM))
        }
    }
}

// MARK: - 집중 모드 안내 (촬영 시작 직전)
//  iOS 정책상 앱이 시스템 알림을 대신 끌 수 없으므로,
//  사용자가 직접 집중 모드를 켜도록 안내한 뒤 '확인'으로 촬영을 시작한다.

struct FocusModeGuideSheet: View {
    /// '확인' — 촬영 시작
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(TL.amber)
                Text("시작 전, 집중 모드를 켜서\n알림을 차단해보세요")
                    .font(.tlTitle(19))
                    .foregroundStyle(TL.paper)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 14) {
                guideStep(number: 1, text: "화면 오른쪽 위 모서리에서 아래로 쓸어내려 제어 센터를 엽니다")
                guideStep(number: 2, text: "🌙 집중 모드 버튼을 누르고 '방해금지'를 선택합니다")
                guideStep(number: 3, text: "세션이 끝나면 같은 방법으로 해제하면 됩니다")
            }
            .padding(16)
            .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous))
            .padding(.top, 20)

            Text("앱 화면 위로 뜨는 배너는 세션 화면의 '알림차단' 버튼이 막아줍니다.")
                .font(.system(size: 12))
                .foregroundStyle(TL.faint)
                .padding(.top, 12)

            Spacer()

            Button {
                onConfirm()
            } label: {
                Label("확인 — 촬영 시작", systemImage: "record.circle.fill")
            }
            .buttonStyle(TLPrimaryButtonStyle())
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TL.ink)
        .presentationDetents([.height(430)])
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
    }

    private func guideStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(TL.ink)
                .frame(width: 22, height: 22)
                .background(Circle().fill(TL.amber))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(TL.paper)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
