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
        .fullScreenCover(isPresented: alarmBinding) {
            if case let .alarm(id, fire) = app.route, let reservation = app.reservation(id: id) {
                AlarmView(reservation: reservation, fireDate: fire)
            }
        }
        .fullScreenCover(isPresented: mountBinding) {
            if case let .mountGuide(pending) = app.route {
                MountGuideView(pending: pending)
            }
        }
        .fullScreenCover(isPresented: sessionBinding) {
            SessionView()
        }
        .fullScreenCover(isPresented: resultBinding) {
            SessionResultView()
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

    private var alarmBinding: Binding<Bool> {
        Binding(get: { if case .alarm = app.route { return true }; return false },
                set: { if !$0, case .alarm = app.route { app.route = .none } })
    }
    private var mountBinding: Binding<Bool> {
        Binding(get: { if case .mountGuide = app.route { return true }; return false },
                set: { if !$0, case .mountGuide = app.route { app.route = .none } })
    }
    private var sessionBinding: Binding<Bool> {
        Binding(get: { app.route == .session },
                set: { if !$0, app.route == .session { app.route = .none } })
    }
    private var resultBinding: Binding<Bool> {
        Binding(get: { app.route == .result },
                set: { if !$0, app.route == .result { app.dismissResult() } })
    }
}

// MARK: - 탭

struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("오늘", systemImage: "clock.fill") }
            CalendarView()
                .tabItem { Label("기록", systemImage: "calendar") }
            SettingsView()
                .tabItem { Label("설정", systemImage: "gearshape.fill") }
        }
        .background(TL.ink)
    }
}
