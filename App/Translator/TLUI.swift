import SwiftUI
import UIKit

// 번역기 화면 공용 조각

/// 칩을 가로로 늘어놓다가 넘치면 다음 줄로
struct TLFlow: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat? = nil

    private func size(_ s: LayoutSubview, _ maxW: CGFloat) -> CGSize {
        s.sizeThatFits(ProposedViewSize(width: maxW.isFinite ? maxW : nil, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        let ls = lineSpacing ?? spacing
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, w: CGFloat = 0
        for s in subviews {
            let sz = size(s, maxW)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + ls; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            w = max(w, x - spacing)
        }
        return CGSize(width: maxW.isFinite ? maxW : w, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ls = lineSpacing ?? spacing
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = size(s, bounds.width)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + ls; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

extension View {
    /// 아래 탭 바가 글래스라 내용이 비쳐 흐려진다. 화면 아래 10% 에 색을 살짝 깔아 바를 또렷하게.
    /// 색은 설정 → 색 → 하단 바 (기본: 번역기 아이콘의 붉은 색)
    func tlBottomFade() -> some View {
        overlay(alignment: .bottom) { TLBottomFade() }
    }

    /// HTML 판의 흰 카드 (다크에선 #1C1C1E)
    func tlCard(_ radius: CGFloat = 14) -> some View {
        background(Color.tlCard, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// 강조색 글래스. iOS 26 이전엔 글래스가 색을 못 받아 흰 글씨가 묻히니 단색으로 칠한다.
    @ViewBuilder
    func tlAccentGlass(cornerRadius: CGFloat? = nil, color: Color = .tlAccent, clear: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if let r = cornerRadius {
                self.glassEffect((clear ? Glass.clear : Glass.regular).tint(color).interactive(),
                                 in: RoundedRectangle(cornerRadius: r, style: .continuous))
            } else {
                self.glassEffect((clear ? Glass.clear : Glass.regular).tint(color).interactive(), in: Capsule())
            }
        } else {
            tlAccentSolid(cornerRadius, color)
        }
        #else
        tlAccentSolid(cornerRadius, color)
        #endif
    }

    @ViewBuilder
    private func tlAccentSolid(_ r: CGFloat?, _ color: Color) -> some View {
        if let r { self.background(color, in: RoundedRectangle(cornerRadius: r, style: .continuous)) }
        else { self.background(color, in: Capsule()) }
    }
}

/// 헤더·언어바의 둥근 글래스 버튼
struct TLCircleButton: View {
    let symbol: String
    var size: CGFloat = 40
    var label: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .liquidGlass()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tapHaptic()
        .accessibilityLabel(label)
    }
}

/// 통통 튀는 점 셋
struct TLLoadingDots: View {
    var size: CGFloat = 7
    @State private var on = false

    var body: some View {
        HStack(spacing: size * 0.7) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.tlAccent)
                    .frame(width: size, height: size)
                    .offset(y: on ? -size * 0.6 : size * 0.3)
                    .opacity(on ? 1 : 0.45)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.15), value: on)
            }
        }
        .frame(height: size * 2.4)
        .onAppear { on = true }
    }
}

/// 회색 바탕 작은 버튼 (복사 · 원문+번역 · 칩)
struct TLFillButton: View {
    let title: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Color.tlOnAccent : Color.primary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(active ? Color.tlAccent : Color.tlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .tapHaptic()
    }
}

extension Color {
    static let tlText2 = Color(UIColor.secondaryLabel)
    static let tlText3 = Color(UIColor.tertiaryLabel)
    static let tlWarn = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0xE0 / 255, green: 0xA4 / 255, blue: 0x6A / 255, alpha: 1)
        : UIColor(red: 0xA6 / 255, green: 0x55 / 255, blue: 0x1A / 255, alpha: 1) })
}

/// 결과 글자 크기 (설정 → 결과 글자 크기)
enum TLResultSize: String, CaseIterable, Identifiable {
    case sm, md, lg
    var id: String { rawValue }
    var label: String { self == .sm ? "작게" : self == .md ? "보통" : "크게" }
    var points: CGFloat { self == .sm ? 15 : self == .md ? 17 : 20 }
}

// MARK: 색 설정

extension Color {
    /// "#RRGGBB" → 색. 못 읽으면 nil
    init?(tlHex: String) {
        var h = tlHex.trimmed
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// 설정에서 고르는 색 목록
enum TLPalette {
    /// 하단 바 깔개 — 첫 번째가 기본(번역기 아이콘의 붉은 색)
    static let bar = ["#BC2448", "#E8789A", "#F08A24", "#3182F6", "#0E8A6F", "#7C5CE6", "#191F28"]
    /// 번역 버튼 — 빈 값은 강조색(초록)
    static let button = ["", "#BC2448", "#E8789A", "#F08A24", "#3182F6", "#7C5CE6", "#191F28"]
    /// 하단 바 아이콘 — 첫 번째가 기본(흰색)
    static let icon = ["#FFFFFF", "#191F28", "#F2B84B", "#BC2448", "#3182F6", "#0E8A6F"]
    /// 쓰기(연필) 버튼 — 첫 번째가 기본(번역기 아이콘의 노란색)
    static let write = ["#F2B84B", "#BC2448", "#E8789A", "#3182F6", "#0E8A6F", "#7C5CE6", "#191F28"]

    /// 글래스에 칠할 색 — 색마다 정한 진하기만큼 투명도를 준다
    @MainActor static var buttonColor: Color {
        (Color(tlHex: TLStore.shared.buttonTint) ?? .tlAccent).opacity(TLStore.shared.buttonStrength)
    }
    @MainActor static var writeColor: Color {
        (Color(tlHex: TLStore.shared.writeTint) ?? Color(tlHex: TLStore.defaultWriteTint)!).opacity(TLStore.shared.writeStrength)
    }
    @MainActor static var barGlassColor: Color { barColor.opacity(TLStore.shared.barStrength) }
    @MainActor static var barColor: Color { Color(tlHex: TLStore.shared.barTint) ?? Color(tlHex: TLStore.defaultBarTint)! }

    /// 버튼 위 글자 색. 색이 연하게 깔리면 바탕이 비쳐 보이니 그만큼 섞어서 밝기를 본다.
    /// hex 가 비면 강조색(라이트 #0E8A6F · 다크 #3ECBA8).
    static func ink(on hex: String, strength: Double = 1, dark: Bool = false) -> Color {
        let h = hex.isEmpty ? (dark ? "#3ECBA8" : "#0E8A6F") : hex
        guard let c = Color(tlHex: h), let comps = UIColor(c).cgColor.components, comps.count >= 3 else { return .white }
        let lum = 0.299 * comps[0] + 0.587 * comps[1] + 0.114 * comps[2]
        let behind: CGFloat = dark ? 0.12 : 0.97
        let mixed = lum * CGFloat(strength) + behind * CGFloat(1 - strength)
        return mixed > 0.62 ? Color(red: 0x19 / 255, green: 0x1F / 255, blue: 0x28 / 255) : .white
    }
}

/// 화면 아래 10% 에 까는 색 그라데이션
struct TLBottomFade: View {
    @ObservedObject private var store = TLStore.shared

    var body: some View {
        LinearGradient(colors: [TLPalette.barColor.opacity(0), TLPalette.barColor.opacity(0.3 * TLStore.shared.barStrength)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: UIScreen.main.bounds.height * 0.1)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
    }
}

/// 색 동그라미 줄 (설정)
struct TLSwatchRow: View {
    let colors: [String]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(colors, id: \.self) { hex in
                let on = selection == hex
                Button { selection = hex; TLHaptic.select() } label: {
                    Circle()
                        .fill(Color(tlHex: hex) ?? Color.tlAccent)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.primary.opacity(on ? 0.85 : 0), lineWidth: 2).padding(-3.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hex.isEmpty ? "기본" : hex)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 진하기 슬라이더 — 10% 단위로 끊겨 움직이고, 한 칸마다 톡
struct TLStrengthSlider: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.dotted").foregroundStyle(Color.tlText3)
            Slider(value: $value, in: 0.1...1, step: 0.1)
            Image(systemName: "circle.fill").foregroundStyle(Color.tlText2)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(Color.tlText2)
                .frame(width: 44, alignment: .trailing)
        }
        .sensoryFeedback(.selection, trigger: Int((value * 10).rounded()))
    }
}
