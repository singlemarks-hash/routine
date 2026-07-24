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
                penaltyPoints: ScoreRules.points(for: .emergency, intensity: app.intensity,
                                                 durationMinutes: reservation.durationMinutes)?.1 ?? -5,
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

    /// 시작 카운트다운 (nil = 대기, 3→2→1, 0 = '시작!')
    @State private var countdown: Int?
    /// '시작!' 후에도 카메라 준비가 안 끝난 드문 경우의 로딩 표시
    @State private var preparing = false

    /// 방향은 사용자가 이 화면에서 고른다 (세션 시작 후엔 고정)
    private var isLandscape: Bool { app.sessionOrientation == .landscape }

    var body: some View {
        ZStack {
            TL.ink.ignoresSafeArea()
            // 구도 화면은 '촬영되는 그대로'(잘림 없음) 보여준다 — 위치 잡기 정확
            CameraPreviewView(session: recorder.captureSession,
                              orientation: app.sessionOrientation, fill: false)
                .ignoresSafeArea()

            if isLandscape {
                // 가로: 점선 프레임을 먼저(뒤) 깔고 → 우측 불투명 패널이 그 위를 덮는다.
                //  프레임이 버튼 영역까지 넓게 뻗지만 패널이 앞이라 조작에 방해되지 않는다.
                compositionGuideLayer
                landscapeLayout
            } else {
                // 세로도 가로와 동일하게: 점선 프레임을 먼저(맨 뒤) 깔고 → 컨트롤이 그 위를 덮는다.
                //  프레임이 헤더·체크·버튼 위를 가로지르지 않아 화면이 깔끔하다.
                compositionGuideLayer
                portraitLayout
            }

            // 시작 카운트다운 — 이 화면의 라이브 프리뷰 위에서 진행 (프리뷰 레이어 1개 유지).
            // '시작!'과 동시에 녹화가 개시되고 세션 화면으로 전환된다.
            if let countdown {
                countdownOverlay(value: countdown)
            }
        }
        .interactiveDismissDisabled()
        .onAppear { recorder.startPreview() }
        .task { _ = await recorder.requestAuthorization() }
        .sheet(isPresented: $showFocusGuide) {
            FocusModeGuideSheet {
                showFocusGuide = false
                app.beginRecording(pending: pending)   // 알람 정지 + 세션 무장
                runCountdown()
            }
        }
    }

    // MARK: 시작 카운트다운

    private func runCountdown() {
        Task { @MainActor in
            // 카운트다운과 '동시에' 녹화를 개시 — 3초가 카메라·엔진 준비 시간을 흡수한다.
            // ('시작!' 후에 준비를 시작하면 준비 시간만큼 화면이 멈춘 것처럼 보였음)
            app.startArmedRecording()

            for n in stride(from: 3, through: 1, by: -1) {
                withAnimation(TLMotion.bouncy) { countdown = n }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            withAnimation(TLMotion.bouncy) { countdown = 0 }   // '시작!'
            UINotificationFeedbackGenerator().notificationOccurred(.success)

            // 첫 촬영 프레임이 들어올 때까지 대기 (보통 즉시 — 이미 3초간 준비됨).
            // 드물게 오래 걸리면 '카메라 준비 중' 로딩을 정직하게 표시. 최대 8초 후엔 진행.
            var waited: Double = 0
            while CameraRecorder.shared.frameCount == 0, waited < 8 {
                if case .finished = app.engine.phase { break }   // 시작 실패 → 결과 화면이 처리
                if waited >= 0.4 { preparing = true }
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 0.1
            }
            preparing = false
            try? await Task.sleep(nanoseconds: 250_000_000)   // '시작!' 잔상 짧게
            app.enterSessionIfRecording()
        }
    }

    private func countdownOverlay(value: Int) -> some View {
        ZStack {
            // 스크림 — 아래 컨트롤 터치 차단 + 숫자 가독성 (프리뷰는 계속 라이브로 비침)
            LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.3), .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(spacing: 18) {
                TLEyebrow(text: "촬영 개시", color: TL.rec)
                Text("이제부터 촬영 시작한다")
                    .font(.tlTitle(23)).foregroundStyle(.white)

                Group {
                    if value > 0 {
                        Text("\(value)")
                            .font(.system(size: 112, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .id(value)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    } else {
                        Text("시작!")
                            .font(.system(size: 80, weight: .heavy, design: .rounded))
                            .foregroundStyle(TL.rec)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .frame(height: 124)
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)

                // 드물게 카메라 준비가 늦어질 때만 — 멈춘 게 아니라 준비 중임을 명시
                if value == 0 && preparing {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white).scaleEffect(0.85)
                        Text("카메라 준비 중…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(TLMotion.smooth, value: preparing)
    }

    // MARK: 세로 레이아웃 — 상단 헤더, 중앙 프레임, 하단 컨트롤

    private var portraitLayout: some View {
        ZStack {
            LinearGradient(colors: [TL.ink.opacity(0.85), .clear, TL.ink.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack {
                header
                    .padding(.top, 24)
                controlsBar
                    .padding(.top, 14)

                // 안내 문구 — 방향·전환 아이콘 바로 아래, 가운데 정렬(VStack 중앙).
                // 프레임(중앙)과 넉넉히 떨어져 점선·다른 요소와 간섭이 없다.
                Text("영역 안에 내 모습이 보이도록 고정")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(.top, 16)

                Spacer()   // 가운데는 점선 프레임(별도 레이어)이 차지한다

                VStack(spacing: 10) {
                    checkRow("거치대에 폰을 고정했어요", isOn: $checkedMount)
                    checkRow("구도 안에 내가 보여요", isOn: $checkedFrame)
                    startButton
                    cancelButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: 가로 레이아웃 — 좌측은 구도 프레임, 우측은 별도 컨트롤 패널(중첩 없음)

    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            // 좌: 촬영 구도 영역 (점선 프레임은 별도 전체 레이어) + 프리뷰 영역 상단 중앙 안내 문구.
            LinearGradient(colors: [TL.ink.opacity(0.5), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    Text("영역 안에 내 모습이 보이도록 고정")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(.top, 44)
                }

            // 우: 불투명 컨트롤 패널 — 한 화면에 모두 들어오도록 압축.
            //  ScrollView는 아주 작은 기기용 안전장치일 뿐, 일반 기기에선 스크롤 없이 꽉 찬다.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    controlsBar
                    checkRow("거치대에 폰을 고정했어요", isOn: $checkedMount, compact: true)
                    checkRow("구도 안에 내가 보여요", isOn: $checkedFrame, compact: true)
                    startButton
                    cancelButton
                }
                .padding(.leading, 18)
                .padding(.trailing, 22)
                .padding(.vertical, 14)
                // 가로에서 노치·홈 인디케이터·둥근 모서리로 버튼이 잘리지 않도록 안전영역만큼 더 들여쓴다.
                .safeAreaPadding(.trailing)
            }
            .frame(width: 300)
            // 반투명 — 뒤의 점선 프레임(80%)이 패널 너머로 비쳐, 내 전신이 어디까지 담기는지 보인다
            .background(TL.ink.opacity(0.6).ignoresSafeArea())
            .overlay(alignment: .leading) {
                Rectangle().fill(TL.hairline).frame(width: 1).ignoresSafeArea()
            }
        }
    }

    // MARK: 공통 구성 요소

    private var header: some View {
        VStack(alignment: isLandscape ? .leading : .center, spacing: 6) {
            TLEyebrow(text: "거치 가이드", color: TL.amber)
            Text(pending.activityName)
                .font(.tlTitle(isLandscape ? 18 : 22))
                .foregroundStyle(TL.paper)
            Text("\(TimePolicy.startWindowMinutes)분 안에 시작하지 않으면 노쇼 처리됩니다")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TL.rec)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: isLandscape ? .infinity : nil, alignment: isLandscape ? .leading : .center)
    }

    private var controlsBar: some View {
        HStack(spacing: 10) {
            orientationToggle
            cameraSwitchButton
        }
    }

    /// 아직 시작 전 — 마음이 바뀌면 아무 기록 없이 되돌아간다.
    /// (예약 세션은 알람 화면으로, 즉시 세션은 홈으로)
    private var cancelButton: some View {
        Button("취소하기") {
            app.cancelMountGuide(pending: pending)
        }
        .font(.system(size: 15, weight: .semibold, design: .rounded))
        .foregroundStyle(TL.paper)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        // 반투명 흰 배경 캡슐 — 전체 화면 프리뷰 위에서도 잘 보이게
        .background(Color.white.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))
        .disabled(countdown != nil)   // 카운트다운 시작 후엔 취소 불가
        .opacity(countdown != nil ? 0.3 : 1)
    }

    private var startButton: some View {
        Button {
            // 예약 세션은 알람 화면에서 이미 집중 모드 안내를 봤으므로 바로 카운트다운.
            // 즉시 세션(지금 바로 시작)은 여기서 안내를 거친다.
            if pending.scheduledAt == nil {
                showFocusGuide = true
            } else {
                app.beginRecording(pending: pending)   // 알람 정지 + 세션 무장
                runCountdown()
            }
        } label: {
            Label("촬영 시작", systemImage: "record.circle.fill")
        }
        .buttonStyle(TLPrimaryButtonStyle())
        .disabled(!(checkedMount && checkedFrame))
        .opacity(checkedMount && checkedFrame ? 1 : 0.4)
    }

    /// 구도 프레임 가이드 — 실제 촬영은 '전체 화면'이므로 점선 프레임도 화면의 ~80%를
    /// 차지하도록 크게 그린다(작은 중앙 박스 ✕). 영상 비율(세로 9:16 / 가로 16:9)에 맞춰
    /// 잘림 없이 표시하고, 터치는 통과시켜 아래 컨트롤 조작을 방해하지 않는다.
    private var compositionGuideLayer: some View {
        GeometryReader { geo in
            // ratio = 가로/세로. 세로영상 9:16, 가로영상 16:9
            let ratio: CGFloat = isLandscape ? 16.0 / 9.0 : 9.0 / 16.0
            // 폭 80% 우선 → 화면 높이를 넘으면 높이 88%로 제한
            let byWidth = geo.size.width * 0.8
            let byWidthHeight = byWidth / ratio
            let maxHeight = geo.size.height * 0.88
            let fitsWidth = byWidthHeight <= maxHeight
            let w: CGFloat = fitsWidth ? byWidth : maxHeight * ratio
            let h: CGFloat = fitsWidth ? byWidthHeight : maxHeight

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(TL.paper.opacity(0.5),
                              style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .frame(width: w, height: h)
                // 안내 문구는 세로=아이콘 아래, 가로=좌상단으로 각 레이아웃이 직접 배치한다.
                .frame(width: geo.size.width, height: geo.size.height)   // 화면 중앙 배치
        }
        .allowsHitTesting(false)   // 점선은 안내용 — 터치는 아래로 통과
        .ignoresSafeArea()
    }

    /// 세로 ↔ 가로 방향 토글 (누르면 화면이 그 방향으로 부드럽게 회전)
    private var orientationToggle: some View {
        HStack(spacing: 0) {
            ForEach(SessionOrientation.allCases, id: \.self) { orientation in
                let selected = app.sessionOrientation == orientation
                Button {
                    withAnimation(TLMotion.smooth) { app.sessionOrientation = orientation }
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
        .pressableStyle()
    }

    /// compact = 가로 모드용 — 텍스트·높이를 줄여 우측 패널이 한 화면에 들어오게 한다.
    private func checkRow(_ title: String, isOn: Binding<Bool>, compact: Bool = false) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: compact ? 9 : 12) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: compact ? 17 : 20))
                    .foregroundStyle(isOn.wrappedValue ? TL.jade : TL.muted)
                Text(title)
                    .font(.system(size: compact ? 13 : 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(TL.paper)
                Spacer()
            }
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 10 : 14)
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
