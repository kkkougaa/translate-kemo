import SwiftUI
import UIKit

// 화면 소리 번역 페이지 — preview/pip.html 의 '앱 화면' 탭

struct TLScreenPage: View {
    @ObservedObject private var m = TLScreenModel.shared
    @ObservedObject private var pip = TLScreenModel.shared.pip

    private static let sizes: [Double] = [0.88, 1, 1.18]
    private static func sizeLabel(_ v: Double) -> String { v < 0.95 ? "작게" : v > 1.05 ? "크게" : "보통" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                langBar
                heroCard
                Text("자막 창").font(.system(size: 13)).foregroundStyle(Color.tlText2).padding(.horizontal, 4)
                optionsCard
                if !m.lines.isEmpty {
                    HStack {
                        Text("받아 적은 말").font(.system(size: 13)).foregroundStyle(Color.tlText2)
                        Spacer()
                        Button("복사") { copyLog() }.font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 4)
                    logCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
        .background(Color.tlBg.ignoresSafeArea())
        .navigationTitle("화면 소리 번역")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !m.lines.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { Button("지우기") { m.clear() } }
            }
        }
        .tint(.tlAccent)
        .onAppear { m.start() }
    }

    // MARK: 언어

    private var langBar: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(TLScreenModel.langs, id: \.self) { l in
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { m.lang = l }
                    } label: {
                        if l == m.lang { Label(TLLang.cfg(l).label, systemImage: "checkmark") } else { Text(TLLang.cfg(l).label) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(m.langName).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.tlText3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.tlText3)
                .frame(width: 30)
            Text("한국어")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.tlText2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(3)
        .frame(height: 48)
        .liquidGlassCard(cornerRadius: 14)
    }

    // MARK: 시작 · 상태 · PIP

    private var stateText: (String, Bool) {
        if let e = m.error { return (e, true) }
        if m.paused { return ("멈춤", false) }
        if !m.broadcasting { return ("대기 중", false) }
        return (m.live ? "번역 중" : "듣는 중", false)
    }

    private var heroCard: some View {
        VStack(spacing: 14) {
            TLPiPHost(layer: pip.layer)
                .aspectRatio(m.canvas.width / m.canvas.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .animation(.snappy(duration: 0.3), value: m.wide)

            recordButton

            VStack(spacing: 2) {
                let st = stateText
                Text(st.0)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(st.1 ? Color.tlRed : Color.primary)
                    .multilineTextAlignment(.center)
                if let at = m.startedAt {
                    TimelineView(.periodic(from: at, by: 1)) { ctx in
                        Text(elapsed(from: at, to: ctx.date))
                            .font(.system(size: 12.5))
                            .monospacedDigit()
                            .foregroundStyle(Color.tlText2)
                    }
                }
            }

            Button { m.togglePiP() } label: {
                Label(pip.active ? "자막 창 닫기" : "자막 창 띄우기", systemImage: pip.active ? "pip.exit" : "pip.enter")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(pip.active ? Color.primary : Color.tlOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(Capsule())
                    .modifier(TLPipButtonGlass(active: pip.active))
            }
            .buttonStyle(.plain)
            .tapHaptic()
            .opacity(pip.possible || pip.active ? 1 : 0.45)
            .disabled(!pip.possible && !pip.active)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .tlCard()
    }

    /// 제어 센터의 화면 기록 버튼 모양 — 글래스 원 안에 기록 점. 기록 중이면 빨간 글래스에 정지 네모.
    private var recordButton: some View {
        ZStack {
            ZStack {
                if m.broadcasting {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 24, height: 24)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.85), lineWidth: 3)
                        .frame(width: 40, height: 40)
                    Circle()
                        .fill(Color(red: 1, green: 0.23, blue: 0.19))
                        .frame(width: 28, height: 28)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 78, height: 78)
            .liquidGlass(tint: m.broadcasting ? Color(red: 1, green: 0.23, blue: 0.19) : nil)
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            // 실제로 눌리는 건 위에 투명하게 덮은 시스템 버튼
            TLBroadcastPicker()
                .frame(width: 78, height: 78)
                .clipShape(Circle())
        }
        .animation(.spring(duration: 0.35, bounce: 0.25), value: m.broadcasting)
        .accessibilityLabel(m.broadcasting ? "화면 기록 멈추기" : "화면 기록 시작")
    }

    private func elapsed(from a: Date, to b: Date) -> String {
        let s = max(0, Int(b.timeIntervalSince(a)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: 설정

    private var optionsCard: some View {
        VStack(spacing: 0) {
            Toggle("원문 같이 보기", isOn: $m.showSrc)
                .font(.system(size: 16))
                .tint(.tlAccent)
                .changeHaptic(m.showSrc)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
            Divider().padding(.leading, 16)
            HStack {
                Text("모양").font(.system(size: 16))
                Spacer()
                Picker("모양", selection: $m.wide) {
                    Text("기본").tag(false)
                    Text("가로로 길게").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            Divider().padding(.leading, 16)
            HStack {
                Text("이전 대화").font(.system(size: 16))
                Spacer()
                Picker("이전 대화", selection: $m.history) {
                    ForEach([0, 1, 2, 3, 5], id: \.self) { n in Text(n == 0 ? "없음" : "\(n)").tag(n) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            Divider().padding(.leading, 16)
            HStack {
                Text("글꼴").font(.system(size: 16))
                Spacer()
                Picker("글꼴", selection: $m.captionFont) {
                    Text("기본").tag("default")
                    Text("둥근").tag("rounded")
                    Text("명조").tag("serif")
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            Divider().padding(.leading, 16)
            HStack {
                Text("띠 색").font(.system(size: 16))
                Spacer()
                HStack(spacing: 9) {
                    ForEach(TLCaptionView.barChoices, id: \.id) { c in
                        Button { m.captionBar = c.id; TLHaptic.select() } label: {
                            Circle()
                                .fill(c.color)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(Color.primary.opacity(m.captionBar == c.id ? 0.85 : 0), lineWidth: 2).padding(-3.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            Divider().padding(.leading, 16)
            HStack {
                Text("줄 간격").font(.system(size: 16))
                Spacer()
                Picker("줄 간격", selection: $m.captionSpacing) {
                    Text("좁게").tag(0.75)
                    Text("보통").tag(1.0)
                    Text("넓게").tag(1.35)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            Divider().padding(.leading, 16)
            HStack {
                Text("글자 크기").font(.system(size: 16))
                Spacer()
                Picker("글자 크기", selection: $m.fontScale) {
                    ForEach(Self.sizes, id: \.self) { Text(Self.sizeLabel($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
        }
        .tlCard()
    }

    // MARK: 기록

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(m.lines.suffix(40)) { l in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(TLSpeaker.color(l.who)).frame(width: 7, height: 7).padding(.top, l.src.isEmpty ? 6 : 5)
                    VStack(alignment: .leading, spacing: 1) {
                        if !l.src.isEmpty {
                            Text(l.src).font(.system(size: 12)).foregroundStyle(Color.tlText3)
                        }
                        Text(l.dst.isEmpty ? "…" : l.dst).font(.system(size: 14))
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .tlCard()
    }

    private func copyLog() {
        UIPasteboard.general.string = m.lines.map { l in [l.src, l.dst].filter { !$0.isEmpty }.joined(separator: "\n") }
            .joined(separator: "\n\n")
        TLHaptic.copy()
    }
}

/// 자막 창 띄우기 — 강조색 글래스, 띄워져 있으면 맑은 글래스
private struct TLPipButtonGlass: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.liquidGlass() } else { content.tlAccentGlass() }
    }
}
