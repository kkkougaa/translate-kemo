import SwiftUI
import UIKit

// 공부 — 문제 내고, 채점 받고, 표현을 모은다. translator.html 의 sq* 를 옮겼다.
// 번역 기록은 문제가 아니라 참고 자료다. 이 사람이 실제로 쓰는 낱말과 관심사를 섞어 문장을 만들게 하고,
// 문장 자체를 베끼지는 않는다. 예문은 친구와 주고받는 평범한 일상 회화로.

/// 표현 노트에서 "이 표현으로 문제 풀기"를 누르면 이번 한 번만 쓸 출제 범위를 여기 둔다
enum TLStudyLaunch {
    static var once: String?
}

@MainActor
final class TLStudyModel: ObservableObject {
    enum Phase { case load, empty, quiz, grade, done }

    struct Q: Hashable { let ko: String; let src: String }
    struct Alt: Hashable { let ja: String; let yomi: String; let tag: String }
    struct Res {
        var v: String
        var alts: [Alt]
        var why: String
        var word: String
        var wordKo: String
        var wordWhy: String
        var wordYomi: String
        var wordTag: String
    }

    static let verdictText = ["ok": "그대로 써도 됨", "soso": "통하긴 함", "redo": "다시"]

    @Published var phase: Phase = .load
    @Published var list: [Q] = []
    @Published var i = 0
    @Published var ans = ""
    @Published var shown = ""
    @Published var res: Res?
    @Published var err = ""
    @Published var ok = 0
    @Published var soso = 0
    @Published var redo = 0
    @Published var learned: [TLWord] = []
    @Published var busy = false
    @Published var hint: String?
    @Published var hintBusy = false
    @Published var hintDone = false
    @Published var glossAdded = false
    @Published var toast: String?
    /// 조절에서 뭔가 바꿨으면 닫을 때 새로 낸다
    @Published var optDirty = false

    var lang = "ja"
    private(set) var started = false
    private var seq = 0
    let store = TLStore.shared

    var tgtName: String { TLLang.cfg(lang).label }
    var current: Q? { i < list.count ? list[i] : nil }
    var isLast: Bool { i >= list.count - 1 }

    var progress: String {
        if list.isEmpty || phase == .load || phase == .empty { return "" }
        return "\(phase == .done ? list.count : i + 1) / \(list.count)"
    }

    private func ask(_ prompt: String, _ maxTokens: Int) async throws -> String {
        try await Gemini.ask(model: store.effectiveModel, key: store.apiKey.trimmed, prompt: prompt, maxTokens: maxTokens)
    }

    // MARK: 출제

    func start() {
        started = true
        var o = TLNotes.opts
        if let once = TLStudyLaunch.once { o.range = once; TLStudyLaunch.once = nil }
        seq += 1
        let my = seq
        list = []; i = 0; ans = ""; shown = ""; res = nil; err = ""
        ok = 0; soso = 0; redo = 0; learned = []
        hint = nil; hintBusy = false; hintDone = false; glossAdded = false
        phase = .load
        guard store.hasKey else { err = "Gemini API 키가 필요해요"; phase = .empty; return }
        Task {
            do {
                let qs = try await build(o)
                guard my == seq else { return }
                if qs.isEmpty {
                    err = o.range == "wrong" ? "틀린 문제가 없어요"
                        : o.range == "words" ? "아직 모인 표현이 없어요"
                        : "문제를 만들지 못했어요"
                    phase = .empty
                } else {
                    list = qs
                    TLNotes.markSeen(qs.map(\.ko))
                    phase = .quiz
                }
            } catch {
                guard my == seq else { return }
                err = error.localizedDescription
                phase = .empty
            }
        }
    }

    private func build(_ o: TLStudyOpts) async throws -> [Q] {
        if o.range == "wrong" {
            return Array(TLNotes.wrongs.shuffled().prefix(o.count)).map { Q(ko: $0.ko, src: "틀린 문제") }
        }
        let qs = try await (o.range == "words" ? makeFromWords(o.count) : make(o, TLNotes.seen))
        // 같은 문장을 두 줄로 내놓을 때가 있다
        var uniq: [Q] = []
        for q in qs where !q.ko.isEmpty && !uniq.contains(where: { $0.ko == q.ko }) { uniq.append(q) }
        return Array(uniq.prefix(o.count))
    }

    private static func lines(_ out: String) -> [String] {
        out.components(separatedBy: "\n")
            .map { $0.rxReplace("^[\\s\\-•·\\d.)]+", "").trimmed }
            .filter { !$0.isEmpty }
    }

    /// 번역 기록에서 이 사람이 실제로 쓰는 말 몇 줄
    private func refLines(_ n: Int) -> [String] {
        var out: [String] = []
        for h in store.history {
            let t = (h.srcName == "한국어" ? h.src : h.tgt).trimmed
            if t.count < 4 || t.count > 60 || t.contains("\n") { continue }
            if !out.contains(t) { out.append(t) }
        }
        return Array(out.shuffled().prefix(n))
    }

    private func refBlock() -> String {
        let ls = refLines(12)
        let terms = store.glossary(lang).map(\.from).filter { !$0.isEmpty }.prefix(20)
        if ls.isEmpty && terms.isEmpty { return "" }
        var out = "\n\n[참고]\n이 사람이 요즘 쓰는 말입니다. 여기 나오는 낱말이나 관심사는 서너 문장에 한 번만 스치듯 섞고, 나머지는 평범한 생활 장면으로 만들어 주세요. 문장을 그대로 베끼지는 마세요.\n"
        if !terms.isEmpty { out += "- 자주 쓰는 말: " + terms.joined(separator: ", ") + "\n" }
        for l in ls { out += "- " + l + "\n" }
        return out
    }

    private func make(_ o: TLStudyOpts, _ skip: [String]) async throws -> [Q] {
        let avoid = skip.prefix(20)
        let avoidLine = avoid.isEmpty ? "" : "- 다음 문장과 겹치지 마세요: " + avoid.joined(separator: " / ") + "\n"
        let prompt = """
        친구와 주고받을 법한 한국어 문장을 \(o.count)개 만들어 주세요.

        [조건]
        - 평범한 일상 회화입니다. 약속을 잡고, 밥 얘기를 하고, 요즘 어떻게 지내는지 묻는 정도.
        - 친구끼리 하는 반말. 다만 인터넷 말투로 몰지 마세요.
          ㅋㅋ나 줄임말은 서너 문장에 한 번이면 충분하고, 아예 없어도 됩니다.
        - 커뮤니티 유행어나 오타쿠 용어를 매 문장에 넣지 마세요.
        - 주제: \(o.topics.joined(separator: ", "))
        - 교과서 예문도 쓰지 마세요. "오늘 날씨가 참 좋네요" 처럼 굳은 문장 금지.
        - 한 문장은 6자에서 35자 사이.
        \(avoidLine)- 각 줄은 "주제|문장" 형태로. 예) 약속|이번 주말에 시간 돼?
        - 설명이나 번호 없이 한 줄에 하나씩만 쓰세요.
        """ + refBlock()
        let out = try await ask(prompt, 800)
        return Array(Self.lines(out).map { line -> Q in
            if let r = line.range(of: "|"), r.lowerBound > line.startIndex {
                let topic = String(line[..<r.lowerBound]).trimmed
                return Q(ko: String(line[r.upperBound...]).trimmed, src: topic.isEmpty ? "일상 회화" : topic)
            }
            return Q(ko: line, src: "일상 회화")
        }.filter { $0.ko.count >= 4 && $0.ko.count <= 60 }.prefix(o.count))
    }

    /// 모아 둔 표현을 쓰게 될 만한 상황을 거꾸로 만들어 낸다
    private func makeFromWords(_ n: Int) async throws -> [Q] {
        let pick = Array(TLNotes.words.prefix(60).shuffled().prefix(n))
        if pick.isEmpty { return [] }
        let words = pick.map { $0.ja + ($0.ko.isEmpty ? "" : " (" + $0.ko + ")") }.joined(separator: "\n")
        let prompt = """
        아래 표현을 각각 한 번씩 쓰게 될 만한, 친구끼리 주고받는 한국어 문장을 하나씩 만들어 주세요.

        [표현]
        \(words)

        [조건]
        - 한국어 문장에 그 표현을 직접 적지 말고, 뜻이 담기게만 쓰세요.
        - 친구끼리 하는 반말. 인터넷 말투로 몰지 말고 평범한 생활 장면으로.
        - 설명이나 번호 없이 한 줄에 한 문장씩만 쓰세요.
        """
        let out = try await ask(prompt, 800)
        return Array(Self.lines(out).filter { $0.count >= 4 && $0.count <= 60 }.prefix(n)).map { Q(ko: $0, src: "배운 말") }
    }

    // MARK: 채점

    private static func json(_ text: String) -> [String: Any]? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let data = String(text[a...b]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func grade(_ ko: String, _ answer: String) async throws -> Res {
        let tgt = tgtName
        let gl = Glossary.instr(ko, pairs: store.glossary(lang), toKO: false)
        let prompt = """
        당신은 \(tgt)를 쓰는 친구입니다. 아래 한국어를 \(tgt)로 옮긴 답을 봐 주세요.

        [판정]
        ok — 현지인이 실제로 이렇게 씁니다. 그대로 보내도 됩니다.
        soso — 뜻은 전달되지만 번역 티가 나거나 말투가 어긋납니다.
        redo — 뜻이 어긋났습니다.

        [규칙]
        - 정답은 하나가 아닙니다. 자연스러우면 ok 를 주세요. 교과서 기준으로 깐깐하게 굴지 마세요.
        - 받는 사람은 친구입니다. 반말과 구어가 기본이고, 정중체로 썼으면 soso 입니다.
        - alts 는 이 상황에서 실제로 쓰는 말 두세 개. 교과서 표현보다 요즘 쓰는 말을 앞에 두세요.
        - tag 는 그 말을 어디까지 편하게 써도 되는지 한 단어로: 어디서나 / 친구끼리 / 요즘 말 / 칸사이 / 덕질
        - yomi 는 한글로 읽는 소리.
        - why 는 한국어 두세 문장. 왜 그 판정인지, 어디가 어긋났는지 짚어 주세요.
        - word 는 alts 중 새로 알아 갈 만한 표현 하나, wordKo 는 그 뜻을 한국어로 짧게,
          wordWhy 는 그 말의 뉘앙스를 한국어 한두 문장으로.
        - 설명이나 머리말 없이 JSON 만 출력하세요.

        [형식]
        {"verdict":"ok","alts":[{"ja":"","yomi":"","tag":""}],"why":"","word":"","wordKo":"","wordWhy":"","wordTag":""}
        """ + gl + "\n\n[한국어]\n" + ko + "\n\n[답]\n" + answer

        let raw = try await ask(prompt, 1200)
        guard let j = Self.json(raw) else {
            throw GeminiError(message: "채점 결과를 읽지 못했어요.")
        }
        let str: (String) -> String = { k in (j[k] as? String ?? "").trimmed }
        let alts = ((j["alts"] as? [[String: Any]]) ?? []).compactMap { a -> Alt? in
            guard let ja = a["ja"] as? String, !ja.trimmed.isEmpty else { return nil }
            return Alt(ja: TLText.tidyOut(ja.trimmed, tgtLang: lang),
                       yomi: (a["yomi"] as? String ?? "").trimmed,
                       tag: (a["tag"] as? String ?? "").trimmed)
        }.prefix(4)
        let word = TLText.tidyOut(str("word"), tgtLang: lang)
        let hit = alts.first { $0.ja == word }
        let v = str("verdict")
        return Res(v: ["ok", "soso", "redo"].contains(v) ? v : "soso",
                   alts: Array(alts),
                   why: str("why"),
                   word: word,
                   wordKo: str("wordKo"),
                   wordWhy: str("wordWhy"),
                   wordYomi: hit?.yomi ?? "",
                   wordTag: str("wordTag").isEmpty ? (hit?.tag ?? "") : str("wordTag"))
    }

    func submit(giveUp: Bool) {
        guard !busy, let q = current else { return }
        let a = ans.trimmed
        if !giveUp && a.isEmpty { return }
        guard store.hasKey else { show("Gemini API 키가 필요해요"); return }
        busy = true
        let my = seq
        Task {
            defer { if my == seq { busy = false } }
            do {
                let r = try await grade(q.ko, giveUp ? "(답을 못 썼습니다. 판정은 redo 로 하고 alts 와 해설만 채워 주세요.)" : a)
                guard my == seq else { return }
                res = r
                shown = giveUp ? "" : a
                if r.v == "ok" { ok += 1 } else if r.v == "soso" { soso += 1 } else { redo += 1 }
                if r.v == "ok" { TLNotes.dropWrong(q.ko) } else { TLNotes.addWrong(ko: q.ko, mine: shown, v: r.v) }
                if !r.word.isEmpty, let w = TLNotes.addWord(ja: r.word, yomi: r.wordYomi, ko: r.wordKo, tag: r.wordTag),
                   !learned.contains(where: { $0.ja == w.ja }) {
                    learned.append(w)
                }
                glossAdded = false
                phase = .grade
                Haptics.light()
            } catch {
                guard my == seq else { return }
                show(error.localizedDescription)
            }
        }
    }

    func askHint() {
        guard let q = current, !hintBusy, !hintDone else { return }
        hintBusy = true
        hint = "…"
        let prompt = "\"\(q.ko)\" 를 \(tgtName)로 옮길 때 열쇠가 되는 표현 하나만 알려 주세요. 문장 전체를 옮기지 말고, 그 표현과 한글 독음만 한 줄로 쓰세요."
        Task {
            defer { hintBusy = false }
            do {
                let out = try await ask(prompt, 150)
                let first = out.components(separatedBy: "\n").first?.trimmed ?? ""
                hint = TLText.tidyOut(first, tgtLang: lang)
                hintDone = true
            } catch {
                hint = error.localizedDescription
            }
        }
    }

    func next() {
        if isLast { phase = .done }
        else {
            i += 1
            ans = ""; shown = ""; res = nil
            hint = nil; hintBusy = false; hintDone = false; glossAdded = false
            phase = .quiz
        }
    }

    func addToGlossary() {
        guard let r = res, !r.word.isEmpty, let q = current else { return }
        var pairs = store.glossary(lang)
        if pairs.contains(where: { $0.to == r.word }) { show("이미 용어집에 있어요"); return }
        pairs.append(GlossaryPair(from: r.wordKo.isEmpty ? q.ko : r.wordKo, to: r.word))
        store.setGlossary(pairs, lang: lang)
        glossAdded = true
        show("용어집에 넣었어요")
        Haptics.light()
    }

    func show(_ s: String) {
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { toast = s }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation(.easeOut(duration: 0.25)) { if toast == s { toast = nil } }
        }
    }
}

// MARK: 화면

struct TLStudyPage: View {
    /// 대상 언어. 메인 화면에서 넘겨 주면 그 언어로 낸다.
    var tgtLang: String = "ja"
    @StateObject private var m = TLStudyModel()
    @State private var showOpts = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.tlBg.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        Color.clear.frame(height: 0).id("top")
                        content
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 18)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: m.i) { _, _ in proxy.scrollTo("top", anchor: .top) }
                .onChange(of: m.phase) { _, _ in proxy.scrollTo("top", anchor: .top) }
            }
            TLToastView(text: m.toast)
        }
        .navigationTitle("공부")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    if !m.progress.isEmpty {
                        Text(m.progress)
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.tlText3)
                    }
                    Button { showOpts = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("조절")
                }
            }
        }
        .sheet(isPresented: $showOpts, onDismiss: {
            if m.optDirty { m.optDirty = false; m.start() }
        }) {
            TLStudyOptsSheet(dirty: $m.optDirty)
        }
        .onAppear {
            // 노트에서 "다시 풀기"로 들어왔으면 진행 중이어도 새로 낸다
            if !m.started || TLStudyLaunch.once != nil {
                m.lang = tgtLang
                m.start()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch m.phase {
        case .load:
            HStack { TLLoadingDots(); Spacer() }
                .padding(.horizontal, 16).padding(.vertical, 28)
        case .empty:
            VStack(spacing: 16) {
                Text(m.err.isEmpty ? "낼 문제가 없어요" : m.err)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.tlText3)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                Button { m.start() } label: { TLGoLabel(title: "다시") }
                    .buttonStyle(.plain)
            }
            .padding(.top, 70).padding(.horizontal, 6)
        case .quiz:
            if let q = m.current { quiz(q) }
        case .grade:
            if let q = m.current { gradeView(q) }
        case .done:
            done
        }
    }

    // MARK: 문제

    private func quiz(_ q: TLStudyModel.Q) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 9) {
                Text(q.src)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color.tlAccentDark)
                Text(q.ko)
                    .font(.system(size: 23, weight: .semibold))
                    .tracking(-0.5)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 20)
            .tlCard()

            TextField(m.tgtName + "로 써보기", text: $m.ans, axis: .vertical)
                .font(.system(size: 18))
                .lineSpacing(5)
                .lineLimit(3...8)
                .focused($inputFocused)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(minHeight: 106, alignment: .topLeading)
                .tlCard()

            HStack(spacing: 8) {
                mini("힌트", disabled: m.hintBusy || m.hintDone) { m.askHint() }
                mini("모르겠어", disabled: m.busy) { inputFocused = false; m.submit(giveUp: true) }
            }

            if let h = m.hint {
                Text(h)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(Color.tlAccentDark)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Color.tlAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button { inputFocused = false; m.submit(giveUp: false) } label: {
                TLGoLabel(title: m.busy ? "보는 중" : "제출")
            }
            .buttonStyle(.plain)
            .tapHaptic()
            .disabled(m.busy || m.ans.trimmed.isEmpty)
            .opacity(m.busy || m.ans.trimmed.isEmpty ? 0.55 : 1)
        }
    }

    private func mini(_ title: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(Color.tlText2)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .tapHaptic()
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    // MARK: 채점

    private func gradeView(_ q: TLStudyModel.Q) -> some View {
        let r = m.res
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 9) {
                    TLVerdictPill(v: r?.v ?? "soso", text: TLStudyModel.verdictText[r?.v ?? "soso"] ?? "통하긴 함")
                    Text(q.ko)
                        .font(.system(size: 14.5))
                        .foregroundStyle(Color.tlText2)
                        .lineLimit(2)
                        .padding(.top, 3)
                }
                if m.shown.isEmpty {
                    Text("답을 안 쓰고 넘겼어요").font(.system(size: 16)).foregroundStyle(Color.tlText3)
                } else {
                    Text(m.shown).font(.system(size: 19)).lineSpacing(4).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 15)
            .tlCard()

            if let alts = r?.alts, !alts.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("이렇게 씀")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Color.tlText3)
                        .padding(.bottom, 5)
                    ForEach(alts, id: \.self) { a in
                        // 긴 표현이 발음을 밀어내지 않게 위아래로 쌓는다
                        HStack(alignment: .top, spacing: 9) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(a.ja)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.tlAccentDark)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !a.yomi.isEmpty {
                                    Text(a.yomi)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Color.tlText3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            if !a.tag.isEmpty { TLTagPill(text: a.tag) }
                        }
                        .padding(.vertical, 7)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 15)
                .tlCard()
            }

            VStack(alignment: .leading, spacing: 12) {
                if let why = r?.why, !why.isEmpty {
                    Text(why).font(.system(size: 15.5)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                }
                if let r, !r.word.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(r.word).font(.system(size: 16.5, weight: .bold)).foregroundStyle(Color.tlAccentDark)
                        let t = r.wordWhy.isEmpty ? r.wordKo : r.wordWhy
                        if !t.isEmpty {
                            Text(t).font(.system(size: 14)).lineSpacing(4).foregroundStyle(Color.tlText2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(Color.tlBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 15)
            .tlCard()

            HStack(spacing: 8) {
                if let r, !r.word.isEmpty {
                    Button { m.addToGlossary() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                            Text("용어집")
                        }
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Color.tlText2)
                        .padding(.horizontal, 15)
                        .frame(height: 52)
                        .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(m.glossAdded)
                    .opacity(m.glossAdded ? 0.45 : 1)
                }
                Button { m.next() } label: { TLGoLabel(title: m.isLast ? "끝내기" : "다음 문제") }
                    .buttonStyle(.plain)
                    .tapHaptic()
            }
        }
    }

    // MARK: 끝

    private var done: some View {
        VStack(spacing: 10) {
            VStack(spacing: 15) {
                Text("\(m.ok) / \(m.list.count)")
                    .font(.system(size: 58, weight: .bold))
                    .tracking(-2)
                    .monospacedDigit()
                    .foregroundStyle(Color.tlAccentDark)
                HStack(spacing: 7) {
                    TLVerdictPill(v: "ok", text: "그대로 \(m.ok)")
                    TLVerdictPill(v: "soso", text: "통함 \(m.soso)")
                    TLVerdictPill(v: "redo", text: "다시 \(m.redo)")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48).padding(.horizontal, 16)
            .tlCard()

            if !m.learned.isEmpty {
                NavigationLink(value: TLRoute.words) { TLGoLabel(title: "오늘 배운 말 \(m.learned.count)개") }
                    .buttonStyle(.plain)
            }
            Button { m.start() } label: {
                Text("다시 하기")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.tlText2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tapHaptic()
        }
    }
}

// MARK: 조절

struct TLStudyOptsSheet: View {
    @Binding var dirty: Bool
    @State private var o = TLNotes.opts
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("조절")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.5)
                    .padding(.top, 22).padding(.bottom, 4)

                label("출제 범위")
                VStack(spacing: 0) {
                    rangeRow("daily", "일상 회화", nil)
                    Divider().padding(.leading, 16)
                    rangeRow("words", "배운 말 다시", TLNotes.words.count)
                    Divider().padding(.leading, 16)
                    rangeRow("wrong", "틀린 문제", TLNotes.wrongs.count)
                }
                .background(Color.tlFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                label("주제")
                TLFlow(spacing: 7) {
                    ForEach(TLStudyOpts.topicsAll, id: \.self) { t in
                        let on = o.topics.contains(t)
                        Button {
                            if let k = o.topics.firstIndex(of: t) { if o.topics.count > 1 { o.topics.remove(at: k) } }
                            else { o.topics.append(t) }
                            save()
                        } label: {
                            Text(t)
                                .font(.system(size: 14, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Color.tlOnAccent : Color.primary)
                                .padding(.horizontal, 13)
                                .frame(height: 34)
                                .background(on ? Color.tlAccent : Color.tlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                label("한 번에")
                TLSeg(items: TLStudyOpts.counts.map { ($0, String($0)) },
                      selection: Binding(get: { o.count }, set: { o.count = $0; save() }))

                Button { dismiss() } label: { TLGoLabel(title: "완료") }
                    .buttonStyle(.plain)
                    .padding(.top, 18)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(Color.tlText3)
            .padding(.horizontal, 4).padding(.top, 15).padding(.bottom, 7)
    }

    private func rangeRow(_ k: String, _ title: String, _ n: Int?) -> some View {
        Button {
            o.range = k
            save()
        } label: {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 16)).foregroundStyle(.primary)
                if let n { Text("\(n)").font(.system(size: 15)).foregroundStyle(Color.tlText3) }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.tlAccent)
                    .opacity(o.range == k ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        TLNotes.opts = o
        dirty = true
        Haptics.selection()
    }
}
