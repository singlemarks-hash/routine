//
//  OnboardingFlow.swift
//  TimeLock
//
//  1. 컨셉 — 알람을 끄는 유일한 방법은 촬영 시작
//  2. 권한 — 카메라 / 알림 (거부 시 제약 고지)
//  3. 강도 — 매운맛 선택 (미친 매운맛은 완주 3회 후 잠금 해제)
//

import SwiftUI

struct OnboardingFlow: View {
    @EnvironmentObject private var app: AppState
    @State private var step = 0

    var body: some View {
        ZStack {
            TL.ink.ignoresSafeArea()
            switch step {
            case 0: ConceptStep { step = 1 }
            case 1: PermissionStep { step = 2 }
            default: IntensityStep { app.onboarded = true }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }
}

// MARK: - 1. 컨셉

private struct ConceptStep: View {
    var next: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            // 캐릭터 이미지 — 기존 링(220) 대비 1/2 크기(110)
            Image("OnboardingCharacter")
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 110)
                .scaleEffect(appeared ? 1 : 0.8)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.6, dampingFraction: 0.7), value: appeared)
                .onAppear { appeared = true }

            Spacer().frame(height: 48)

            VStack(spacing: 14) {
                Text("알람을 끄는 유일한 방법,\n촬영 시작.")
                    .font(.tlTitle(26))
                    .foregroundStyle(TL.paper)
                    .multilineTextAlignment(.center)
                Text("예약한 시각에 알람이 울리면 10분 안에\n전면 카메라 타임랩스를 시작해야 합니다.\n촬영이 곧 잠금이 되어 끝까지 지켜봅니다.")
                    .font(.tlBody)
                    .foregroundStyle(TL.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 32)

            Spacer()

            Button("시작하기") { next() }
                .buttonStyle(TLPrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
    }
}

// MARK: - 2. 권한

private struct PermissionStep: View {
    var next: () -> Void
    @State private var cameraGranted: Bool?
    @State private var notifGranted: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            TLEyebrow(text: "권한 설정")
            Text("두 가지가 필요합니다")
                .font(.tlTitle(28))
                .foregroundStyle(TL.paper)
                .padding(.top, 8)
            Text("앵그리모티의 강제력은 카메라와 알람에서 나옵니다.")
                .font(.tlBody)
                .foregroundStyle(TL.muted)
                .padding(.top, 6)

            VStack(spacing: 12) {
                permissionRow(icon: "camera.fill", title: "카메라",
                              detail: "알람 해제와 세션 기록에 사용합니다. 영상은 기기에만 저장되고 본인만 봅니다.",
                              granted: cameraGranted) {
                    Task { cameraGranted = await CameraRecorder.shared.requestAuthorization() }
                }
                permissionRow(icon: "bell.badge.fill", title: "알림",
                              detail: "예약 시각의 알람과 10분 전 예고를 보냅니다.",
                              granted: notifGranted) {
                    Task { notifGranted = await AlarmScheduler.shared.requestAuthorization() }
                }
            }
            .padding(.top, 28)

            if cameraGranted == false || notifGranted == false {
                Text("거부된 권한은 iPhone 설정 › 앵그리모티에서 다시 켤 수 있습니다. 권한 없이는 알람 해제와 세션 기록이 동작하지 않습니다.")
                    .font(.system(size: 13))
                    .foregroundStyle(TL.amber)
                    .padding(.top, 16)
            }

            Spacer()

            Button("다음") { next() }
                .buttonStyle(TLPrimaryButtonStyle())
                .disabled(cameraGranted != true || notifGranted != true)
                .opacity(cameraGranted == true && notifGranted == true ? 1 : 0.4)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
    }

    private func permissionRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey,
                               granted: Bool?, action: @escaping () -> Void) -> some View {
        TLCard {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(TL.rec)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.tlTitle(16)).foregroundStyle(TL.paper)
                    Text(detail).font(.system(size: 13)).foregroundStyle(TL.muted)
                }
                Spacer()
                switch granted {
                case .some(true):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(TL.jade).font(.title3)
                case .some(false):
                    Image(systemName: "xmark.circle.fill").foregroundStyle(TL.rec).font(.title3)
                case .none:
                    Button("허용") { action() }
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(TL.ink)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(TL.paper, in: Capsule())
                }
            }
        }
    }
}

// MARK: - 3. 강도 선택

private struct IntensityStep: View {
    @EnvironmentObject private var app: AppState
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            TLEyebrow(text: "강도 설정")
            Text("얼마나 매울까요")
                .font(.tlTitle(28))
                .foregroundStyle(TL.paper)
                .padding(.top, 8)
            Text("강도는 앱 전체에 하나만 적용됩니다.\n올리는 건 즉시, 내리는 건 다음날 0시부터.")
                .font(.tlBody)
                .foregroundStyle(TL.muted)
                .padding(.top, 6)

            VStack(spacing: 12) {
                IntensityCard(intensity: .spicy, selected: true, locked: false)
                IntensityCard(intensity: .insane, selected: false, locked: true)
            }
            .padding(.top, 28)

            Text("미친 매운맛은 매운맛 완주 3회 후 잠금 해제됩니다.")
                .font(.system(size: 13))
                .foregroundStyle(TL.faint)
                .padding(.top, 14)

            Spacer()

            Button("매운맛으로 시작") { done() }
                .buttonStyle(TLPrimaryButtonStyle())
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
    }
}

struct IntensityCard: View {
    let intensity: Intensity
    var selected: Bool
    var locked: Bool

    var body: some View {
        TLCard(raised: selected) {
            HStack(spacing: 14) {
                Text(intensity.emoji).font(.system(size: 28))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(intensity.title).font(.tlTitle(17)).foregroundStyle(TL.paper)
                        if locked {
                            Label("잠금 해제 전", systemImage: "lock.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(TL.faint)
                        }
                    }
                    Text(intensity.subtitle).font(.system(size: 13)).foregroundStyle(TL.muted)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(TL.rec).font(.title3)
                }
            }
            .opacity(locked ? 0.55 : 1)
        }
    }
}
