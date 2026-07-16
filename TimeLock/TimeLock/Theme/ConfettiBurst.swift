//
//  ConfettiBurst.swift
//  AngryMoti
//
//  축하 파티클 — 중앙에서 사방으로 터지는 콘페티.
//  슬롯 확장 보너스 등 '특별한 순간'에만 아껴 쓴다. onAppear 시 1회 재생.
//

import SwiftUI

struct ConfettiBurst: View {
    var count: Int = 30
    @State private var fired = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let palette: [Color] = [TL.jade, TL.amber, TL.rec, TL.paper]

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                particle(index: i)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.1)) { fired = true }
        }
    }

    /// 인덱스 기반 결정적 난수 (프레임마다 흔들리지 않게)
    private func rand(_ i: Int, _ salt: Double) -> Double {
        abs(sin(Double(i) * 12.9898 + salt * 78.233)).truncatingRemainder(dividingBy: 1)
    }

    private func particle(index i: Int) -> some View {
        let angle = (Double(i) / Double(count)) * 2 * .pi + rand(i, 1) * 0.5
        let distance = 70 + rand(i, 2) * 90            // 70~160pt 비산
        let size = 5 + rand(i, 3) * 6                  // 5~11pt
        let color = Self.palette[i % Self.palette.count]
        let isCapsule = i % 3 == 0
        let spin = rand(i, 4) * 540 - 270              // -270°~270° 회전

        return Group {
            if isCapsule {
                Capsule().fill(color).frame(width: size * 0.45, height: size * 1.6)
            } else {
                Circle().fill(color).frame(width: size, height: size)
            }
        }
        .rotationEffect(.degrees(fired ? spin : 0))
        .offset(x: fired ? cos(angle) * distance : 0,
                y: fired ? sin(angle) * distance + 18 : 0)   // 살짝 아래로 낙하감
        .scaleEffect(fired ? 0.55 : 1)
        .opacity(fired ? 0 : 1)
    }
}
