import SwiftUI
import UIKit

// 공유 시트 → "translate-kemo". 앱을 열지 않고 호스트 앱 위에 작은 카드로 번역을 띄운다.
// 번역 규칙(프롬프트·뒷정리·용어집)은 본 앱과 같은 TLPrompt · TLText 를 그대로 쓴다.

extension Color {
    /// 번역기 액센트 — 본 앱 Color.tlAccent 와 같은 값
    static let taAccent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x3E / 255, green: 0xCB / 255, blue: 0xA8 / 255, alpha: 1)
        : UIColor(red: 0x0E / 255, green: 0x8A / 255, blue: 0x6F / 255, alpha: 1) })
    static let taAccentDark = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x6F / 255, green: 0xE0 / 255, blue: 0xC4 / 255, alpha: 1)
        : UIColor(red: 0x0B / 255, green: 0x6E / 255, blue: 0x58 / 255, alpha: 1) })
    static let taRed = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1, green: 0x7A / 255, blue: 0x5C / 255, alpha: 1)
        : UIColor(red: 0xC1 / 255, green: 0x45 / 255, blue: 0x2A / 255, alpha: 1) })
    static let taFill = Color(UIColor.tertiarySystemFill)
    static let taText2 = Color(UIColor.secondaryLabel)
    static let taText3 = Color(UIColor.tertiaryLabel)
    static let taCard = Color(UIColor.systemBackground)
}

// MARK: 모델

@MainActor
final class TLActionModel: ObservableObject {
    @Published private(set) var source = ""
    @Published private(set) var srcLang = "ko"
    @Published private(set) var tgtLang = "ja"
    @Published private(set) var result = ""
    @Published private(set) var comment = ""
    @Published private(set) var error = ""
    @Published private(set) var busy = false
    @Published private(set) var streaming = false
    @Published private(set) var done = false
    @Published private(set) var empty = false
    @Published private(set) var needKey = false
    @Published var keyInput = ""
    @Published var toast: String?

    private var settings = TLActionStore.load()
    private var task: Task<Void, Never>?
    private var seq = 0

    var toKO: Bool { srcLang != "ko" }
    var outLang: String { toKO ? "ko" : tgtLang }
    var srcName: String { srcLang == "ko" ? "한국어" : TLLang.cfg(srcLang).label }
    var tgtName: String { toKO ? "한국어" : TLLang.cfg(tgtLang).label }

    func setText(_ t: String) {
        source = String(t.trimmed.prefix(4000))
        empty = source.isEmpty
        guard !empty else { return }
        detect()
        translate()
    }

    func setEmpty() { empty = true }

    /// 본 앱의 자동 감지와 같다. 한국어면 마지막에 고른 언어로, 외국어면 한국어로.
    private func detect() {
        switch TLText.detectInputLang(source) {
        case "ja": srcLang = "ja"; tgtLang = "ja"
        case "en": srcLang = "en"; tgtLang = "en"
        case "foreign": srcLang = settings.lastTgt; tgtLang = settings.lastTgt
        default: srcLang = "ko"; tgtLang = settings.lastTgt
        }
    }

    func pickTarget(_ l: String) {
        guard !toKO, l != tgtLang else { return }
        tgtLang = l
        translate()
    }

    func saveKey() {
        let k = keyInput.trimmed
        guard !k.isEmpty else { return }
        TLActionStore.saveOwnKey(k)
        settings.apiKey = k
        keyInput = ""
        translate()
    }

    func translate() {
        task?.cancel()
        seq += 1
        let my = seq
        let text = source.trimmed
        guard !text.isEmpty else { return }
        guard settings.hasKey else { needKey = true; return }
        needKey = false
        busy = true; streaming = false; done = false
        result = ""; comment = ""; error = ""

        let s = settings
        let sLang = srcLang, tLang = tgtLang, outL = outLang, toKO = self.toKO
        let glossary = Glossary.parse(s.glossary[tLang] ?? "")
        let ctx = TLPrompt.Context(srcLang: sLang, tgtLang: tLang, tone: "none", strict: true,
                                   extraOn: false, extraText: "", charPrompt: s.charPrompt,
                                   tones: TLPrompt.defaultTones, glossary: glossary, bannedRaw: s.banned[tLang] ?? "")
        let prompt = TLPrompt.build(text, ctx)
        let parsed = TLText.parseInput(text)
        var gen: [String: Any] = ["temperature": 0.3, "maxOutputTokens": 2048]
        if !s.thinking { gen["thinkingConfig"] = ["thinkingBudget": 0] }
        let body: [String: Any] = ["contents": [["parts": [["text": prompt]]]], "generationConfig": gen]
        let timeout: TimeInterval = s.thinking ? 90 : 25
        let model = s.effectiveModel, key = s.apiKey.trimmed

        let draw: @MainActor (String) -> Void = { [weak self] full in
            guard let self, my == self.seq else { return }
            self.streaming = true
            self.result = TLText.splitComment(full).body.trimmedStart
        }

        task = Task { [weak self] in
            do {
                let full = try await Gemini.withRetry {
                    try await Gemini.streamOnce(model: model, key: key, body: body, timeout: timeout, onText: draw)
                }
                guard let self, my == self.seq else { return }
                // 본문만 다듬는다 — 읽는 법 꼬리 떼기, 전각 숫자·영문 반각, 용어집 강제. 코멘트는 그대로.
                var cs = full.trimmed.components(separatedBy: TLText.commentSep)
                cs[0] = Glossary.enforce(TLText.tidyOut(cs[0], tgtLang: outL), srcText: parsed.body,
                                         outLang: outL, pairs: glossary, toKO: toKO)
                let split = TLText.splitComment(cs.joined(separator: TLText.commentSep))
                let clean = TLText.cleanForCopy(split.body)
                if clean.isEmpty { throw GeminiError(message: "번역 결과를 받지 못했습니다.") }
                self.result = clean
                self.comment = (split.comment ?? "").trimmed
                self.busy = false
                self.streaming = false
                self.done = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch is CancellationError {
            } catch {
                guard let self, my == self.seq else { return }
                self.busy = false
                self.streaming = false
                self.error = "오류: " + error.localizedDescription
                // 키가 틀렸으면 바로 다시 넣을 수 있게 칸을 연다
                if error.localizedDescription.contains("API 키") { self.needKey = true }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    func copy(both: Bool) {
        guard !result.isEmpty else { return }
        UIPasteboard.general.string = both ? source + "\n\n" + result : result
        Haptics.light()
        show("복사했어요")
    }

    func show(_ msg: String) {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { toast = msg }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeOut(duration: 0.25)) { if self?.toast == msg { self?.toast = nil } }
        }
    }

    func cancel() { task?.cancel(); seq += 1 }
}

// MARK: 카드

struct TLActionView: View {
    @ObservedObject var m: TLActionModel
    let onClose: () -> Void
    let onReplace: (String) -> Void
    /// 기본 번역 앱(시스템 시트) 안에 들어갈 때 — 막·바깥 그림자 없이 카드 내용만
    var embedded = false
    /// 원문 자리에 바꿔 넣을 수 있나 (시스템 시트가 알려 준다)
    var canReplace = true
    @State private var shown = false
    @State private var srcOpen = false

    var body: some View {
        if embedded {
            ScrollView { cardContent.padding(18) }
                .onAppear { shown = true }
        } else {
            overlayBody
        }
    }

    private var overlayBody: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(shown ? 0.28 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
            if shown {
                card
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.4, bounce: 0.14)) { shown = true } }
    }

    private func close() {
        m.cancel()
        if embedded { onClose(); return }
        withAnimation(.easeIn(duration: 0.18)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onClose() }
    }

    private var card: some View {
        cardContent
            .padding(18)
            .background(Color.taCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 6)
            .overlay(alignment: .top) { toastView }
    }

    @ViewBuilder
    private var toastView: some View {
        if let t = m.toast {
            Text(t)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .liquidGlass()
                .offset(y: -44)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if m.empty {
                Text("번역할 글이 없어요")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.taText2)
                    .padding(.vertical, 8)
            } else {
                langPill
                sourceText
                Divider()
                resultArea
                if !m.comment.isEmpty { commentBox }
                if !m.error.isEmpty {
                    Text(m.error)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.taRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if m.needKey { keyField }
                footer
                if embedded, let t = m.toast {
                    Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.taText2)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image("logo")
                .resizable()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("translate-kemo")
                .font(.system(size: 16, weight: .bold))
                .tracking(-0.4)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .liquidGlass()
            }
            .buttonStyle(.plain)
            .tapHaptic()
            .accessibilityLabel("닫기")
        }
    }

    private var langPill: some View {
        HStack(spacing: 8) {
            Text(m.srcName).foregroundStyle(Color.taText2)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.taText3)
            if m.toKO {
                Text(m.tgtName)
            } else {
                Menu {
                    ForEach(TLLang.order, id: \.self) { l in
                        Button {
                            m.pickTarget(l)
                        } label: {
                            if l == m.tgtLang { Label(TLLang.cfg(l).label, systemImage: "checkmark") }
                            else { Text(TLLang.cfg(l).label) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(m.tgtName).foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.taText3)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 14)
        .frame(height: 34)
        .liquidGlass()
    }

    private var sourceText: some View {
        Text(m.source)
            .font(.system(size: 14))
            .foregroundStyle(Color.taText2)
            .lineLimit(srcOpen ? nil : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.22)) { srcOpen.toggle() } }
    }

    @ViewBuilder
    private var resultArea: some View {
        if m.busy && !m.streaming {
            TADots().padding(.vertical, 6)
        } else if !m.result.isEmpty {
            ScrollView {
                Text(m.result)
                    .font(.system(size: 17))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var commentBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("번역 코멘트").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.taAccentDark)
            Text(m.comment).font(.system(size: 13)).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(Color.taAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var keyField: some View {
        HStack(spacing: 8) {
            SecureField("Gemini API 키", text: $m.keyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15, design: .monospaced))
                .submitLabel(.done)
                .onSubmit { m.saveKey() }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(Color.taFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button { m.saveKey() } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.taAccent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(m.keyInput.trimmed.isEmpty)
            .opacity(m.keyInput.trimmed.isEmpty ? 0.5 : 1)
        }
    }

    private var footer: some View {
        let off = m.result.isEmpty || m.busy
        return HStack(spacing: 8) {
            GlassPillButton(title: "복사") { m.copy(both: false) }
            GlassPillButton(title: "원문+번역") { m.copy(both: true) }
            if canReplace {
                GlassPillButton(title: "바꿔 넣기", tint: .taAccent, prominent: true) {
                    Haptics.light()
                    let t = m.result
                    if embedded { onReplace(t); return }
                    withAnimation(.easeIn(duration: 0.18)) { shown = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onReplace(t) }
                }
            }
        }
        .disabled(off)
        .opacity(off ? 0.5 : 1)
    }
}

/// 통통 튀는 점 셋 (본 앱 TLLoadingDots 와 같은 모양)
struct TADots: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.taAccent)
                    .frame(width: 7, height: 7)
                    .offset(y: on ? -4 : 2)
                    .opacity(on ? 1 : 0.45)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.15), value: on)
            }
        }
        .frame(height: 17)
        .onAppear { on = true }
    }
}
