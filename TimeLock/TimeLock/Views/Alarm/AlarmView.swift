//
//  AlarmView.swift
//  TimeLock
//
//  알람 화면 최소화 규칙:
//  활동명 · 5분 경고 · [촬영 시작] · [긴급] — 그 외 동선 없음. 스누즈 없음.
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

    private var deadline: Date { fireDate.addingTimeInterval(300) }
    private var remaining: Int { max(0, Int(deadline.timeIntervalSince(now))) }
    private var progress: Double { Double(remaining) / 300.0 }

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

                // 시그니처 REC 링 = 남은 5분
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
                // 5분 경과 → 알람 자동 종료, 노쇼는 스위퍼가 벌점과 함께 기록
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
            Text("긴급 종료해도 이 예약은 5분 규칙에 따라 탈락으로 기록됩니다.")
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

                // 구도 프레임 가이드
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(TL.paper.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    .frame(width: 240, height: 320)
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
                        app.beginRecording(pending: pending)
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
