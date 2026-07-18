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
    /// 이용약관 — 노션 공개 페이지 (App Store Connect의 EULA 필드에도 동일 주소 등록)
    static let termsOfUseURL = URL(string:
        "https://singlemark.notion.site/39f41b10f64b8026ab19cab6bf66ade2")!

    /// 개인정보처리방침 — 노션 공개 페이지 (App Store Connect '개인정보처리방침 URL'에 동일 등록)
    static let privacyPolicyURL = URL(string:
        "https://singlemark.notion.site/39f41b10f64b80d2acaffcb5815106a9")!

    /// 자동 갱신 구독 고지 (App Store 3.1.2 필수 문구).
    static let subscriptionDisclosure =
        "앵그리모티 멤버십은 월 단위 자동 갱신 구독입니다. 현재 결제 기간이 끝나기 최소 24시간 전에 해지하지 않으면 등록된 Apple 계정으로 자동 갱신·청구됩니다. 구매 후 App Store 계정 설정에서 언제든 관리·해지할 수 있습니다."
}

/// 이용약관·개인정보처리방침 링크 한 줄. 구독을 노출하는 화면에 공통으로 붙인다.
struct LegalLinksRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Link("이용약관", destination: Legal.termsOfUseURL)
            Text("·").foregroundStyle(TL.faint)
            Link("개인정보처리방침", destination: Legal.privacyPolicyURL)
        }
        .font(.system(size: 12, weight: .semibold))
        .tint(TL.muted)
    }
}
