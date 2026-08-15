//
//  L10nScreenshotTests.swift
//  TimeLockUITests
//
//  G2 스크린샷 캡처 (docs/영어화-설계도.md §5) — CI 전용.
//  TEST_RUNNER_SHOT_LOCALE(en|ko)로 앱 언어를 강제해 주요 표면을 XCTAttachment로 남기고,
//  워크플로(ios-screenshots.yml)가 xcresult에서 추출해 shots-ios 브랜치로 푸시한다.
//
//  설계 원칙: 내비게이션 실패는 테스트 실패가 아니다 — 닿은 화면까지만 찍고 넘어간다.
//  (macOS 러너가 비싸서, 한 번의 실행에서 최대한 많은 장면을 건지는 쪽을 우선한다.
//   커버리지 부족은 manifest를 보고 다음 반복에서 좁혀 고친다)
//

import XCTest

final class L10nScreenshotTests: XCTestCase {

    private var shotIndex = 0
    private var locale: String {
        ProcessInfo.processInfo.environment["SHOT_LOCALE"] ?? "en"
    }

    override func setUpWithError() throws {
        continueAfterFailure = true   // 한 장면 실패로 전체 캡처를 버리지 않는다
    }

    // MARK: - 헬퍼

    private func shoot(_ app: XCUIApplication, _ name: String) {
        shotIndex += 1
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = String(format: "%@-%02d-%@", locale, shotIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// en/ko 라벨 후보 중 존재하는 버튼을 탭한다. 실패해도 테스트를 멈추지 않는다.
    @discardableResult
    private func tapAny(_ app: XCUIApplication, _ labels: [String],
                        timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for label in labels {
                // SwiftUI Button은 buttons로, 커스텀 뷰 안의 텍스트 버튼은 staticTexts로 잡히기도 한다
                let button = app.buttons[label]
                if button.exists && button.isHittable { button.tap(); return true }
                let text = app.staticTexts[label]
                if text.exists && text.isHittable { text.tap(); return true }
            }
            usleep(300_000)
        }
        return false
    }

    /// 시스템 권한 알럿(알림·카메라)을 허용으로 닫는다. 러너의 시스템 언어는 영어다.
    private func allowSystemAlerts(maxCount: Int = 3) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<maxCount {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 4) else { return }
            // 허용 계열 버튼이 항상 마지막에 온다 ("Don't Allow" | "Allow" / "OK")
            let buttons = alert.buttons
            let last = buttons.element(boundBy: buttons.count - 1)
            if last.exists { last.tap() }
        }
    }

    // MARK: - 캡처 투어

    @MainActor
    func testCaptureMainSurfaces() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(\(locale))",
            "-AppleLocale", locale == "ko" ? "ko_KR" : "en_US",
        ]
        app.launch()
        sleep(2)

        // 1) 온보딩 — 페이지마다 찍고 다음으로. 이미 끝난 상태면 루프가 바로 빠진다.
        for page in 1...4 {
            let advanced: Bool
            if page == 1 {
                shoot(app, "onboarding-\(page)")
                advanced = tapAny(app, ["Next", "다음"], timeout: 4)
            } else {
                shoot(app, "onboarding-\(page)")
                advanced = tapAny(app, ["Next", "다음", "Continue", "계속"], timeout: 4)
            }
            if !advanced { break }
            sleep(1)
            if page >= 3 { allowSystemAlerts() }   // 권한 페이지 뒤 시스템 알럿 처리
        }
        sleep(1)

        // 2) 인증 화면 (온보딩 종료 후 도달)
        if app.buttons["Continue as Guest"].waitForExistence(timeout: 6)
            || app.buttons["게스트로 시작"].waitForExistence(timeout: 2) {
            shoot(app, "auth")
            tapAny(app, ["Continue as Guest", "게스트로 시작"])
            sleep(2)
        }

        // 3) 홈 — 활동(Focus) 탭
        shoot(app, "home-focus")

        // 4) 일정(Plan) 탭
        if tapAny(app, ["Plan", "일정"]) {
            sleep(1)
            shoot(app, "plan")
        }

        // 5) 활동 탭 복귀 후 마이페이지 (우상단 프로필 아이콘 — 에셋명으로 조회)
        tapAny(app, ["Focus", "활동"])
        sleep(1)
        let profile = app.images["profile"].firstMatch
        if profile.exists && profile.isHittable {
            profile.tap()
        } else {
            // NavigationLink가 버튼으로 노출되는 경우
            let profileButton = app.buttons["profile"].firstMatch
            if profileButton.exists { profileButton.tap() }
        }
        sleep(1)
        if app.staticTexts["My Page"].exists || app.staticTexts["마이페이지"].exists {
            shoot(app, "mypage")

            // 6) 마이페이지 하위 화면들 — 각각 들어가 찍고 뒤로
            let subScreens: [(names: [String], shot: String)] = [
                (["Profile & Subscription", "프로필 및 구독 관리"], "profile-guest"),
                (["Privacy", "프라이버시"], "privacy"),
                (["Score Ledger", "점수 원장"], "ledger"),
                (["App Language", "앱 언어"], "app-language"),
            ]
            for screen in subScreens {
                guard tapAny(app, screen.names, timeout: 4) else { continue }
                sleep(1)
                shoot(app, screen.shot)
                app.navigationBars.buttons.firstMatch.tap()   // 뒤로
                sleep(1)
            }
        }

        // 항상 통과 — 수확량은 xcresult manifest로 판단한다
        XCTAssertTrue(shotIndex > 0, "스크린샷이 한 장도 찍히지 않았다")
    }
}
