//
//  Legal.swift
//  AngryMoti
//
//  App Store 심사 규정 3.1.2(자동 갱신 구독)에서 요구하는 약관·정책 링크와
//  자동 갱신 고지 문구를 한 곳에 모은다. 구독을 노출하는 모든 화면(페이월·설정)이
//  이 상수를 공유하므로 문구·URL이 서로 어긋나지 않는다.
//

import Foundation
import SwiftUI

enum Legal {
    /// 기기 언어가 한국어인가 (D1: ko 외에는 전부 영어)
    private static var isKorean: Bool {
        Locale.current.language.languageCode?.identifier == "ko"
    }

    /// 이용약관 — 노션 공개 페이지. 언어별 하위 페이지로 바로 보낸다.
    /// App Store Connect의 EULA 필드에는 두 언어를 모두 담은 허브 페이지를 등록한다
    /// (심사자가 어느 언어든 찾을 수 있도록):
    /// https://singlemark.notion.site/Terms-of-Use-3be41b10f64b80edaf31da1742338b2c
    static var termsOfUseURL: URL {
        URL(string: isKorean
            ? "https://singlemark.notion.site/39f41b10f64b8026ab19cab6bf66ade2"
            : "https://singlemark.notion.site/Terms-of-Use-English-3be41b10f64b8016ba06e582c2a03caf")!
    }

    /// 개인정보처리방침 — 위와 동일. App Store Connect '개인정보처리방침 URL'에는 허브를 등록한다:
    /// https://singlemark.notion.site/Privacy-Policy-3be41b10f64b80788968de130cb0a7d2
    static var privacyPolicyURL: URL {
        URL(string: isKorean
            ? "https://singlemark.notion.site/39f41b10f64b80d2acaffcb5815106a9"
            : "https://singlemark.notion.site/Privacy-Policy-English-3be41b10f64b80d99cc8d8ed818fc6ec")!
    }

    /// 복원할 구독을 못 찾았을 때. 복원은 없는 구독을 만들어내지 못하므로 이건 정상 동작이지만,
    /// 암호까지 입력한 사용자에게 아무 반응이 없으면 고장으로 읽힌다.
    static let restoreNotFoundMessage = String(localized:
        "We couldn't find a subscription to restore. Make sure you're signed in with the Apple ID you subscribed with. If you haven't subscribed yet, please subscribe first.")

    /// 자동 갱신 구독 고지 (App Store 3.1.2 필수 문구).
    static let subscriptionDisclosure = String(localized:
        "AngryMoti Membership is a monthly auto-renewing subscription. Unless cancelled at least 24 hours before the end of the current billing period, it will automatically renew and charge your Apple ID account. You can manage or cancel anytime in your App Store account settings after purchase.")

    /// 숫자 App Store ID — 앱 승인 후 App Store Connect에서 확인해 채운다.
    /// 비어 있으면 '리뷰 남기기'는 SKStoreReviewController 요청으로 폴백한다.
    static let appStoreID = "6792526569"

    /// App Store 리뷰 작성 페이지 딥링크 (ID가 있을 때만).
    static var writeReviewURL: URL? {
        guard !appStoreID.isEmpty else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }
}

/// 이용약관·개인정보처리방침 링크 한 줄. 구독을 노출하는 화면에 공통으로 붙인다.
struct LegalLinksRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Link("Terms of Use", destination: Legal.termsOfUseURL)
            Text("·").foregroundStyle(TL.faint)
            Link("Privacy Policy", destination: Legal.privacyPolicyURL)
        }
        .font(.system(size: 12, weight: .semibold))
        .tint(TL.muted)
    }
}
