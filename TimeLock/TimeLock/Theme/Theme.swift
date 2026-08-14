//
//  Theme.swift
//  TimeLock — 앵그리모티
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

    var body: some View {
        ZStack {
            Circle()
                .stroke(TL.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.003, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.4), value: progress)
            // live 맥동 점은 제거 — offset 0으로 링 정중앙에 찍혀 타이머 숫자와
            // 간섭했다. live 파라미터는 호출부 호환을 위해 남긴다.
        }
    }
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
/// 바깥 베젤에는 3단 위계 눈금(1분·5분·15분)을 둘러 시계다운 세밀함과 시간 감각을 준다.
/// 세션이 길수록 1분 눈금은 성글게(뭉침 방지) — minorCount가 줄어든다.
struct FocusDial: View {
    /// 남은 비율 0~1
    var remaining: Double
    var tint: Color = TL.rec
    /// 세션 전체 길이(분). 1분 눈금 밀도 결정에 사용.
    var totalMinutes: Int = 60

    private var clamped: Double { min(1, max(0, remaining)) }

    /// 1분(마이너) 눈금 개수 — 5분(12개)·15분(4개)과 항상 정렬되도록 12의 배수.
    /// 긴 세션일수록 성글게 해서 작은 눈금이 뭉치는 것을 막는다.
    private var minorCount: Int {
        switch totalMinutes {
        case ..<90:  return 60   // ~1.5시간: 1분 간격 (촘촘)
        case ..<240: return 36   // ~4시간: 살짝 성글게
        default:     return 24   // 그 이상: 더 성글게
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let majorLen = size * 0.060   // 15분 — 길고 굵고 밝게
            let midLen   = size * 0.040   // 5분  — 중간
            let minorLen = size * 0.022   // 1분  — 짧고 흐리게
            let majorW = max(2.0, size * 0.012)
            let midW   = max(1.5, size * 0.008)
            let minorW = max(1.0, size * 0.005)
            let outerTip = size / 2 - size * 0.006   // 눈금 바깥 끝
            let dialInset = majorLen + size * 0.04   // 흰 판이 눈금 자리를 비워둠
            let minorStep = minorCount / 12          // 5분 눈금과 겹치는 간격

            ZStack {
                // 1분(마이너) — 5분/15분 위치는 건너뛴다
                ForEach(0..<minorCount, id: \.self) { i in
                    if i % minorStep != 0 {
                        tick(len: minorLen, width: minorW, color: TL.faint,
                             angle: Double(i) * 360 / Double(minorCount), outerTip: outerTip)
                    }
                }
                // 5분(미드) — 15분 위치는 건너뛴다
                ForEach(0..<12, id: \.self) { i in
                    if i % 3 != 0 {
                        tick(len: midLen, width: midW, color: TL.muted,
                             angle: Double(i) * 30, outerTip: outerTip)
                    }
                }
                // 15분(메이저) — 길고 밝게
                ForEach(0..<4, id: \.self) { i in
                    tick(len: majorLen, width: majorW, color: TL.paper,
                         angle: Double(i) * 90, outerTip: outerTip)
                }

                // 흰 시계판 (눈금 안쪽)
                Circle().fill(Color.white).padding(dialInset)

                // 남은 시간 부채꼴 (12시 → 시계 방향)
                PieSlice(startAngle: .degrees(-90),
                         endAngle: .degrees(-90 + 360 * clamped))
                    .fill(tint)
                    .padding(dialInset)
                    .animation(TLMotion.progress, value: clamped)

                // 흰 바늘 — 부채꼴의 진행 경계를 가리킨다 (안드로이드와 공통)
                DialHand(angle: .degrees(-90 + 360 * clamped),
                         length: size / 2 - dialInset,
                         width: max(3, size * 0.014))
                    .animation(TLMotion.progress, value: clamped)

                // 중심점
                Circle()
                    .fill(TL.ink)
                    .frame(width: size * 0.07, height: size * 0.07)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func tick(len: CGFloat, width: CGFloat, color: Color,
                      angle: Double, outerTip: CGFloat) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: len)
            .offset(y: -(outerTip - len / 2))
            .rotationEffect(.degrees(angle))
    }
}

/// 다이얼 중심에서 진행 경계까지 뻗는 흰 바늘 (안드로이드 FocusDial과 공통)
private struct DialHand: View {
    let angle: Angle
    let length: CGFloat
    let width: CGFloat

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            Path { p in
                p.move(to: c)
                p.addLine(to: CGPoint(
                    x: c.x + length * cos(angle.radians),
                    y: c.y + length * sin(angle.radians)))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
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
            .animation(TLMotion.press, value: configuration.isPressed)
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

/// 핵심 대주제 6개 태그 + 그룹의 엄선 색상 (다크 배경에서 서로 뚜렷이 구분).
/// 직접 입력 태그만 nil → 회색.
/// '그룹'이 회색이던 시절엔 커스텀 태그와 같은 색이라 도넛에서 조각이 구분되지 않았다 —
/// 그룹은 옛 '작업' 골드를 물려받고, '작업'은 브랜드 라임으로 옮겼다.
/// 비교는 정본 키로만 한다 — 레거시 한글('악기' 포함)은 canonical()이 흡수한다.
func tagTint(_ name: String) -> Color? {
    switch CanonicalTag.canonical(name) {
    case "study":   return Color(hex: 0x5B8DEF)   // 블루
    case "reading": return Color(hex: 0xB07CF0)   // 바이올렛
    case "workout": return Color(hex: 0xFF7A66)   // 코랄
    case "work":    return Color(hex: 0xAFE746)   // 라임 (메인 브랜드 컬러)
    case "group":   return Color(hex: 0xF2A93C)   // 골드 (옛 '작업' 색 승계)
    case "music":   return Color(hex: 0xF473B3)   // 핑크
    case "writing": return Color(hex: 0x35C8AE)   // 틸
    default:        return nil
    }
}

/// 선택(원색 솔리드) 칩 위 글자색 — 밝은 원색(라임 등)은 흰 글씨가 묻히므로 잉크로 반전한다.
/// 상대 휘도 0.6 기준: 라임(0.75)만 잉크, 나머지 프리셋(0.3~0.5)은 기존 흰 글씨 유지.
private func brightTint(_ tint: Color) -> Bool {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(tint).getRed(&r, green: &g, blue: &b, alpha: &a)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.6
}

struct TagChip: View {
    let name: String
    var selected = false
    var body: some View {
        // 프리셋 6개+그룹은 고유 색, 그 외(직접 입력 태그)는 기존 회색 유지.
        // name은 저장값(정본 키 또는 커스텀 원문) — 표시할 때 로케일 문구로 푼다.
        let tint = tagTint(name)
        Text(CanonicalTag.label(name))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(textColor(tint))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(bgColor(tint)))
            .overlay(Capsule().strokeBorder(borderColor(tint), lineWidth: 1))
    }
    private func textColor(_ tint: Color?) -> Color {
        guard let tint else { return selected ? TL.ink : TL.muted }
        return selected ? (brightTint(tint) ? TL.ink : .white) : tint
    }
    private func bgColor(_ tint: Color?) -> Color {
        guard let tint else { return selected ? TL.paper : TL.surface }
        return selected ? tint : tint.opacity(0.16)
    }
    private func borderColor(_ tint: Color?) -> Color {
        guard let tint else { return selected ? .clear : TL.hairline }
        return selected ? .clear : tint.opacity(0.38)
    }
}

// MARK: - 시간 포맷 유틸

enum TLFormat {
    /// 현재 UI 언어가 한국어인가 — ko는 기존 문구·패턴을 바이트 그대로 유지해야 해서(설계도 D4)
    /// 포맷터마다 이 분기를 탄다. 그 외 언어는 OS 로케일 포맷터(템플릿)에 맡긴다.
    static var isKorean: Bool { Locale.current.language.languageCode?.identifier == "ko" }

    /// 일요일부터 7개의 요일 약칭 — 캘린더 헤더 등 (ko: 일 월 … / en: Sun Mon …)
    static var weekdaySymbols: [String] {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        return f.shortStandaloneWeekdaySymbols
    }

    /// 1(일)~7(토) → 요일 약칭. 범위 밖은 빈 문자열 (클라우드 유입값 방어 — 배열 인덱싱 크래시 금지)
    static func weekdaySymbol(_ weekday: Int) -> String {
        guard (1...7).contains(weekday) else { return "" }
        return weekdaySymbols[weekday - 1]
    }

    /// 1(일)~7(토) → 요일 전체 이름 (ko: 일요일 / en: Sunday)
    static func weekdayFullSymbol(_ weekday: Int) -> String {
        guard (1...7).contains(weekday) else { return "" }
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        return f.standaloneWeekdaySymbols[weekday - 1]
    }

    /// "8월 14일" / "Aug 14"
    static func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        if isKorean {
            f.locale = Locale(identifier: "ko_KR")
            f.dateFormat = "M월 d일"
        } else {
            f.locale = .autoupdatingCurrent
            f.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return f.string(from: date)
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        if isKorean {
            f.locale = Locale(identifier: "ko_KR")
            f.dateFormat = "a h:mm"
        } else {
            f.locale = .autoupdatingCurrent
            f.setLocalizedDateFormatFromTemplate("jmm")   // 로케일이 12/24시간·AM/PM 위치 결정
        }
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
        if isKorean {
            if h > 0 && m > 0 { return "\(h)시간 \(m)분" }
            if h > 0 { return "\(h)시간" }
            return "\(m)분"
        }
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
    static func dayTitle(_ date: Date) -> String {
        let f = DateFormatter()
        if isKorean {
            f.locale = Locale(identifier: "ko_KR")
            f.dateFormat = "M월 d일 EEEE"
        } else {
            f.locale = .autoupdatingCurrent
            f.setLocalizedDateFormatFromTemplate("MMMMdEEEE")   // "Thursday, August 14"
        }
        return f.string(from: date)
    }
}

/// 누적 시간 표기 — 숫자는 강조색, 단위는 흐린색의 스타일드 텍스트.
/// '시간 단위 내림'만 쓰면 1시간 미만이 전부 "0시간"으로 뭉개진다 —
/// "N시간 n분"으로 분까지 보여준다 (시간이 0이면 분만, 분이 0이면 시간만).
/// 홈 상단 배지와 기록탭 헤더가 같은 규칙 하나를 쓴다.
func styledHourMinute(seconds: Int, numberFont: Font, unitFont: Font,
                      numberColor: Color = TL.jade, unitColor: Color = TL.muted) -> Text {
    let h = max(0, seconds) / 3600
    let m = (max(0, seconds) % 3600) / 60
    let f = NumberFormatter()
    f.numberStyle = .decimal
    let hLabel = f.string(from: NSNumber(value: h)) ?? "\(h)"

    func part(_ value: String, _ unit: String) -> Text {
        Text(value).font(numberFont).foregroundStyle(numberColor)
        + Text(unit).font(unitFont).foregroundStyle(unitColor)
    }
    let hUnit = TLFormat.isKorean ? "시간" : "h"
    let mUnit = TLFormat.isKorean ? "분" : "m"
    if h > 0 && m > 0 { return part(hLabel, hUnit) + Text(" ") + part("\(m)", mUnit) }
    if h > 0 { return part(hLabel, hUnit) }
    return part("\(m)", mUnit)
}
