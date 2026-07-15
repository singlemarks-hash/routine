//
//  Theme.swift
//  TimeLock — 타임락
//
//  다크룸(레코딩 부스) 무드의 단일 디자인 시스템.
//  시그니처: REC 링 — 알람 해제 버튼, 세션 타이머, 캘린더 완주 마크를
//  하나의 원형 모티프로 관통한다. 빨강(rec)은 강제·촬영·실패에만,
//  옥색(jade)은 완주·상점에만 사용한다.
//

import SwiftUI

// MARK: - Palette

enum TL {
    /// 배경: 깊은 잉크 블랙(살짝 보라 기운)
    static let ink        = Color(hex: 0x0F0F13)
    /// 카드 표면
    static let surface    = Color(hex: 0x1A1A21)
    /// 떠 있는 표면(시트, 강조 카드)
    static let raised     = Color(hex: 0x23232C)
    /// 헤어라인
    static let hairline   = Color(hex: 0x2F2F3A)
    /// REC 레드 — 알람·촬영·실패·벌점 전용
    static let rec        = Color(hex: 0xFF4B33)
    /// 옥색 — 완주·상점·성공 전용
    static let jade       = Color(hex: 0x45D6A0)
    /// 앰버 — 경고·유예·임박 전용
    static let amber      = Color(hex: 0xFFB020)
    /// 본문 텍스트(따뜻한 종이색)
    static let paper      = Color(hex: 0xF4F2EC)
    /// 보조 텍스트
    static let muted      = Color(hex: 0x9A98A3)
    /// 비활성
    static let faint      = Color(hex: 0x55535E)

    static let cornerL: CGFloat = 22
    static let cornerM: CGFloat = 14
    static let cornerS: CGFloat = 9
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Typography

extension Font {
    /// 대형 타이머 숫자 — 라운디드 헤비 + 고정폭 숫자
    static func tlTimer(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded).monospacedDigit()
    }
    /// 섹션/카드 타이틀
    static func tlTitle(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
    /// 본문
    static let tlBody = Font.system(size: 16, weight: .regular)
    /// 캡션 라벨(대문자 트래킹은 뷰에서 .tracking으로)
    static let tlLabel = Font.system(size: 12, weight: .semibold, design: .rounded)
}

/// 대문자 트래킹 라벨 ("REC", "다음 활동" 등)
struct TLEyebrow: View {
    let text: String
    var color: Color = TL.muted
    var body: some View {
        Text(text)
            .font(.tlLabel)
            .tracking(2.2)
            .foregroundStyle(color)
    }
}

// MARK: - 시그니처: REC 링

/// 앱 전체를 관통하는 원형 모티프.
/// progress(0~1)에 따라 링이 채워지고, live가 켜지면 REC 점이 맥동한다.
struct RECRing: View {
    var progress: Double
    var live: Bool = false
    var tint: Color = TL.rec
    var lineWidth: CGFloat = 10

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(TL.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.003, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.4), value: progress)
            if live {
                Circle()
                    .fill(tint)
                    .frame(width: lineWidth * 1.15, height: lineWidth * 1.15)
                    .opacity(pulse ? 1 : 0.25)
                    .offset(y: -ringRadiusOffset)
                    .animation(
                        reduceMotion ? nil :
                            .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: pulse
                    )
                    .onAppear { pulse = true }
            }
        }
    }

    private var ringRadiusOffset: CGFloat { 0 } // 점은 중앙 상단이 아닌 링 위 progress 지점 대신 12시 고정
}

/// 세션·알람의 대형 링 + 중앙 콘텐츠
struct RECRingDial<Center: View>: View {
    var progress: Double
    var live: Bool
    var tint: Color
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            RECRing(progress: progress, live: live, tint: tint, lineWidth: 12)
            center()
        }
    }
}

// MARK: - 세션 다이얼: 교실 벽시계 (아날로그)

/// 부채꼴 (파이 조각) — 남은 시간 영역 표현용
struct PieSlice: Shape {
    var startAngle: Angle
    var endAngle: Angle

    var animatableData: Double {
        get { startAngle.degrees }
        set { startAngle = .degrees(newValue) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center,
                    radius: min(rect.width, rect.height) / 2,
                    startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// 세션 진행 화면의 미니멀 시계판 (피그마 시안 + 뽀모도로 눈금).
/// 흰 판 위에 12시부터 시계 방향으로 '남은 시간'만큼의 빨간 부채꼴이 그려지고,
/// 시간이 흐르면 부채꼴이 12시를 향해 줄어든다. 중심에는 검은 점 하나.
/// 바깥 베젤에 5분(짧은 선)·15분(살짝 긴 선) 눈금을 조용히 둘러 시간 감각을 준다.
struct FocusDial: View {
    /// 남은 비율 0~1
    var remaining: Double
    var tint: Color = TL.rec

    private var clamped: Double { min(1, max(0, remaining)) }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let longLen = size * 0.05      // 15분 눈금
            let shortLen = size * 0.03     // 5분 눈금
            let tickW = max(1.5, size * 0.009)
            let outerTip = size / 2 - size * 0.006   // 눈금 바깥 끝(프레임 가장자리 근처)
            let dialInset = longLen + size * 0.04    // 흰 판이 눈금 자리를 비워둠

            ZStack {
                // 뽀모도로 눈금 — 60분 시계 기준 5분마다(12개), 15분마다는 살짝 길게
                ForEach(0..<12) { i in
                    let isQuarter = i % 3 == 0
                    let len = isQuarter ? longLen : shortLen
                    Capsule()
                        .fill(isQuarter ? TL.muted : TL.faint)
                        .frame(width: tickW, height: len)
                        .offset(y: -(outerTip - len / 2))
                        .rotationEffect(.degrees(Double(i) * 30))
                }

                // 흰 시계판 (눈금 안쪽)
                Circle().fill(Color.white).padding(dialInset)

                // 남은 시간 부채꼴 (12시 → 시계 방향)
                PieSlice(startAngle: .degrees(-90),
                         endAngle: .degrees(-90 + 360 * clamped))
                    .fill(tint)
                    .padding(dialInset)
                    .animation(.linear(duration: 0.4), value: clamped)

                // 중심점
                Circle()
                    .fill(TL.ink)
                    .frame(width: size * 0.07, height: size * 0.07)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - 버튼 스타일

struct TLPrimaryButtonStyle: ButtonStyle {
    var tint: Color = TL.rec
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(TL.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(tint, in: RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct TLGhostButtonStyle: ButtonStyle {
    var tint: Color = TL.paper
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: TL.cornerM, style: .continuous)
                    .strokeBorder(TL.hairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - 카드

struct TLCard<Content: View>: View {
    var raised = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
                    .fill(raised ? TL.raised : TL.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TL.cornerL, style: .continuous)
                    .strokeBorder(TL.hairline.opacity(0.6), lineWidth: 1)
            )
    }
}

// MARK: - 태그 칩

struct TagChip: View {
    let name: String
    var selected = false
    var body: some View {
        Text(name)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(selected ? TL.ink : TL.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(selected ? TL.paper : TL.surface)
            )
            .overlay(Capsule().strokeBorder(selected ? .clear : TL.hairline, lineWidth: 1))
    }
}

// MARK: - 시간 포맷 유틸

enum TLFormat {
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"
        return f.string(from: date)
    }
    static func hms(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
    static func durationLabel(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 && m > 0 { return "\(h)시간 \(m)분" }
        if h > 0 { return "\(h)시간" }
        return "\(m)분"
    }
    static func dayTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 EEEE"
        return f.string(from: date)
    }
}
