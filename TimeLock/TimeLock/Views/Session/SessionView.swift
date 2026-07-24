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
import AVFoundation

struct SessionView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: SessionEngine
    @EnvironmentObject private var alarm: AlarmScheduler
    @StateObject private var recorder = CameraRecorder.shared

    @State private var showEmergency = false

    /// 세션 방향은 구도 단계에서 확정 — 촬영 내내 고정
    private var isLandscape: Bool { app.sessionOrientation == .landscape }

    /// 다이얼 눈금 밀도 산정용 세션 길이(분)
    private var sessionMinutes: Int { (engine.session?.targetSeconds ?? 3600) / 60 }

    var body: some View {
        ZStack {
            TL.ink.ignoresSafeArea()

            if isLandscape {
                landscapeLayout
            } else {
                portraitLayout
            }

            // 자리비움 경고 배너 — 30초 연속 부재부터 표시, 2분 확정 시 자동 긴급 중단/즉시 실패
            if engine.absenceWarning {
                VStack {
                    absenceBanner
                        .padding(.top, 10)
                        .padding(.horizontal, 20)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // 긴급 용무 중단 오버레이 — 재촬영 카운트다운 (통화도 백그라운드 이탈로 이 오버레이에 진입)
            if case .pausedForBreak(let deadline) = engine.phase {
                BreakOverlay(deadline: deadline)
            }

        }
        .animation(TLMotion.smooth, value: engine.absenceWarning)
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
                      tint: engine.remainingSeconds <= 60 ? TL.jade : TL.rec,
                      totalMinutes: sessionMinutes)
                .frame(width: 230, height: 230)

            Text(TLFormat.hms(engine.remainingSeconds))
                .font(.tlTimer(36))
                .foregroundStyle(TL.paper)
                .padding(.top, 14)

            Spacer()

            // 영상 비율(9:16)과 동일 → 잘림 없이 촬영 그대로 보임
            selfieCard(width: 162, height: 288)

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
                          tint: engine.remainingSeconds <= 60 ? TL.jade : TL.rec,
                          totalMinutes: sessionMinutes)
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
                // 영상 비율(16:9)과 동일 → 잘림 없이 촬영 그대로 보임
                selfieCard(width: 256, height: 144)
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
        // 세션 화면은 녹화가 이미 시작된 뒤에만 등장 — 이 프리뷰가 유일한 레이어라 안전
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
        // 긴급 예산(세션당 10분)을 다 쓰면 버튼 자체를 비활성화 — 누를 일도 없게.
        // (중단 중 00:00 도달은 엔진 틱이 자동으로 실패 처리한다)
        let exhausted = engine.session?.intensity == .spicy && engine.breakBudgetRemaining < 1
        return squareButton(title: exhausted ? "긴급 소진" : "긴급중단",
                            symbol: "light.beacon.max.fill", active: false) {
            if engine.session?.intensity == .insane {
                showEmergency = true
            } else {
                engine.startBreak()
            }
        }
        .disabled(exhausted)
        .opacity(exhausted ? 0.4 : 1)
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

    // MARK: 자리비움 경고 배너

    private var absenceBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill.questionmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(TL.ink)
            VStack(alignment: .leading, spacing: 1) {
                // 카운트는 경고가 뜨는 순간 이미 +1 된 상태 — 복귀해도 유지된다
                Text("자리비움 감지 · \(min(engine.absenceEpisodeCount, engine.absenceMaxEpisodes))/\(engine.absenceMaxEpisodes)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(TL.ink)
                Text(engine.session?.intensity == .insane
                     ? engine.absenceEpisodeCount >= engine.absenceMaxEpisodes
                       ? "마지막 경고 — 다음 자리비움은 알림 없이 즉시 실패합니다"
                       : "2분 안에 돌아오세요 — 초과 시 즉시 실패 (경고는 \(engine.absenceMaxEpisodes)번까지)"
                     : engine.absenceEpisodeCount >= engine.absenceMaxEpisodes
                       ? "마지막 경고 — 다음 자리비움은 알림 없이 자동 긴급 중단됩니다"
                       : "2분 안에 돌아오세요 — 초과 시 자동 긴급 중단 (경고는 \(engine.absenceMaxEpisodes)번까지)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TL.ink.opacity(0.8))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous).fill(TL.amber))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
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
            Text(engine.breakNote == nil ? "긴급 용무 중" : "촬영이 중단됐어요")
                .font(.tlTitle(compact ? 18 : 24))
                .foregroundStyle(TL.paper)
                .padding(.top, 6)
            if let note = engine.breakNote {
                Text(note)
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .foregroundStyle(TL.amber)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
            }

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

            Text("총 \(TimePolicy.resumeWindowMinutes)분 안에 재촬영을 시작하면 벌점이 없습니다.\n시간이 지나면 벌점과 함께 세션이 종료됩니다.")
                .font(.system(size: compact ? 12 : 14))
                .foregroundStyle(TL.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, compact ? 8 : 22)

            Text("긴급 용무 시간은 리셋되지 않고, 계속 이어집니다")
                .font(.system(size: compact ? 11 : 13, weight: .semibold))
                .foregroundStyle(TL.amber)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, compact ? 6 : 12)

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
    /// 완주 성공 연출 — 캐릭터 팝 + 옥색 리플
    @State private var successPop = false
    @State private var successRipple = false

    /// 이 계정의 누적 벌점 횟수
    private var penaltyCount: Int {
        scoreEvents.filter { $0.ownerUserID == account.currentUserID && $0.points < 0 }.count
    }

    var body: some View {
        let session = engine.lastFinishedSession
        let outcome = session?.outcome ?? .completed
        let tint = outcome.isSuccess ? TL.jade : (outcome.isFailure ? TL.rec : TL.amber)

        ZStack {
            TL.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                header(session: session, outcome: outcome, tint: tint)
                    .padding(.top, 20)

                if let s = session, s.videoFileName != nil, let url = s.videoURL {
                    previewCard(session: s, url: url)
                        .padding(.top, 16)
                        .padding(.horizontal, 20)
                } else if saved {
                    savedCard
                        .padding(.top, 16)
                        .padding(.horizontal, 20)
                }

                Spacer(minLength: 12)

                Button("종료") { app.dismissResult() }
                    .buttonStyle(TLPrimaryButtonStyle(tint: tint))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: 상단 결과 요약 (컴팩트 — 원 아이콘 축소)

    private func header(session: FocusSession?, outcome: SessionOutcome, tint: Color) -> some View {
        VStack(spacing: 6) {
            // 결과 아이콘: 완주 = 스마일 캐릭터 / 실패·긴급 = 앵그리 캐릭터 / 그 외 = 기존 심볼
            if outcome.isSuccess {
                ZStack {
                    // 성공 리플 — 옥색 링이 퍼지며 사라진다 (은은한 성공감)
                    Circle()
                        .stroke(TL.jade.opacity(successRipple ? 0 : 0.7), lineWidth: 3)
                        .frame(width: 90, height: 90)
                        .scaleEffect(successRipple ? 2.0 : 0.85)

                    Image("MotiSmile")
                        .resizable().scaledToFit()
                        .frame(width: 84, height: 84)
                        .scaleEffect(successPop ? 1 : 0.45)
                        .shadow(color: TL.jade.opacity(successPop ? 0.35 : 0), radius: 16)
                }
                .overlay {
                    // 슬롯 확장·미친맛 해제 순간의 축하 파티클 (해당자만 — 리플 위에 추가)
                    if engine.lastSlotBonus != nil || engine.lastUnlockBonus != nil {
                        ConfettiBurst()
                    }
                }
                .onAppear {
                    withAnimation(TLMotion.bouncy) { successPop = true }
                    withAnimation(.easeOut(duration: 0.9).delay(0.1)) { successRipple = true }
                }
            } else if outcome.isFailure || outcome == .emergency {
                Image("MotiAngry")
                    .resizable().scaledToFit()
                    .frame(width: 84, height: 84)
            } else {
                ZStack {
                    Circle().strokeBorder(tint, lineWidth: 5).frame(width: 76, height: 76)
                    Image(systemName: symbol(for: outcome))
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(tint)
                }
            }

            Text(title(for: outcome))
                .font(.tlTitle(22))
                .foregroundStyle(TL.paper)
                .padding(.top, 8)

            if let s = session {
                Text(s.activityName)
                    .font(.system(size: 13)).foregroundStyle(TL.muted)
                Text("순수 촬영 \(TLFormat.hms(s.recordedSeconds)) / 목표 \(TLFormat.hms(s.targetSeconds))")
                    .font(.tlTimer(15)).foregroundStyle(TL.paper)

                if let (_, points) = ScoreRules.points(for: outcome, intensity: s.intensity,
                                                       durationMinutes: s.targetSeconds / 60) {
                    HStack(spacing: 8) {
                        Text(points > 0 ? "+\(points)점 적립" : "\(points)점 벌점")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(points > 0 ? TL.jade : TL.rec)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(TL.surface))
                        if points < 0 {
                            Text("누적 벌점 \(penaltyCount)회")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(TL.rec)
                        }
                    }
                    .padding(.top, 4)

                    // 슬롯 확장 보너스 — 연속 달성 단계를 넘은 순간에만 (파티클과 함께)
                    if let bonus = engine.lastSlotBonus {
                        Label("연속 \(bonus.days)일 달성! 보너스 상점 +\(bonus.points)",
                              systemImage: "party.popper.fill")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .foregroundStyle(TL.ink)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(TL.amber))
                            .shadow(color: TL.amber.opacity(0.5), radius: 10)
                            .padding(.top, 6)
                    }

                    // 미친 매운맛 잠금 해제 보너스 — 매운맛 완주 3회째 순간에만 (평생 1회)
                    if let unlockPoints = engine.lastUnlockBonus {
                        Label("미친 매운맛 잠금 해제! 보너스 상점 +\(unlockPoints)",
                              systemImage: "flame.fill")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .foregroundStyle(TL.paper)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(TL.rec))
                            .shadow(color: TL.rec.opacity(0.5), radius: 10)
                            .padding(.top, 6)
                    }
                } else {
                    Text("벌점 없음")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TL.amber)
                        .padding(.top, 4)
                }
            }
        }
    }

    // MARK: 타임랩스 미리보기 + 저장 (지금 저장 안 하면 닫을 때 삭제)

    private func previewCard(session: FocusSession, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TLEyebrow(text: "타임랩스 미리보기")

            // 미리보기 = 촬영 결과물과 동일 비율(세로 9:16 / 가로 16:9), 잘림 없음.
            // 카드 프레임을 영상 비율에 맞추고 resizeAspect로 그려 "잘린 데 없이" 확인 가능.
            TimelapsePreview(url: url)
                .aspectRatio(previewAspect(for: session), contentMode: .fit)
                .frame(maxHeight: previewMaxHeight(for: session))
                .clipShape(RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                        .strokeBorder(TL.hairline, lineWidth: 1))
                .overlay(alignment: .topTrailing) { saveButton(session: session).padding(10) }
                .frame(maxWidth: .infinity)   // 카드 안에서 가로 중앙 정렬

            Text(saved
                 ? "저장 완료 · 원본은 기기에서 삭제되었습니다."
                 : "저장하지 않으면 닫을 때 삭제됩니다. 기록·점수는 유지됩니다.")
                .font(.system(size: 11))
                .foregroundStyle(TL.faint)

            if let saveError {
                Text(saveError).font(.system(size: 11, weight: .semibold)).foregroundStyle(TL.rec)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
    }

    /// 촬영 결과물의 가로세로 비율 (세로 1080×1920 = 9:16, 가로 1920×1080 = 16:9)
    private func previewAspect(for session: FocusSession) -> CGFloat {
        app.sessionOrientation == .landscape ? 16.0 / 9.0 : 9.0 / 16.0
    }

    /// 비율을 유지하되 한 화면에 들어오도록 높이 상한만 둔다
    /// (세로는 높이가, 가로는 카드 너비가 실제 크기를 결정)
    private func previewMaxHeight(for session: FocusSession) -> CGFloat {
        app.sessionOrientation == .landscape ? 240 : 360
    }

    /// 저장 완료 후 확인 카드 (원본 삭제되어 미리보기는 사라짐)
    private var savedCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22)).foregroundStyle(TL.jade)
            VStack(alignment: .leading, spacing: 2) {
                Text("타임랩스가 사진 앱에 저장되었습니다")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(TL.paper)
                Text("기록·점수는 유지됩니다.")
                    .font(.system(size: 12)).foregroundStyle(TL.faint)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
    }

    private func saveButton(session: FocusSession) -> some View {
        Button {
            save(session: session)
        } label: {
            Group {
                if saving {
                    SaveSpinner()
                } else {
                    Image(systemName: saved ? "checkmark" : "arrow.down.to.line")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TL.ink)
                }
            }
            .frame(width: 38, height: 38)
            .background(Circle().fill(saved ? TL.jade : TL.paper))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        }
        .pressableStyle()
        .disabled(saving || saved)
    }

    private func save(session: FocusSession) {
        guard let url = session.videoURL else { return }
        saveError = nil
        saving = true
        // 멤버십 = 무조건 워터마크 제거, 비구독 = 항상 포함 (선택지 없음)
        let watermarked = !subscription.isPro
        Task {
            defer { saving = false }
            do {
                try await VideoDownloader.saveToPhotos(videoURL: url, watermarked: watermarked)
                // 정책: 다운로드 완료 즉시 원본 삭제.
                // 순서 중요 — DB에서 참조를 먼저 끊어 저장을 확정한 뒤에 파일을 지운다.
                // (먼저 지우고 저장이 실패하면 DB가 '없는 파일'을 참조해 미리보기가 깨진다)
                session.videoFileName = nil
                do {
                    try context.save()
                    try? FileManager.default.removeItem(at: url)
                    saved = true
                } catch {
                    session.videoFileName = url.lastPathComponent   // 롤백 — 파일·참조 모두 보존
                    saveError = "저장 상태를 기록하지 못했어요. 다시 시도해주세요."
                }
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
}

// MARK: - 타임랩스 미리보기 (재생 버튼으로 1회 재생, 끝나면 다시 버튼)

struct TimelapsePreview: View {
    let url: URL

    @State private var player: AVPlayer
    @State private var isPlaying = false

    init(url: URL) {
        self.url = url
        let p = AVPlayer(url: url)
        p.isMuted = true
        _player = State(initialValue: p)
    }

    var body: some View {
        ZStack {
            PlayerLayerView(player: player)

            // 대기 상태에서만 중앙 재생 버튼 (재생 중엔 숨김, 한 번 끝나면 다시 표시)
            if !isPlaying {
                Color.black.opacity(0.18)
                Button {
                    play()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 6)
                }
                .pressableStyle()
            }
        }
        .onAppear {
            // 첫 프레임을 포스터로 노출
            player.seek(to: .zero)
        }
        .onDisappear { player.pause() }
        .onReceive(NotificationCenter.default.publisher(
            for: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)) { _ in
            isPlaying = false   // 한 사이클 끝 → 재생 버튼 복귀
        }
    }

    private func play() {
        player.seek(to: .zero)
        player.play()
        isPlaying = true
    }
}

/// AVPlayer를 그리는 얇은 레이어 뷰
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect   // 잘림 없이 전체 프레임 표시
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - 저장 진행 스피너 — 꼬리가 잦아드는 아크 (연타 방지 시각 피드백)

private struct SaveSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.06, to: 0.94)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [TL.ink.opacity(0), TL.ink]),
                    center: .center,
                    startAngle: .degrees(0), endAngle: .degrees(320)),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            .frame(width: 17, height: 17)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
