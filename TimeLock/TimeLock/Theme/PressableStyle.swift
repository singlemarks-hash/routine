//
//  PressableStyle.swift
//  TimeLock
//
//  앱 전체 버튼에 공통 탭 피드백을 주는 재사용 스타일.
//  배경·색 등 시각 스타일은 건드리지 않고 '눌림 반응'만 얹으므로
//  어떤 버튼에도 그대로 덧붙일 수 있다.
//
//  사용법:  Button { … } label: { … }.pressableStyle()
//  옵션:    .pressableStyle(scale: 0.94, haptics: false)
//

import SwiftUI
import UIKit

/// 눌림 시 살짝 축소 + 흐려짐 + 가벼운 햅틱. (TLMotion.press 커브 사용)
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var dimsOnPress: Bool = true
    var haptics: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(dimsOnPress && configuration.isPressed ? 0.85 : 1)
            .animation(TLMotion.press, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed && haptics {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}

extension View {
    /// 버튼에 공통 탭 피드백(눌림 축소·흐려짐·햅틱)을 붙인다.
    /// 커스텀 시각 스타일(TLPrimaryButtonStyle 등)이 이미 있는 버튼에는 쓰지 않는다
    /// — 그 스타일들이 자체 눌림 피드백을 갖고 있고, ButtonStyle은 하나만 적용되기 때문.
    /// 시각 스타일이 없는(=.plain 성격의) 버튼에 붙이면 된다.
    func pressableStyle(scale: CGFloat = 0.96,
                        dimsOnPress: Bool = true,
                        haptics: Bool = true) -> some View {
        buttonStyle(PressableButtonStyle(scale: scale,
                                         dimsOnPress: dimsOnPress,
                                         haptics: haptics))
    }
}
