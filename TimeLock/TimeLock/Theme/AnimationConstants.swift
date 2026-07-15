//
//  AnimationConstants.swift
//  TimeLock
//
//  앱 전역 애니메이션 컨벤션.
//  화면마다 제각각인 duration/spring 값을 흩뿌리지 말고,
//  여기 정의한 프리셋(TLMotion)만 사용해 모션에 일관된 성격을 준다.
//
//  선택 기준
//  - quick   : 버튼 탭·누름처럼 즉각 반응해야 하는 짧은 인터랙션
//  - smooth  : 화면 전환·레이아웃 변경처럼 눈이 따라가야 하는 큰 움직임
//  - bouncy  : 완주·상점 적립 등 성취를 강조하는 보상 피드백
//  - snappy  : 토글·선택처럼 딱 떨어지는 짧은 상태 변화
//  - progress: 타이머 링·부채꼴처럼 일정 속도로 흐르는 연속 진행
//

import SwiftUI

enum TLMotion {

    // MARK: - 원시 상수 (커스텀 조합이 필요할 때 직접 참조)

    /// 스프링 파라미터 (response = 반응 속도, dampingFraction = 튕김 억제; 1에 가까울수록 덜 튕김)
    enum Spring {
        static let quickResponse:  Double = 0.25
        static let quickDamping:   Double = 0.85

        static let smoothResponse: Double = 0.45
        static let smoothDamping:  Double = 0.90

        static let bouncyResponse: Double = 0.50
        static let bouncyDamping:  Double = 0.58
    }

    /// 이징 지속시간
    enum Duration {
        static let instant: Double = 0.12   // 눌림 등 거의 즉시
        static let fast:    Double = 0.20    // 짧은 상태 변화
        static let base:    Double = 0.30    // 기본
        static let slow:    Double = 0.45    // 진행/전환
    }

    // MARK: - 프리셋 애니메이션 (기본은 이걸 쓴다)

    /// 버튼 탭·누름 — 즉각적이고 짧은 스프링
    static let quick = Animation.spring(response: Spring.quickResponse,
                                        dampingFraction: Spring.quickDamping)

    /// 화면 전환·레이아웃 변경 — 부드러운 스프링
    static let smooth = Animation.spring(response: Spring.smoothResponse,
                                         dampingFraction: Spring.smoothDamping)

    /// 완주·상점 등 성공 피드백 — 탄력 있는 스프링
    static let bouncy = Animation.spring(response: Spring.bouncyResponse,
                                         dampingFraction: Spring.bouncyDamping)

    /// 토글·선택 등 짧은 상태 변화 — 딱 떨어지는 이징
    static let snappy = Animation.easeInOut(duration: Duration.fast)

    /// 눌림 피드백 — 거의 즉시
    static let press = Animation.easeOut(duration: Duration.instant)

    /// 타이머 링·부채꼴 등 연속 진행 — 등속
    static let progress = Animation.linear(duration: Duration.slow)
}
