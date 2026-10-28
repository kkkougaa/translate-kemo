import SwiftUI
import UIKit

// 대화 모드 — 실시간 전사·번역. translator.html 의 rt* 를 옮겼다.
// Soniox 한 스트림에서 원문과 번역이 같이 온다(two_way). 마이크는 켜 두고, 조용하면 연결만 끊는다 —
// 요금은 연결 시간으로 매겨지기 때문이다. 문장이 끝나면 Gemini 로 다시 옮겨 갈아끼운다.

struct TLTalkTurn: Identifiable, Equatable {
    let id = UUID()
    var who: String          // me · them · p1, p2 …
    var src = ""
    var dst = ""
    var done = false
    var refined = false
}

@MainActor
final class TLTalkModel: ObservableObject {
    /// 이만큼 조용하면 연결을 닫는다. 자주 끊으면 문맥과 화자 번호가 초기화된다
    static let quietSeconds: TimeInterval = 30
    /// 이 세기를 넘으면 말이 시작된 걸로 본다
    static let wake: Float = 0.045
    /// 화자마다 다른 점 색. 초록(나)과 안 겹치게 골랐다
    static let hues: [UInt32] = [0x4A7FC1, 0x8E63C8, 0xC25E93, 0xB8862F, 0x6B7B9E, 0x3A8FA8]

    @Published var turns: [TLTalkTurn] = []
    @Published var pSrc = ""
    @Published var pDst = ""
    @Published var mic = false
    @Published var live = false
    @Published var level: Float = 0
    /// 화자 번호 → 직접 붙인 이름. 이 대화에서만 쓴다(다시 연결하면 번호가 바뀐다)
    @Published var names: [String: String] = [:]
    @Published var say: String?
    @Published var refine: Bool { didSet { UserDefaults.standard.set(refine ? "1" : "0", forKey: "tl.rt_refine") } }

    // 타자로 입력하고 번역을 미리 보는 칸
    @Published var composeOpen = false
    @Published var typed = "" { didSet { if typed != oldValue { typeChanged() } } }
    @Published var prevDst = ""
    @Published var prevYomi = ""
    @Published var prevWaiting = false

    var otherLang = "ja"
    var otherName: String { TLLang.cfg(otherLang).label }

    private let store = TLStore.shared
    private let micIn = TLMic()
    private let pump = TLAudioPump()
    private var conn: TLSonioxConn?
    private var curID: UUID?
    /// 문장이 끝난 뒤 늦게 오는 번역 토큰이 새 말풍선을 만들지 않게 잡아 둔다
    private var justEndedID: UUID?
    private var quietAt = Date()
    private var typeTask: Task<Void, Never>?
    private var typeSeq = 0
    private var lastAsked = ""
    private var sayTask: Task<Void, Never>?

    init() {
        refine = UserDefaults.standard.string(forKey: "tl.rt_refine") != "0"
    }

    var previewVisible: Bool { typed.trimmed.count >= 2 }
    var yomiWanted: Bool { ["ja", "zh-cn", "zh-tw"].contains(otherLang) }

    func reset() {
        turns = []; curID = nil; justEndedID = nil; pSrc = ""; pDst = ""
        composeOpen = false; typed = ""; prevDst = ""; prevYomi = ""; lastAsked = ""
    }

    // MARK: 화자

    static func letter(_ n: String) -> String {
        guard let i = Int(n), i > 0, let u = Unicode.Scalar(64 + ((i - 1) % 26) + 1) else { return "" }
        return String(Character(u))
    }

    static func hue(_ n: String) -> Color {
        let i = max((Int(n) ?? 1) - 1, 0)
        let v = hues[i % hues.count]
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    func whoName(_ who: String) -> String {
        let n = who.hasPrefix("p") ? String(who.dropFirst()) : who
        let named = (names[n] ?? "").trimmed
        return named.isEmpty ? Self.letter(n) : named
    }

    var seenSpeakers: [String] {
        var seen: [String] = []
        for t in turns where t.who != "me" && t.who.hasPrefix("p") {
            let n = String(t.who.dropFirst())
            if !seen.contains(n) { seen.append(n) }
        }
        return seen.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }

    // MARK: 결과 → 말풍선

    private func idx(_ id: UUID?) -> Int? {
        guard let id else { return nil }
        return turns.firstIndex { $0.id == id }
    }

    private func endTurn() {
        guard let k = idx(curID) else { curID = nil; return }
        turns[k].done = true
        let id = turns[k].id
        curID = nil
        justEndedID = id
        // 늦은 번역 토큰이 먼저 붙게 조금 기다렸다 다시 옮긴다
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            self.refineTurn(id)
        }
    }

    private func ensure(_ who: String) {
        if let k = idx(curID), turns[k].who == who { return }
        endTurn()
        let t = TLTalkTurn(who: who)
        turns.append(t)
        curID = t.id
        if turns.count > 60 { turns.removeFirst() }
    }

    private func whoOf(_ t: TLSoniox.Token) -> String {
        if t.language == "ko" { return "me" }
        if let s = t.speaker, !s.isEmpty { return "p" + s }
        return "them"
    }

    func take(_ tokens: [TLSoniox.Token]) {
        var ps = "", pd = ""
        for t in tokens {
            if t.text == "<end>" { endTurn(); continue }
            if t.isFinal {
                if !t.isTranslation {
                    ensure(whoOf(t))
                    if let k = idx(curID) { turns[k].src += t.text }
                    continue
                }
                // 번역 토큰이 <end> 뒤에 오면 새 칸을 만들지 말고 방금 끝난 칸에 붙인다
                if let k = idx(curID) { turns[k].dst += t.text }
                else if let k = idx(justEndedID), !turns[k].refined { turns[k].dst += t.text }
                else { ensure("them"); if let k = idx(curID) { turns[k].dst += t.text } }
            } else {
                if t.isTranslation { pd += t.text } else { ps += t.text }
            }
        }
        pSrc = ps; pDst = pd
    }

    /// 용어집을 이 방향에 맞춰 넣는다
    private func glossary(_ text: String, toKo: Bool) -> String {
        let t = text.lowercased()
        let hits = store.glossary(otherLang).filter { t.contains((toKo ? $0.to : $0.from).lowercased()) }
        if hits.isEmpty { return "" }
        return "\n\n[용어집] 아래 단어는 반드시 지정한 번역을 쓰세요.\n"
            + hits.map { toKo ? "- \($0.to) → \($0.from)" : "- \($0.from) → \($0.to)" }.joined(separator: "\n")
    }

    /// Soniox 번역은 즉시 뜨는 초안이다. 문장이 끝나면 Gemini 로 다시 옮겨 갈아끼운다.
    private func refineTurn(_ id: UUID) {
        guard refine, store.hasKey, let k = idx(id), !turns[k].refined else { return }
        let body = turns[k].src.trimmed
        if body.count < 2 { return }
        turns[k].refined = true
        let toKo = turns[k].who != "me"
        let srcName = toKo ? otherName : "한국어"
        let tgtName = toKo ? "한국어" : otherName
        let prompt = """
        당신은 \(srcName)를 \(tgtName)로 옮기는 전문 통역사입니다.
        말하는 사람의 말투와 감정을 그대로 살리되, \(tgtName)로 자연스럽게 옮기세요.
        직역하지 마세요. 실제로 쓰는 말로 바꾸세요.
        번역문 한 줄만 출력하세요. 설명, 주석, 읽는 법 표기는 절대 붙이지 마세요.
        """ + glossary(body, toKo: toKo) + "\n\n[원문]\n" + body
        let lang = toKo ? "ko" : otherLang
        let model = store.effectiveModel, key = store.apiKey.trimmed
        Task {
            // 실패하면 Soniox 번역을 그대로 쓴다
            guard let out = try? await Gemini.ask(model: model, key: key, prompt: prompt, maxTokens: 400) else { return }
            let clean = TLText.tidyOut(out.trimmed, tgtLang: lang)
            if !clean.isEmpty, let k = self.idx(id) { self.turns[k].dst = clean }
        }
    }

    // MARK: 마이크 · 연결

    func toggleMic() { if mic { stopMic() } else { startMic() } }

    func startMic() {
        guard !mic else { return }
        guard !store.sonioxKey.trimmed.isEmpty else { show("Soniox API 키가 필요해요"); return }
        Task {
            guard await TLMic.permission() else { self.show("마이크를 못 열었어."); return }
            guard !self.mic else { return }
            let pump = self.pump
            self.micIn.onChunk = { d in pump.push(d) }
            self.micIn.onLevel = { [weak self] p in
                Task { @MainActor in self?.heard(p) }
            }
            do { try self.micIn.start() } catch { self.show("마이크를 못 열었어."); return }
            self.mic = true
            self.quietAt = Date()
            self.connect()
        }
    }

    func stopMic() {
        disconnect()
        mic = false
        micIn.stop()
        pump.reset()
        level = 0
        endTurn()
        pSrc = ""; pDst = ""
    }

    private func heard(_ p: Float) {
        guard mic else { return }
        level = p
        if p > Self.wake {
            quietAt = Date()
            if conn == nil { connect() }                 // 말이 시작되면 다시 붙는다
        } else if conn != nil && Date().timeIntervalSince(quietAt) > Self.quietSeconds {
            disconnect()                                 // 조용하면 연결만 닫는다
        }
    }

    private func connect() {
        guard conn == nil, mic else { return }
        let key = store.sonioxKey.trimmed
        guard !key.isEmpty else { return }
        let a = "ko", b = otherLang
        var cfg: [String: Any] = [
            "model": TLSoniox.model,
            "language_hints": [a, b],
            "translation": ["type": "two_way", "language_a": a, "language_b": b],
            "enable_speaker_diarization": true,
            "enable_language_identification": true,
            "enable_endpoint_detection": true
        ]
        if let ctx = TLSoniox.context(store.glossary(otherLang), withTranslation: true) { cfg["context"] = ctx }
        let c = TLSonioxConn(key: key, config: cfg)
        c.onTokens = { [weak self] toks in self?.take(toks) }
        c.onFinished = { [weak self, weak c] in
            guard let self, self.conn === c else { return }
            self.conn = nil
            self.live = false
            self.pump.attach(nil)
        }
        c.onError = { [weak self, weak c] code, msg in
            guard let self, self.conn === c else { return }
            self.conn = nil
            self.live = false
            self.stopMic()
            self.show(TLSoniox.errorText(code, msg))
        }
        conn = c
        live = true
        quietAt = Date()
        c.start()
        pump.attach(c)
    }

    private func disconnect() {
        guard let c = conn else { return }
        conn = nil
        live = false
        pump.attach(nil)
        c.stop()
    }

    // MARK: 타자 입력

    private func typeChanged() {
        typeTask?.cancel()
        let t = typed.trimmed
        if t.count < 2 { lastAsked = ""; prevDst = ""; prevYomi = ""; prevWaiting = false; return }
        if t != lastAsked { prevDst = "옮기는 중"; prevWaiting = true; prevYomi = "" }
        // 타자를 멈추고 잠깐 뒤에 한 번만 부른다
        typeTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self.typeTranslate()
        }
    }

    private func typeTranslate() {
        let t = typed.trimmed
        guard t.count >= 2, t != lastAsked else { return }
        guard store.hasKey else { prevDst = "Gemini 키가 없어"; prevWaiting = false; return }
        lastAsked = t
        typeSeq += 1
        let my = typeSeq
        let yomi = yomiWanted
        let prompt = "다음 한국어를 \(otherName)로 번역해줘.\n번역문만 먼저 쓰고, 줄을 바꿔 --- 한 줄을 적어줘.\n"
            + (yomi ? "그 아래에는 번역문을 한글로 읽는 소리를 적어줘.\n" : "--- 아래는 비워 둬.\n")
            + "설명은 쓰지 마.\n\n[원문]\n" + t
        let model = store.effectiveModel, key = store.apiKey.trimmed
        Task {
            do {
                let out = try await Gemini.ask(model: model, key: key, prompt: prompt, maxTokens: 400)
                guard my == self.typeSeq else { return }      // 그새 더 쳤으면 버린다
                if let r = out.range(of: "---") {
                    self.prevDst = String(out[..<r.lowerBound]).trimmed
                    self.prevYomi = yomi ? String(out[r.upperBound...]).trimmed : ""
                } else {
                    self.prevDst = out.trimmed
                    self.prevYomi = ""
                }
                self.prevWaiting = false
            } catch {
                guard my == self.typeSeq else { return }
                self.prevDst = "번역을 못 가져왔어"
                self.prevWaiting = false
                self.lastAsked = ""
            }
        }
    }

    var canSend: Bool { !prevWaiting && !prevDst.isEmpty && previewVisible && lastAsked == typed.trimmed }

    func sendTyped() {
        let src = typed.trimmed
        guard canSend else { return }
        endTurn()
        turns.append(TLTalkTurn(who: "me", src: src, dst: prevDst, done: true, refined: true))
        curID = nil
        lastAsked = ""
        typed = ""
        Haptics.light()
    }

    func clearTyped() {
        typed = ""
        lastAsked = ""
    }

    // MARK: 알림

    func show(_ s: String) {
        sayTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { say = s }
        sayTask = Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.say = nil }
        }
    }
}

// MARK: 화면

struct TLTalkPage: View {
    /// 상대 언어. 메인 화면에서 넘겨 주면 그 언어로 듣는다.
    var otherLang: String = "ja"
    @StateObject private var m = TLTalkModel()
    @State private var showSet = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            flow
            if m.composeOpen { compose.transition(.move(edge: .bottom).combined(with: .opacity)) }
            foot
        }
        .background(Color.tlBg.ignoresSafeArea())
        .navigationTitle("대화")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSet = true } label: { Image(systemName: "person.2") }
                    .accessibilityLabel("대화 설정")
            }
        }
        .sheet(isPresented: $showSet) { TLTalkSettings(m: m) }
        .onAppear {
            m.otherLang = otherLang
            m.reset()
        }
        .onDisappear { m.stopMic() }
        .animation(.snappy(duration: 0.25), value: m.composeOpen)
    }

    // MARK: 흐름

    private var flow: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    if m.turns.isEmpty && m.pSrc.isEmpty {
                        Text(m.mic ? "말하면 여기에 쌓여요" : "")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.tlText3)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 200)
                    }
                    let shown = Array(m.turns.suffix(30))
                    let many = Set(m.turns.map(\.who).filter { $0 != "me" }).count > 1
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                        bubble(t, last: i == shown.count - 1,
                               showTag: tagFor(t, prev: i > 0 ? shown[i - 1].who : nil, many: many))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: m.turns) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: m.pSrc) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// 상대가 둘 이상 나왔을 때만 이름표를 단다. 이름을 붙여 뒀으면 한 명뿐이어도 보여 준다.
    private func tagFor(_ t: TLTalkTurn, prev: String?, many: Bool) -> Bool {
        guard t.who != "me", t.who.hasPrefix("p"), prev != t.who else { return false }
        let named = !(m.names[String(t.who.dropFirst())] ?? "").trimmed.isEmpty
        return many || named
    }

    private func bubble(_ t: TLTalkTurn, last: Bool, showTag: Bool) -> some View {
        let me = t.who == "me"
        let dstColor: Color = me ? .tlAccentDark : .primary
        let pd = last ? m.pDst : ""
        let ps = last ? m.pSrc : ""
        let dstText: Text = (t.dst.isEmpty && pd.isEmpty)
            ? Text("…").foregroundColor(dstColor)
            : Text(t.dst).foregroundColor(dstColor) + Text(pd).foregroundColor(dstColor.opacity(0.35))
        let shape = UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: me ? 14 : 5,
                                           bottomTrailingRadius: me ? 5 : 14, topTrailingRadius: 14,
                                           style: .continuous)
        return VStack(alignment: me ? .trailing : .leading, spacing: 3) {
            if showTag {
                HStack(spacing: 4) {
                    Circle().fill(TLTalkModel.hue(String(t.who.dropFirst()))).frame(width: 6, height: 6)
                    Text(m.whoName(t.who))
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.tlText3)
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 3) {
                dstText
                    .font(.system(size: 16, weight: .semibold))
                    .lineSpacing(3)
                if !t.src.isEmpty || !ps.isEmpty {
                    (Text(t.src) + Text(ps).foregroundColor(Color.tlText3.opacity(0.35)))
                        .font(.system(size: 11.5))
                        .foregroundColor(Color.tlText3)
                        .lineSpacing(2)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 10)
            .background(me ? Color.tlAccent.opacity(0.13) : Color.tlCard, in: shape)
        }
        .frame(maxWidth: .infinity, alignment: me ? .trailing : .leading)
        .padding(me ? .leading : .trailing, 44)
    }

    // MARK: 타자 입력

    private var compose: some View {
        VStack(spacing: 8) {
            TextField("한국어로 입력", text: $m.typed, axis: .vertical)
                .font(.system(size: 16))
                .lineLimit(2...5)
                .focused($typing)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.tlCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if m.previewVisible {
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.prevDst)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(m.prevWaiting ? Color.tlText3 : Color.tlAccentDark)
                        .textSelection(.enabled)
                    if m.yomiWanted && !m.prevYomi.isEmpty {
                        Text(m.prevYomi).font(.system(size: 13)).foregroundStyle(Color.tlText3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.tlAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack(spacing: 8) {
                Button { m.clearTyped(); typing = true } label: {
                    Text("지우기")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tlText2)
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                Button { m.sendTyped() } label: {
                    Text("대화에 넣기")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tlOnAccent)
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .tlAccentGlass(cornerRadius: 12)
                }
                .buttonStyle(.plain)
                .disabled(!m.canSend)
                .opacity(m.canSend ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    // MARK: 아래

    private var foot: some View {
        VStack(spacing: 8) {
            if let s = m.say {
                Text(s)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.tlText2)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            TimelineView(.animation(paused: !m.mic)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * 1000 / 90
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<9, id: \.self) { i in
                        let h = m.mic ? 3 + Double(m.level) * 26 * (0.55 + 0.45 * abs(sin(t + Double(i) * 0.8))) : 3
                        RoundedRectangle(cornerRadius: 2)
                            .fill(m.live ? Color.tlAccent : Color.tlText3)
                            .frame(width: 3, height: min(16, h))
                    }
                }
                .frame(height: 16, alignment: .bottom)
            }
            HStack(spacing: 8) {
                Button {
                    m.composeOpen.toggle()
                    typing = m.composeOpen
                } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(m.composeOpen ? Color.tlAccentDark : Color.tlText2)
                        .frame(width: 50, height: 50)
                        .background(m.composeOpen ? Color.tlAccent.opacity(0.13) : Color.tlFill,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .tapHaptic()
                .accessibilityLabel("타자로 입력")

                Button { m.toggleMic() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: m.mic ? "stop.fill" : "mic")
                            .font(.system(size: 16, weight: .semibold))
                        Text(m.mic ? "멈추기" : "듣기 시작")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(m.mic ? Color.tlRed : Color.tlOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(Rectangle())
                    .modifier(TLGoBackground(on: m.mic))
                }
                .buttonStyle(.plain)
                .tapHaptic()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.2), value: m.say)
    }
}

/// 듣기 버튼 바탕 — 꺼져 있으면 초록 글래스, 듣는 중이면 회색
private struct TLGoBackground: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content.background(Color.tlFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            content.tlAccentGlass(cornerRadius: 14)
        }
    }
}

// MARK: 대화 설정

struct TLTalkSettings: View {
    @ObservedObject var m: TLTalkModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("대화 설정")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.5)
                    .padding(.top, 22).padding(.bottom, 6)

                head("번역")
                Toggle("Gemini로 다시 번역", isOn: $m.refine)
                    .font(.system(size: 16))
                    .tint(.tlAccent)
                    .changeHaptic(m.refine)
                    .padding(.vertical, 6)

                head("화자 이름")
                let seen = m.seenSpeakers
                if seen.isEmpty {
                    Text("아직 상대가 말하기 전이에요.\n목소리가 들어오면 여기에 A·B·C 로 나타나요.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.tlText3)
                        .lineSpacing(3)
                        .padding(.vertical, 8)
                } else {
                    ForEach(seen, id: \.self) { n in
                        HStack(spacing: 10) {
                            Text(TLTalkModel.letter(n))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(TLTalkModel.hue(n), in: Circle())
                            TextField("이름", text: Binding(
                                get: { m.names[n] ?? "" },
                                set: { m.names[n] = String($0.prefix(12)) }))
                                .font(.system(size: 16))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .padding(.vertical, 4)
                    }
                }

                Button { dismiss() } label: {
                    Text("닫기")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tlOnAccent)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .tlAccentGlass(cornerRadius: 12)
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func head(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(Color.tlText3)
            .padding(.top, 14).padding(.bottom, 4)
    }
}
