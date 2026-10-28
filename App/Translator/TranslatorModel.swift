import Foundation
import SwiftUI
import UIKit

// 번역 화면 상태와 동작. translator.html 의 translate() · sendFeedback() 흐름을 그대로 따른다.

enum ResultMode { case translate, grammar, spell, image }

struct FbMsg: Identifiable, Hashable {
    let id = UUID()
    let role: String   // user · ai
    let text: String
}

@MainActor
final class TranslatorModel: ObservableObject {
    let store = TLStore.shared

    // 언어
    @Published var srcLang = "ko"
    @Published var tgtLang = "ja"
    /// 직접 고른 대상 언어 — 자동 감지가 바꿔도 여기로 돌아온다
    @Published var userTgt = "ja"
    /// 직접 언어를 고르면 자동 감지를 멈춘다
    @Published var langLocked = false

    // 입력·옵션
    @Published var input = "" {
        didSet {
            if input.count > 2000 { input = String(input.prefix(2000)); return }
            if input != oldValue { scheduleDetect() }
        }
    }
    @Published var tone = "none"
    @Published var strict = true
    @Published var extraOn = false
    @Published var extraText = ""

    // 결과
    @Published var busy = false
    @Published var streaming = false
    @Published var result = ""
    @Published var comment = ""
    @Published var error = ""
    @Published var succeeded = false
    @Published var usedPriority = false
    @Published var fbMessages: [FbMsg] = []
    @Published var fbBusy = false
    @Published var toast: String?

    // 2단계 — 결과 종류 · 사진 · 역번역 · 독음
    @Published var mode: ResultMode = .translate
    @Published var attached: UIImage?
    var attachedData: Data?
    var attachedMime = "image/jpeg"
    @Published var overlay: [OverlayItem] = []
    /// 오버레이를 만든 그 사진 (첨부를 지워도 결과는 남는다)
    @Published var overlayImage: UIImage?
    @Published var madeImage: UIImage?
    @Published var makingImage = false
    var makeTask: Task<Void, Never>?
    @Published var btText: String?
    @Published var btOpen = false
    @Published var btLoading = false
    @Published var btWarn = ""
    @Published var btMarks: [String] = []
    @Published var pronText: String?
    @Published var pronOpen = false
    @Published var pronLoading = false
    var pronCache: [String: String] = [:]
    @Published var ttsLoading = false
    /// 결과를 손으로 고쳤나 — 고치면 독음 옆에 문법 버튼이 생긴다
    @Published var resultEdited = false
    @Published var checkText: String?
    @Published var checkLoading = false

    var originalText = ""
    var conversation: [[String: Any]] = []
    private var priorityOff = false
    var task: Task<Void, Never>?
    var reqSeq = 0
    private var detectTask: Task<Void, Never>?

    var toKO: Bool { srcLang != "ko" }
    var outLang: String { srcLang == "ko" ? tgtLang : "ko" }
    var outName: String { srcLang == "ko" ? TLLang.cfg(tgtLang).label : "한국어" }
    var resultLabel: String { toKO ? "한국어 결과" : TLLang.cfg(tgtLang).resultLabel }
    var placeholder: String { toKO ? TLLang.cfg(tgtLang).placeholder : "번역할 한국어를 입력하세요..." }
    var politeness: String { TLText.politeness(result, lang: outLang) }

    /// 일본어 대상에서만 쓰는 말투는 나머지 언어에서 잠근다
    func toneAvailable(_ id: String) -> Bool {
        if ["formal", "young_male", "adult"].contains(id) { return tgtLang == "ja" && srcLang == "ko" }
        return true
    }

    var optionsSummary: String {
        let name: String
        switch tone {
        case "formal": name = "정중하게"
        case "young_male": name = "20대 남성"
        case "adult": name = "성인"
        case "character": name = store.charName.trimmed.isEmpty ? "캐릭터" : store.charName.trimmed
        case "none": name = "기본"
        default: name = store.tones.first { $0.id == tone }?.name ?? "기본"
        }
        return name + " · " + (strict ? "원문 충실" : "정리 번역")
    }

    // MARK: 언어 바

    func pickKorean() {
        langLocked = true
        if srcLang != "ko" { srcLang = "ko"; clearResult() }
    }

    func pickTarget(_ lang: String) {
        langLocked = true
        if srcLang != "ko" { srcLang = lang }
        tgtLang = lang; userTgt = lang
        TLShare.setLastTarget(lang)
        if !toneAvailable(tone) { tone = "none" }
        clearResult()
    }

    func swap() {
        langLocked = true
        srcLang = srcLang == "ko" ? tgtLang : "ko"
        if !toneAvailable(tone) { tone = "none" }
        clearResult()
    }

    private func scheduleDetect() {
        detectTask?.cancel()
        detectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.applyAutoDetect()
        }
    }

    /// 감지가 바꾼 대상 언어는 임시다. 한국어로 돌아오면 고른 언어를 되살린다.
    func applyAutoDetect() {
        guard store.autoDetect, !langLocked, attached == nil else { return }
        var src = srcLang, tgt = tgtLang
        if input.trimmed.isEmpty { src = "ko"; tgt = userTgt }
        else {
            guard let det = TLText.detectInputLang(input) else { return }
            switch det {
            case "ko": src = "ko"; tgt = userTgt
            case "ja": src = "ja"; tgt = "ja"
            case "en": src = "en"; tgt = "en"
            case "foreign": src = tgtLang
            default: break
            }
        }
        if src == srcLang && tgt == tgtLang { return }
        srcLang = src; tgtLang = tgt
        if !toneAvailable(tone) { tone = "none" }
    }

    // MARK: 번역

    func clearResult() {
        result = ""; comment = ""; error = ""; succeeded = false
        conversation = []; fbMessages = []; usedPriority = false
        mode = .translate
        resetExtras()
    }

    func clearInput() {
        input = ""
        langLocked = false
        clearResult()
    }

    func translateOrCancel() {
        if busy { cancel() } else { translate() }
    }

    func cancel() {
        if busy { TLHaptic.cancel() }
        reqSeq += 1
        task?.cancel(); task = nil
        busy = false; streaming = false
    }

    private func context() -> TLPrompt.Context {
        TLPrompt.Context(srcLang: srcLang, tgtLang: tgtLang, tone: tone, strict: strict,
                         extraOn: extraOn, extraText: extraText, charPrompt: store.charPrompt,
                         tones: store.tones, glossary: store.glossary(tgtLang), bannedRaw: store.banned(tgtLang))
    }

    /// 용어집·금지어·요청문·말투처럼 "이렇게 써 달라"고 넘긴 글
    private func userPool(_ reqs: [String]) -> String {
        var pool = Glossary.serialize(store.glossary(tgtLang)) + "\n" + store.banned(tgtLang)
        pool += "\n" + reqs.joined(separator: "\n")
        if extraOn { pool += "\n" + extraText }
        if tone == "character" { pool += "\n" + store.charPrompt }
        return pool
    }

    var genCfg: [String: Any] {
        var g: [String: Any] = ["temperature": 0.3, "maxOutputTokens": 2048]
        if !store.thinking { g["thinkingConfig"] = ["thinkingBudget": 0] }
        return g
    }
    private var timeout: TimeInterval { store.thinking ? 90 : 25 }

    /// 우선 처리를 켰고 글 한 덩어리면 Interactions API 로, 아니면 스트리밍
    func stream(_ body: [String: Any], single: String?, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        let key = store.apiKey.trimmed, model = store.effectiveModel, thinking = store.thinking
        if store.priority, !priorityOff, let text = single, !text.isEmpty {
            do {
                let out = try await Gemini.withRetry { try await Gemini.askPriority(model: model, key: key, text: text, thinking: thinking) }
                usedPriority = true
                onText(out)
                return out
            } catch let e as GeminiError where e.priorityRejected {
                priorityOff = true
                usedPriority = false
                show("우선 처리를 못 써서 표준으로 돌렸어요")
            }
        }
        let t = timeout
        return try await Gemini.withRetry { try await Gemini.streamOnce(model: model, key: key, body: body, timeout: t, onText: onText) }
    }

    func translate() {
        let text = input.trimmed
        guard !text.isEmpty || attachedData != nil, !busy else { return }
        guard store.hasKey else { error = "설정에서 Gemini API 키를 넣어주세요."; return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        busy = true; streaming = false; error = ""; usedPriority = false; succeeded = false
        result = ""; comment = ""; fbMessages = []; conversation = []
        mode = .translate
        resetExtras()
        reqSeq += 1
        let my = reqSeq
        let ctx = context()
        let outL = outLang, oName = outName, sLang = srcLang, tLang = tgtLang
        let toKO = self.toKO
        let parsed = TLText.parseInput(text)
        let img = attachedData, imgMime = attachedMime
        // 글 없이 사진만 있으면 사진 속 글을 옮긴다
        let promptText = img != nil && text.isEmpty ? TLExtras.imagePlainPrompt(tgtName: oName) : TLPrompt.build(text, ctx)
        let glossary = ctx.glossary
        let pool = userPool(parsed.reqs)
        let gen = genCfg

        let draw: @MainActor (String) -> Void = { [weak self] full in
            guard let self, my == self.reqSeq else { return }
            if !self.streaming { TLHaptic.tick() }
            self.streaming = true
            self.result = TLText.splitComment(full).body.trimmedStart
            self.comment = ""
        }
        // 본문만 다듬는다 — 읽는 법 꼬리 떼기, 전각 숫자·영문 반각, 용어집 강제. 코멘트는 그대로.
        let polish: (String) -> String = { full in
            var cs = full.components(separatedBy: TLText.commentSep)
            cs[0] = Glossary.enforce(TLText.tidyOut(cs[0], tgtLang: outL), srcText: parsed.body,
                                     outLang: outL, pairs: glossary, toKO: toKO)
            return cs.joined(separator: TLText.commentSep)
        }

        task = Task { [weak self] in
            guard let self else { return }
            defer { if my == self.reqSeq { self.busy = false; self.streaming = false } }
            do {
                var parts: [[String: Any]] = []
                if let img { parts.append(["inline_data": ["mime_type": imgMime, "data": img.base64EncodedString()]]) }
                parts.append(["text": promptText])
                let body: [String: Any] = ["contents": [["parts": parts]], "generationConfig": gen]
                // 사진이 붙으면 우선 처리(Interactions)로 못 보낸다
                var result = try await self.stream(body, single: img == nil ? promptText : nil, onText: draw).trimmed
                if result.isEmpty { throw GeminiError(message: "번역 결과를 받지 못했습니다.") }
                let p0 = polish(result)
                if p0 != result { result = p0; draw(result) }

                // 대상 언어가 아닌 글자가 섞였으면 알리지 않고 한 번만 다시 부른다
                if img == nil && my == self.reqSeq {
                    let allow = TLText.allowedExtraChars(srcLang: sLang, srcBody: parsed.body, pool: pool)
                    let badness: (String) -> Int = { t in
                        let b = TLText.splitComment(t).body
                        return TLText.strayChars(b, tgtLang: outL, allow: allow).count
                            + TLText.strayWords(b, tgtLang: outL, srcBody: parsed.body, pool: pool).count
                    }
                    let b0 = TLText.splitComment(result).body
                    let strays = TLText.strayChars(b0, tgtLang: outL, allow: allow)
                    let words = TLText.strayWords(b0, tgtLang: outL, srcBody: parsed.body, pool: pool)
                    if !strays.isEmpty || !words.isEmpty {
                        let retryText = TLPrompt.retryFix(promptText, strays: strays, words: words, tgtName: oName)
                        let rb: [String: Any] = ["contents": [["parts": [["text": retryText]]]], "generationConfig": gen]
                        if let retried = try? await self.stream(rb, single: retryText, onText: draw).trimmed, !retried.isEmpty {
                            let fixed = polish(retried)
                            if badness(fixed) < strays.count + words.count { result = fixed }
                        }
                        draw(result)
                    }
                }
                guard my == self.reqSeq, !Task.isCancelled else { return }

                let split = TLText.splitComment(result)
                let clean = TLText.cleanForCopy(split.body)
                if !text.isEmpty { self.store.saveHistory(src: text, tgt: clean, srcLang: sLang, tgtLang: tLang) }
                self.originalText = parsed.body
                self.conversation = [
                    ["role": "user", "parts": [["text": TLPrompt.feedbackSystem(source: parsed.body, result: result)]]],
                    ["role": "model", "parts": [["text": "네, 번역 결과를 기억했습니다. 수정 요청을 말씀해주세요."]]]
                ]
                self.result = clean
                self.comment = (split.comment ?? "").trimmed
                self.fbMessages = []
                self.succeeded = true
                TLHaptic.done()
                // 역번역은 접어두지 않고 번역 직후 바로 가져와 펼친다
                if sLang == "ko" { self.toggleBackTranslation() }
            } catch is CancellationError {
            } catch {
                guard my == self.reqSeq else { return }
                self.error = "오류: " + error.localizedDescription
                TLHaptic.error()
            }
        }
        TLHaptic.start()
    }

    // MARK: 피드백

    func sendFeedback(_ msg: String) {
        let m = msg.trimmed
        guard !m.isEmpty, !busy, !fbBusy, !conversation.isEmpty else { return }
        guard store.hasKey else { error = "설정에서 Gemini API 키를 넣어주세요."; return }
        fbMessages.append(FbMsg(role: "user", text: m))
        // 손으로 고친 번역이 있으면 그걸 기준으로 고쳐 달라고 같이 보낸다
        let ask = resultEdited ? "[지금 번역문 — 내가 직접 고쳤어]\n\(result)\n\n[요청]\n\(m)" : m
        conversation.append(["role": "user", "parts": [["text": ask]]])
        fbBusy = true
        let outL = outLang, oName = outName, sLang = srcLang, toKO = self.toKO
        let glossary = store.glossary(tgtLang)
        let source = originalText
        let conv = conversation
        let gen = genCfg
        let draw: @MainActor (String) -> Void = { [weak self] full in
            self?.result = TLText.splitComment(full).body.trimmedStart
        }
        let tidy: (String) -> String = { t in
            Glossary.enforce(TLText.cleanForCopy(TLText.tidyOut(t, tgtLang: outL)), srcText: source,
                             outLang: outL, pairs: glossary, toKO: toKO)
        }
        Task { [weak self] in
            guard let self else { return }
            defer { self.fbBusy = false }
            do {
                var reply = try await self.stream(["contents": conv, "generationConfig": gen], single: nil, onText: draw).trimmed
                if reply.isEmpty { throw GeminiError(message: "응답을 받지 못했습니다.") }
                reply = tidy(reply)
                // 수정본에도 딴 언어가 끼어든다. 같은 그물을 걸고 한 번만 다시 부른다.
                let allow = TLText.allowedExtraChars(srcLang: sLang, srcBody: source, pool: "")
                let bad: (String) -> [String] = { t in
                    TLText.strayChars(t, tgtLang: outL, allow: allow) + TLText.strayWords(t, tgtLang: outL, srcBody: source, pool: "")
                }
                let b = bad(reply)
                if !b.isEmpty {
                    let ask = "방금 결과에 \(oName)가 아닌 것(\(b.prefix(6).joined(separator: ", ")))이 섞여 있었습니다."
                        + " 인명과 고유명사까지 모두 \(oName) 표기로 옮겨서, 번역문만 다시 써 주세요."
                    let c2 = conv + [["role": "model", "parts": [["text": reply]]], ["role": "user", "parts": [["text": ask]]]]
                    if let again = try? await self.stream(["contents": c2, "generationConfig": gen], single: nil, onText: { _ in }).trimmed {
                        let fixed = tidy(again)
                        if !fixed.isEmpty && bad(fixed).count < b.count { reply = fixed }
                    }
                }
                self.conversation.append(["role": "model", "parts": [["text": reply]]])
                self.result = reply
                self.comment = ""
                self.resultEdited = false
                self.checkText = nil
                self.fbMessages.append(FbMsg(role: "ai", text: reply))
                TLHaptic.done()
            } catch is CancellationError {
            } catch {
                self.fbMessages.append(FbMsg(role: "ai", text: "오류: " + error.localizedDescription))
                TLHaptic.error()
            }
        }
    }

    // MARK: 용어집 제안

    var glossarySuggestions: [Glossary.Suggestion] {
        guard succeeded, mode == .translate, srcLang == "ko", tgtLang == "ja" else { return [] }
        return Glossary.suggest(srcText: originalText, history: store.history, tgtLabel: TLLang.cfg(tgtLang).label,
                                pairs: store.glossary(tgtLang), skip: store.glossarySkip(tgtLang))
    }

    func acceptSuggestion(_ s: Glossary.Suggestion) {
        var list = store.glossary(tgtLang)
        if !list.contains(where: { $0.from == s.x }) { list.append(GlossaryPair(from: s.x, to: s.k)) }
        store.setGlossary(list, lang: tgtLang)
        show("용어집에 넣었어요")
        TLHaptic.select()
    }

    func dismissSuggestion(_ s: Glossary.Suggestion) {
        store.addGlossarySkip(s.x + "=" + s.k, lang: tgtLang)
    }

    // MARK: 복사·알림

    func copyResult() {
        guard !result.isEmpty else { return }
        UIPasteboard.general.string = TLText.cleanForCopy(result)
        show("복사했어요"); TLHaptic.copy()
    }

    func copyBoth() {
        guard !result.isEmpty else { return }
        let orig = TLText.cleanForCopy(input)
        UIPasteboard.general.string = [orig, TLText.cleanForCopy(result)].filter { !$0.isEmpty }.joined(separator: "\n\n")
        show("복사했어요"); TLHaptic.copy()
    }

    /// 클립보드에 사진이 있으면 사진을, 아니면 글을 붙인다
    func paste() {
        let pb = UIPasteboard.general
        if pb.hasImages, let im = pb.image { attach(im); TLHaptic.copy(); return }
        if let s = pb.string, !s.isEmpty { input = String(s.prefix(2000)); TLHaptic.copy() }
    }

    func loadHistory(_ h: HistoryItem) {
        langLocked = false
        input = h.src
    }

    func show(_ msg: String) {
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { toast = msg }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            withAnimation(.easeOut(duration: 0.25)) { if self?.toast == msg { self?.toast = nil } }
        }
    }
}
