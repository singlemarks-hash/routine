//
//  OnboardingFlow.swift
//  TimeLock
//
//  첫 실행 흐름: 1. 촬영하기 → 2. 기록관리 (로그인보다 먼저, 설명을 먼저 보여줘 로그인 장벽을 낮춘다)
//  → 로그인 → 3. 권한 설정 → 홈.
//  강도 선택 단계는 폐기 — 강도는 활동별 설정으로 옮겨졌다.
//

import SwiftUI

/// 로그인 이전, 기기 최초 1회만 보여주는 인트로 2페이지(촬영하기·기록관리).
/// TabView(.page)로 감싸 스와이프로 앞뒤 이동이 가능하다 — 버튼은 앞으로만 가지만,
/// 뒤로는 스와이프나 2페이지의 이전 버튼으로 돌아갈 수 있다.
struct IntroFlow: View {
    var onFinish: () -> Void
    @State private var step = 0

    var body: some View {
        ZStack {
            TL.ink.ignoresSafeArea()
            // 로그인 화면과 같은 계열의 레드 글로우 — 여기선 하단에서 위로 번지는 방향.
            LinearGradient(
                stops: [
                    .init(color: TL.rec.opacity(0.28), location: 0),
                    .init(color: TL.rec.opacity(0.10), location: 0.35),
                    .init(color: .clear, location: 0.7),
                ],
                startPoint: .bottom, endPoint: .top)
                .ignoresSafeArea()
            TabView(selection: $step) {
                ShootStep { step = 1 }
                    .tag(0)
                RecordStep(onBack: { step = 0 }) { onFinish() }
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }
}

/// 로그인 이후, 홈 진입 전 권한 설정 1페이지.
struct OnboardingFlow: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ZStack {
            TL.ink.ignoresSafeArea()
            PermissionStep { app.onboarded = true }
        }
    }
}

// MARK: - 1. 촬영하기

private struct ShootStep: View {
    var next: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 110)
            TLEyebrow(text: "촬영하기")
            Text("예약한 시각에 알람이 울리면\n바로 타임랩스를 촬영하세요")
                .font(.tlTitle(26))
                .foregroundStyle(TL.paper)
                .lineSpacing(5)
                .padding(.top, 10)
            Text("내가 지정한 시간만큼 몰입 타이머가 시작돼요\n끝까지 완주하면 상점, 그만두면 벌점이 쌓여요")
                .font(.tlBody)
                .foregroundStyle(TL.muted)
                .lineSpacing(4)
                .padding(.top, 14)

            Spacer()

            // 책상에서 타임랩스 촬영 중인 모티 — 우측 정렬
            HStack {
                Spacer()
                Image("OnboardingShoot")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240)
                    .scaleEffect(appeared ? 1 : 0.9)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7), value: appeared)
                    .onAppear { appeared = true }
            }

            Spacer()

            Button("다음") { next() }
                .buttonStyle(TLPrimaryButtonStyle())
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - 2. 기록관리

private struct RecordStep: View {
    var onBack: () -> Void
    var next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(TL.muted)
                    .padding(8)
            }
            Spacer().frame(height: 22)
            TLEyebrow(text: "기록관리")
            Text("의지가 아닌, 실행할 수 밖에 없는\n환경을 만들어요")
                .font(.tlTitle(26))
                .foregroundStyle(TL.paper)
                .lineSpacing(5)
                .padding(.top, 10)
            Text("목표달성을 위한 나의 몰입을 기록해요\n모티가 강력한 실행환경을 만들어 줄 거에요")
                .font(.tlBody)
                .foregroundStyle(TL.muted)
                .lineSpacing(4)
                .padding(.top, 14)

            Spacer()

            streakCardMock

            Spacer()

            Button("다음") { next() }
                .buttonStyle(TLPrimaryButtonStyle())
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
    }

    /// 홈 연속달성 카드의 정적 목업 — 실데이터 화면과 같은 구성이라 에셋이 필요 없다.
    private var streakCardMock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("연속달성").font(.system(size: 13, weight: .bold)).foregroundStyle(TL.muted)
                        Image("fire").resizable().scaledToFit().frame(width: 15, height: 15)
                    }
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text("3").font(.tlTimer(38)).foregroundStyle(TL.jade)
                        Text("일").font(.system(size: 17, weight: .bold)).foregroundStyle(TL.muted)
                    }
                    (Text("총 ").font(.system(size: 13, weight: .semibold)).foregroundColor(TL.muted)
                     + Text("506").font(.system(size: 13, weight: .heavy)).foregroundColor(TL.jade)
                     + Text("시간 ").font(.system(size: 13, weight: .semibold)).foregroundColor(TL.muted)
                     + Text("16").font(.system(size: 13, weight: .heavy)).foregroundColor(TL.jade)
                     + Text("분을 기록했어요!").font(.system(size: 13, weight: .semibold)).foregroundColor(TL.muted))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("최고기록").font(.system(size: 12, weight: .semibold)).foregroundStyle(TL.muted)
                            Image("average").resizable().scaledToFit().frame(width: 13, height: 13)
                        }
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            Text("56").font(.tlTimer(17)).foregroundStyle(TL.paper)
                            Text("일").font(.system(size: 12)).foregroundStyle(TL.muted)
                        }
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("평균 일정").font(.system(size: 12, weight: .semibold)).foregroundStyle(TL.muted)
                            Image("record").resizable().scaledToFit().frame(width: 13, height: 13)
                        }
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            Text("4.2").font(.tlTimer(17)).foregroundStyle(TL.paper)
                            Text("개").font(.system(size: 12)).foregroundStyle(TL.muted)
                        }
                    }
                }
            }

            HStack(spacing: 0) {
                mockDay("목", "23", icon: "success")
                mockDay("목", "23", icon: "fail")
                mockDay("금", "24", icon: "half")
                mockDay("토", "25", icon: "success")
                mockDay("일", "26", icon: "success", highlighted: true)
                mockDay("월", "27", icon: "not_started")
            }
            .padding(.top, 18)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous).fill(TL.surface))
        .overlay(RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
            .strokeBorder(TL.hairline.opacity(0.6), lineWidth: 1))
    }

    private func mockDay(_ weekday: String, _ day: String, icon: String,
                         highlighted: Bool = false) -> some View {
        VStack(spacing: 5) {
            Text(weekday)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(highlighted ? TL.paper : TL.faint)
            Image(icon).resizable().scaledToFit().frame(width: 22, height: 22)
            Text(day)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(highlighted ? TL.paper : TL.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(highlighted ? TL.raised : .clear,
                    in: RoundedRectangle(cornerRadius: TL.cornerS, style: .continuous))
    }
}

// MARK: - 3. 권한 설정

private struct PermissionStep: View {
    var next: () -> Void
    @State private var cameraGranted: Bool?
    @State private var notifGranted: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            TLEyebrow(text: "권한 설정")
            // 심사(5.1.1(iv)) — 허용을 권하는 문구·버튼 금지. 무엇에 쓰는지만 알리고
            // 결정은 시스템 창에 맡긴다. ('허용해 주세요'는 용도 안내 제목으로 유지)
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
            TLCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(TL.amber)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("저장공간 용량 확인")
                            .font(.tlTitle(15)).foregroundStyle(TL.paper)
                        Text("영상 촬영 중간에 녹화가 중단되면, 이탈로 간주되어 패널티를 받을 수 있습니다. 용량 부족으로 타임랩스가 끊기지 않도록 저장공간을 미리 확보해 주세요.")
                            .font(.system(size: 13)).foregroundStyle(TL.amber)
                            .lineSpacing(3)
                    }
                }
            }
            .padding(.top, 12)

            // 권한은 선택 — 거부해도 온보딩을 진행할 수 있어야 한다(App Review 4.5.4/5.1.1).
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
                    // 시스템 권한창 앞 버튼에 '허용'을 쓰면 반려된다 (5.1.1(iv)) —
                    // 이 버튼은 시스템 창을 여는 역할만 한다.
                    Button("계속") { action() }
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(TL.ink)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(TL.paper, in: Capsule())
                }
            }
        }
    }
}
