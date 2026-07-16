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
    /// 이용약관(EULA). Apple 표준 EULA URL — 자체 약관을 쓰려면 이 URL만 교체하고
    /// App Store Connect의 EULA도 동일하게 맞춘다. (표준 EULA는 별도 등록 불필요)
    static let termsOfUseURL = URL(string:
        "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// 개인정보처리방침. 저장소 루트 PRIVACY.md를 GitHub가 렌더링해 공개로 열람 가능.
    /// ⚠️ 배포 전: 이 URL이 실제로 열리는지 확인하고, App Store Connect의
    ///    '개인정보처리방침 URL'에도 동일한 주소를 등록할 것. (자체 도메인이 있으면 교체)
    static let privacyPolicyURL = URL(string:
        "https://github.com/singlemarks-hash/routine/blob/main/PRIVACY.md")!

    /// 자동 갱신 구독 고지 (App Store 3.1.2 필수 문구).
    static let subscriptionDisclosure =
        "앵그리모티 프로는 월 단위 자동 갱신 구독입니다. 현재 결제 기간이 끝나기 최소 24시간 전에 해지하지 않으면 등록된 Apple 계정으로 자동 갱신·청구됩니다. 구매 후 App Store 계정 설정에서 언제든 관리·해지할 수 있습니다."
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
