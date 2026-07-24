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
            Text("두 가지 권한을 허용해 주세요")
                .font(.tlTitle(28))
                .foregroundStyle(TL.paper)
                .padding(.top, 8)
            Text("카메라와 알람에 사용됩니다. 지금 허용하지 않아도 앱을 둘러볼 수 있고, 촬영·알람을 쓸 때 다시 요청합니다.")
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

            // 저장공간 부족 경고 — 촬영 중단이 이탈로 간주될 수 있음을 미리 고지.
            // 위 권한 카드와 동일한 '아이콘(32) + 제목/설명' 레이아웃으로 통일 (기본 이모지 대신 SF Symbol).
            TLCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(TL.amber)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("저장공간 용량 확인")
                            .font(.tlTitle(15)).foregroundStyle(TL.paper)
                        Text("저장공간이 부족하여 중간에 타임랩스가 중단되면, 이탈로 간주되어 패널티를 받을 수 있습니다. 미리 충분한 저장공간을 꼭 확보해 주세요.")
                            .font(.system(size: 13)).foregroundStyle(TL.amber)
                            .lineSpacing(3)
                    }
                }
            }
            .padding(.top, 12)

            // 권한은 선택 — 거부해도 온보딩을 진행할 수 있어야 한다(App Review 4.5.4/5.1.1).
            // 설정 앱으로 강제 유도하지 않고, 실제로 촬영·알람을 사용할 때 다시 안내한다.
            if cameraGranted == false || notifGranted == false {
                Text("나중에 허용해도 괜찮아요. 촬영·알람 기능을 사용할 때 다시 안내해 드립니다.")
                    .font(.system(size: 13))
                    .foregroundStyle(TL.muted)
                    .padding(.top, 16)
            }

            Spacer()

            Button("다음") { next() }
                .buttonStyle(TLPrimaryButtonStyle())
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
    }

    private func permissionRow(icon: String, title: String, detail: String,
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

            Text("미친 매운맛은 매운맛 완주 3회 후 잠금 해제됩니다.\n(멤버십은 조건 없이 바로 사용할 수 있어요)")
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
