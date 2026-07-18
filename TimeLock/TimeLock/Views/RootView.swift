//
//  RootView.swift
//  TimeLock
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: SessionEngine
    @EnvironmentObject private var account: AccountStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !app.onboarded {
                OnboardingFlow()
            } else if !account.isSignedIn {
                AuthView()   // 상점·벌점은 계정 단위 — 로그인(또는 게스트) 후 입장
            } else {
                MainTabView()
            }
        }
        .background(TL.ink)
        // 알람→거치→세션→결과를 하나의 커버가 담당한다.
        // 커버를 내렸다 다시 올리는 방식(화면당 커버 1개)은 전환마다 홈 화면이
        // 몇 초씩 노출되는 갭을 만들었다 — 한 커버 안에서 내용만 즉시 교체하면 갭이 없다.
        .fullScreenCover(isPresented: flowBinding) {
            CaptureFlowCover()
        }
        .onChange(of: scenePhase) { _, newPhase in
            app.onScenePhase(newPhase)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            // 화면 잠금(전원 버튼) = 이탈 이벤트
            engine.handleExitEvent()
        }
        .onChange(of: engine.phase) { _, newPhase in
            if case .finished = newPhase, app.route == .session || app.route == .none {
                if engine.lastFinishedSession != nil { app.sessionFinished() }
            }
        }
    }

    private var flowBinding: Binding<Bool> {
        Binding(get: {
            switch app.route {
            case .alarm, .mountGuide, .session, .result: return true
            case .none: return false
            }
        }, set: { shown in
            guard !shown else { return }
            switch app.route {
            case .result: app.dismissResult()
            case .alarm, .mountGuide: app.route = .none
            default: break
            }
        })
    }
}

/// 알람→거치 가이드→세션→결과를 한 커버 안에서 즉시 전환하는 컨테이너.
private struct CaptureFlowCover: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ZStack {
            TL.ink.ignoresSafeArea()
            switch app.route {
            case .alarm(let id, let fire):
                if let reservation = app.reservation(id: id) {
                    AlarmView(reservation: reservation, fireDate: fire)
                }
            case .mountGuide(let pending):
                MountGuideView(pending: pending)
            case .session:
                SessionView()
            case .result:
                SessionResultView()
            case .none:
                Color.clear
            }
        }
        .animation(TLMotion.smooth, value: app.route)
    }
}

// MARK: - 메인 (활동|기록 토글 쉘 — 설정은 홈 우상단 마이페이지로 이동)

struct MainTabView: View {
    var body: some View {
        HomeShellView()
    }
}
