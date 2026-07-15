//
//  AlarmView.swift
//  TimeLock
//
//  알람 화면:
//  활동명 · 10분 카운트다운 · 큰 [촬영 준비] · [밀어서 일정 취소] — 스누즈 없음.
//  촬영 준비 = 알람 즉시 정지 → 집중 모드 안내 → 구도 잡기 (10분 내 미시작은 노쇼)
//  일정 취소 = 알람 즉시 정지 → 사유 선택(4종) → 벌점과 함께 기록
//

import SwiftUI

struct AlarmView: View {
    let reservation: Reservation
    let fireDate: Date

    @EnvironmentObject private var app: AppState
    @State private var now = Date()
    @State private var showFocusGuide = false
    @State private var showCancelSheet = false
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

                VStack(spacing: 14) {
                    // 큰 '촬영준비' — 누르는 즉시 알람이 꺼지고 집중 모드 안내 → 구도 잡기
                    Button {
                        AlarmScheduler.shared.stopAlarmSound()
                        AlarmScheduler.shared.cancelAlarmNotifications(
                            reservationID: reservation.id, fireDate: fireDate)
                        showFocusGuide = true
                    } label: {
                        VStack(spacing: 3) {
                            Label("촬영 준비", systemImage: "record.circle.fill")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                            Text("\(TimePolicy.startWindowMinutes)분 안에 촬영을 시작하세요")
                                .font(.system(size: 11, weight: .semibold))
                                .opacity(0.75)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(TLPrimaryButtonStyle())

                    // 밀어서 일정 취소 — 밀자마자 알람이 꺼지고 사유 입력 + 벌점 확인
                    SlideToCancelButton(title: "밀어서 일정 취소") {
                        AlarmScheduler.shared.stopAlarmSound()
                        AlarmScheduler.shared.cancelAlarmNotifications(
                            reservationID: reservation.id, fireDate: fireDate)
                        showCancelSheet = true
                    }
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
        .sheet(isPresented: $showFocusGuide) {
            FocusModeGuideSheet(confirmTitle: "확인 — 구도 잡으러 가기") {
                showFocusGuide = false
                app.proceedToMountGuide(reservation: reservation, fireDate: fireDate)
            }
        }
        .sheet(isPresented: $showCancelSheet) {
            CancelReasonSheet(
                penaltyPoints: ScoreRules.points(for: .emergency, intensity: app.intensity)?.1 ?? -5,
                onConfirm: { reason in
                    showCancelSheet = false
                    app.cancelSchedule(reservation: reservation, fireDate: fireDate, reason: reason)
                },
                onResume: {
                    showCancelSheet = false
                    AlarmScheduler.shared.startAlarmSound()   // 마음이 바뀌면 알람 재개
                }
            )
        }
    }
}

// MARK: - 밀어서 일정 취소 (슬라이드 버튼)

private struct SlideToCancelButton: View {
    let title: String
    var onComplete: () -> Void

    @State private var offset: CGFloat = 0
    @GestureState private var isDragging = false

    private let height: CGFloat = 56
    private let knobSize: CGFloat = 48

    var body: some View {
        GeometryReader { geo in
            let maxOffset = geo.size.width - knobSize - 8
            ZStack(alignment: .leading) {
                // 트랙
                Capsule()
                    .fill(TL.surface)
                    .overlay(Capsule().strokeBorder(TL.hairline, lineWidth: 1))

                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(TL.muted)
                    .frame(maxWidth: .infinity)
                    .opacity(1 - Double(offset / max(1, maxOffset)) * 1.6)

                // 노브
                Circle()
                    .fill(TL.rec)
                    .frame(width: knobSize, height: knobSize)
                    .overlay(
                        Image(systemName: "chevron.right.2")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(TL.ink)
                    )
                    .offset(x: 4 + offset)
                    .gesture(
                        DragGesture()
                            .updating($isDragging) { _, state, _ in state = true }
                            .onChanged { value in
                                offset = min(max(0, value.translation.width), maxOffset)
                            }
                            .onEnded { _ in
                                if offset >= maxOffset * 0.85 {
                                    offset = maxOffset
                                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                                    onComplete()
                                    // 시트가 닫히고 돌아올 때를 위해 원위치
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                        withAnimation(.spring(duration: 0.3)) { offset = 0 }
                                    }
                                } else {
                                    withAnimation(.spring(duration: 0.3)) { offset = 0 }
                                }
                            }
                    )
            }
        }
        .frame(height: height)
    }
}

// MARK: - 일정 취소 사유 + 벌점 확인

private struct CancelReasonSheet: View {
    let penaltyPoints: Int
    var onConfirm: (String) -> Void
    var onResume: () -> Void

    @State private var selected: String?
    @State private var customReason = ""
    @FocusState private var customFocused: Bool

    private let presets = ["급한 일이 생겼어요", "몸이 좋지 않아요", "오늘은 쉬고싶어요"]
    private static let etc = "기타"

    /// 확정 가능한 최종 사유 (기타는 직접 입력 필수)
    private var finalReason: String? {
        guard let selected else { return nil }
        if selected == Self.etc {
            let trimmed = customReason.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("취소 사유를 선택해주세요")
                .font(.tlTitle(20))
                .foregroundStyle(TL.paper)
                .padding(.top, 24)

            VStack(spacing: 8) {
                ForEach(presets + [Self.etc], id: \.self) { reason in
                    reasonRow(reason)
                }
                if selected == Self.etc {
                    TextField("사유를 입력하세요", text: $customReason)
                        .font(.tlBody)
                        .foregroundStyle(TL.paper)
                        .focused($customFocused)
                        .padding(13)
                        .background(TL.surface, in: RoundedRectangle(cornerRadius: TL.cornerM))
                        .overlay(RoundedRectangle(cornerRadius: TL.cornerM)
                            .strokeBorder(TL.amber.opacity(0.6), lineWidth: 1))
                }
            }
            .padding(.top, 16)

            Label("취소하면 벌점 \(penaltyPoints)점이 사유와 함께 기록됩니다.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TL.rec)
                .padding(.top, 16)

            Spacer()

            VStack(spacing: 10) {
                Button("벌점 확인 · 일정 취소") {
                    if let reason = finalReason { onConfirm(reason) }
                }
                .buttonStyle(TLPrimaryButtonStyle())
                .disabled(finalReason == nil)
                .opacity(finalReason == nil ? 0.45 : 1)

                Button("돌아가기 — 알람 다시 울리기") { onResume() }
                    .buttonStyle(TLGhostButtonStyle(tint: TL.muted))
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TL.ink)
        .presentationDetents([.height(520)])
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
    }

    private func reasonRow(_ reason: String) -> some View {
        Button {
            selected = reason
            if reason == Self.etc { customFocused = true }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected == reason ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected == reason ? TL.rec : TL.faint)
                Text(reason)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(TL.paper)
                Spacer()
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                    .fill(selected == reason ? TL.raised : TL.surface)
            )
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

    /// 방향은 사용자가 이 화면에서 고른다 (세션 시작 후엔 고정)
    private var isLandscape: Bool { app.sessionOrientation == .landscape }

    var body: some View {
        ZStack {
            TL.ink.ignoresSafeArea()
            // 구도 화면은 '촬영되는 그대로'(잘림 없음) 보여준다 — 위치 잡기 정확
            CameraPreviewView(session: recorder.captureSession,
                              orientation: app.sessionOrientation, fill: false)
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
                    Text("\(TimePolicy.startWindowMinutes)분 안에 시작하지 않으면 노쇼 처리됩니다")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TL.rec)
                }
                .padding(.top, 24)

                // 세로/가로 방향 선택 + 전/후면 전환
                HStack(spacing: 10) {
                    orientationToggle
                    cameraSwitchButton
                }
                .padding(.top, 14)

                Spacer()

                // 구도 프레임 가이드 — 실제 영상 비율(9:16 / 16:9)과 동일
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(TL.paper.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    .frame(width: isLandscape ? 320 : 180, height: isLandscape ? 180 : 320)
                    .overlay(
                        Text("얼굴과 책상이 프레임 안에")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TL.paper.opacity(0.85))
                            .padding(.top, 8), alignment: .top)
                    .animation(.easeInOut(duration: 0.25), value: isLandscape)

                Spacer()

                VStack(spacing: 10) {
                    checkRow("거치대에 폰을 고정했어요", isOn: $checkedMount)
                    checkRow("구도 안에 내가 보여요", isOn: $checkedFrame)

                    Button {
                        // 예약 세션은 알람 화면에서 이미 집중 모드 안내를 봤으므로 바로 시작.
                        // 즉시 세션(지금 바로 시작)은 여기서 안내를 거친다.
                        if pending.scheduledAt == nil {
                            showFocusGuide = true
                        } else {
                            app.beginRecording(pending: pending)
                        }
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

    /// 세로 ↔ 가로 방향 토글 (누르면 화면이 그 방향으로 부드럽게 회전)
    private var orientationToggle: some View {
        HStack(spacing: 0) {
            ForEach(SessionOrientation.allCases, id: \.self) { orientation in
                let selected = app.sessionOrientation == orientation
                Button {
                    withAnimation { app.sessionOrientation = orientation }
                } label: {
                    Label(orientation.title, systemImage: orientation.icon)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? TL.ink : TL.paper)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill(selected ? TL.paper : .clear))
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(TL.ink.opacity(0.6)))
        .overlay(Capsule().strokeBorder(TL.hairline, lineWidth: 1))
    }

    private var cameraSwitchButton: some View {
        Button {
            recorder.switchCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TL.paper)
                .frame(width: 40, height: 40)
                .background(Circle().fill(TL.ink.opacity(0.6)))
                .overlay(Circle().strokeBorder(TL.hairline, lineWidth: 1))
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
    var confirmTitle: String = "확인 — 촬영 시작"
    /// '확인' 버튼 동작
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

            Text("앱 화면 위 배너는 촬영이 시작되면 '알림차단'이 자동으로 켜져 막아줍니다. 이탈 시 재촬영 알림은 집중 모드를 뚫고 전달됩니다.")
                .font(.system(size: 12))
                .foregroundStyle(TL.faint)
                .padding(.top, 12)

            Spacer()

            Button {
                onConfirm()
            } label: {
                Label(confirmTitle, systemImage: "record.circle.fill")
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
