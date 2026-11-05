import Foundation
#if canImport(llama)
import llama
#endif

// 기기 안 번역 엔진 — PLaMo 3 Translate (Preferred Networks) 를 llama.cpp 로 돌린다.
// 본 앱만 쓴다. 기본 번역 앱 · 공유 시트(확장)는 메모리 한도가 빡빡해 꺼져서 Gemini 로 둔다.
// 모델 파일은 앱 그룹 폴더에 둔다 (첫 버전 자리에서 옮겨 온 그대로).
//
// 프롬프트는 모델 카드의 PFML3 형식을 그대로 만든다:
//   <|plamo:tag|>dataset<|plamo:msg|>translation
//   <|plamo:tag|>context<|plamo:msg|>참고 문맥                          (있을 때만)
//   <|plamo:tag|>glossary<|plamo:index|>원어<|plamo:item|>번역어 ...   (있을 때만)
//   <|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>ko<|plamo:msg|>원문
//   <|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja[<|plamo:key|>form<|plamo:val|>polite]<|plamo:msg|>
// 시작 토큰(<|plamo:bos|>)은 llama.cpp 가 붙인다. 번역 뒤에 <|plamo:tag|> · <|plamo:bos|> 가 나오면 멈춘다.

enum TLPlamoPrompt {
    /// 앱 언어 코드 → PLaMo 언어 코드
    static func code(_ l: String) -> String {
        switch l {
        case "zh-cn": return "zh-hans"
        case "zh-tw": return "zh-hant"
        default: return l
        }
    }

    /// 원문에 특수 토큰 모양이 있으면 글자로 남게 깨 둔다
    private static func safe(_ s: String) -> String {
        s.replacingOccurrences(of: "<|", with: "< |")
    }

    /// - form: 일본어로 옮길 때만 — "plain"(だ・である) · "polite"(です・ます)
    /// - context: 상황·말투 설명이나 앞뒤 글. 번역 대상이 아니라 참고로만 쓴다.
    static func build(text: String, src: String, tgt: String, form: String? = nil, context: String? = nil,
                      glossary: [(src: String, dst: String)] = []) -> String {
        var p = "<|plamo:tag|>dataset<|plamo:msg|>translation"
        if let c = context?.trimmed, !c.isEmpty {
            p += "<|plamo:tag|>context<|plamo:msg|>" + safe(c)
        }
        if !glossary.isEmpty {
            p += "<|plamo:tag|>glossary"
            for g in glossary { p += "<|plamo:index|>" + safe(g.src) + "<|plamo:item|>" + safe(g.dst) }
        }
        p += "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>" + code(src) + "<|plamo:msg|>" + safe(text)
        p += "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>" + code(tgt)
        if let form { p += "<|plamo:key|>form<|plamo:val|>" + form }
        return p + "<|plamo:msg|>"
    }

    /// 앱 용어집('원문=번역', 한국어 쪽이 from) 에서 이번 원문에 나오는 것만 번역 방향에 맞춰 꺼낸다
    static func glossary(_ pairs: [GlossaryPair], text: String, toKO: Bool) -> [(src: String, dst: String)] {
        let t = text.lowercased()
        return pairs.map { toKO ? (src: $0.to, dst: $0.from) : (src: $0.from, dst: $0.to) }
            .filter { !$0.src.trimmed.isEmpty && !$0.dst.trimmed.isEmpty && t.contains($0.src.lowercased()) }
    }

    /// 앱 말투 → PLaMo form (일본어 결과에서만)
    static func form(tone: String, outLang: String) -> String? {
        guard outLang == "ja" else { return nil }
        switch tone {
        case "formal": return "polite"
        case "young_male": return "plain"
        default: return nil
        }
    }

    static let stops = ["<|plamo:tag|>", "<|plamo:bos|>"]
}

// MARK: 모델 파일 자리

enum TLPlamoFiles {
    static let group = "group.com.kouga.kemotranslate"

    /// 앱 그룹 폴더 (확장도 읽는다). 서명 없는 빌드처럼 그룹이 없으면 앱 자신의 폴더.
    static var folder: URL {
        if let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return g.appendingPathComponent("PLaMo", isDirectory: true)
        }
        return legacyFolder
    }
    /// 첫 버전은 앱 자신의 Application Support 에 뒀다
    static var legacyFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PLaMo", isDirectory: true)
    }
    static var modelURL: URL { folder.appendingPathComponent("model.gguf") }
    static var installed: Bool { FileManager.default.fileExists(atPath: modelURL.path) }
}

// MARK: 엔진 (llama.cpp)

/// 모델·컨텍스트는 한 번 올리면 계속 쥐고 있다. 모든 일은 한 줄 큐에서 차례로 한다.
final class TLPlamoEngine: @unchecked Sendable {
    static let shared = TLPlamoEngine()

    static var compiled: Bool {
        #if canImport(llama)
        return true
        #else
        return false
        #endif
    }

    /// 어떻게 올릴지. 바뀌면 다시 올린다.
    struct Profile: Equatable {
        /// GPU(Metal) 를 쓸까. 앱이 뒤에 있을 땐(화면 소리 번역 PIP) GPU 를 못 써서 CPU 로 돌린다.
        var gpu = true
        /// 입력 + 출력 토큰 한도
        var context: Int32 = 6144
        /// 메모리를 아끼는 모양 — 확장은 메모리 한도가 빡빡해서 넘으면 iOS 가 바로 꺼 버린다.
        /// 모델은 mmap 으로만 읽고(파일에 기대는 깨끗한 페이지라 한도에 거의 안 잡힌다),
        /// 가중치 재배열 복사를 끄고, 작업 버퍼를 줄인다. GPU 를 쓰면 모델이 통째로 잡혀서 CPU 로.
        var lean = false

        static let app = Profile()
        static let background = Profile(gpu: false, context: 2048, lean: true)
    }

    private let queue = DispatchQueue(label: "com.kouga.kemotranslate.plamo", qos: .userInitiated)
    private let lock = NSLock()
    private var _cancel = false
    private var _loaded: Profile?
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancel }
    private func setCancel(_ v: Bool) { lock.lock(); _cancel = v; lock.unlock() }

    /// 이 모양으로 올라와 있나 (처음 번역은 올리느라 몇 초 걸린다)
    func isLoaded(_ p: Profile = .app) -> Bool { lock.lock(); defer { lock.unlock() }; return _loaded == p }

    #if canImport(llama)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var backendReady = false

    private func load(_ path: String, _ profile: Profile) throws {
        if model != nil, ctx != nil, isLoaded(profile) { return }
        freeAll()
        if !backendReady {
            llama_backend_init()
            // llama.cpp 로그는 콘솔만 어지럽힌다
            llama_log_set({ _, _, _ in }, nil)
            backendReady = true
        }
        var mp = llama_model_default_params()
        mp.n_gpu_layers = profile.gpu ? 999 : 0
        if profile.lean {
            mp.load_mode = LLAMA_LOAD_MODE_MMAP
            mp.use_extra_bufts = false
        }
        guard let m = llama_model_load_from_file(path, mp) else {
            throw GeminiError(message: "PLaMo 모델을 열지 못했어요. 파일이 깨졌거나 PLaMo 3 Translate GGUF 가 아닐 수 있어요.")
        }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(profile.context)
        cp.n_batch = profile.lean ? 512 : 1024
        cp.n_ubatch = profile.lean ? 256 : 512
        let th = Int32(max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = th
        cp.n_threads_batch = th
        if !profile.gpu {
            cp.offload_kqv = false
            cp.op_offload = false
        }
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw GeminiError(message: "PLaMo 를 올릴 메모리가 모자라요. 더 작은 모델(0.8B)을 써 보세요.")
        }
        model = m; ctx = c
        lock.lock(); _loaded = profile; lock.unlock()
    }

    private func freeAll() {
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        ctx = nil; model = nil
        lock.lock(); _loaded = nil; lock.unlock()
    }

    /// 큐 위에서 돈다. onText 에는 지금까지 나온 번역 전체를 넘긴다.
    private func run(path: String, profile: Profile, prompt: String, maxTokens: Int, onText: (String) -> Void) throws -> String {
        try load(path, profile)
        guard let model, let ctx else { throw GeminiError(message: "PLaMo 모델이 없어요.") }
        let vocab = llama_model_get_vocab(model)
        llama_memory_clear(llama_get_memory(ctx), true)

        // 토큰으로 — 특수 토큰을 알아보고(parse_special), 시작 토큰은 llama.cpp 가 붙인다(add_special)
        let byteCount = Int32(prompt.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(byteCount) + 16)
        var n = llama_tokenize(vocab, prompt, byteCount, &tokens, Int32(tokens.count), true, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, prompt, byteCount, &tokens, Int32(tokens.count), true, true)
        }
        guard n > 0 else { throw GeminiError(message: "PLaMo 에 넘길 글을 만들지 못했어요.") }
        tokens.removeSubrange(Int(n)...)

        let room = Int(profile.context) - tokens.count - 8
        guard room > 32 else { throw GeminiError(message: "글이 너무 길어요. 나눠서 번역해 주세요.") }
        let limit = min(maxTokens, room)

        // 원문 읽히기 — 한 번에 n_batch 만큼씩
        let step = profile.lean ? 512 : 1024
        var i = 0
        while i < tokens.count {
            if cancelled { throw CancellationError() }
            let len = min(step, tokens.count - i)
            let rc = tokens.withUnsafeMutableBufferPointer { buf in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress! + i, Int32(len)))
            }
            if rc != 0 { throw GeminiError(message: "PLaMo 가 원문을 읽지 못했어요 (\(rc)).") }
            i += len
        }

        // 한 토큰씩 — 번역은 늘 같은 답이 좋아서 greedy
        guard let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw GeminiError(message: "PLaMo 를 준비하지 못했어요.")
        }
        defer { llama_sampler_free(smpl) }
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy())

        var bytes: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 64)
        var out = ""
        for _ in 0..<limit {
            if cancelled { throw CancellationError() }
            var tok = llama_sampler_sample(smpl, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            var pn = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, true)
            if pn < 0 {
                piece = [CChar](repeating: 0, count: Int(-pn))
                pn = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, true)
            }
            if pn > 0 { bytes.append(contentsOf: piece[0..<Int(pn)].map { UInt8(bitPattern: $0) }) }
            // 글자가 반쯤 끊긴 바이트는 다음 토큰을 기다린다
            out = String(decoding: bytes, as: UTF8.self)
            if let r = TLPlamoPrompt.stops.compactMap({ out.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                out = String(out[..<r.lowerBound])
                break
            }
            onText(Self.visible(out))
            let rc = llama_decode(ctx, llama_batch_get_one(&tok, 1))
            if rc != 0 { throw GeminiError(message: "PLaMo 번역이 중간에 멈췄어요 (\(rc)).") }
        }
        return Self.visible(out)
    }
    #endif

    /// 보여줄 글 — 끝에 걸린 깨진 글자 · 반쯤 나온 특수 토큰은 숨긴다
    private static func visible(_ s: String) -> String {
        var t = s
        while t.hasSuffix("\u{FFFD}") { t.removeLast() }
        if let r = t.range(of: "<|", options: .backwards), TLPlamoPrompt.stops.contains(where: { $0.hasPrefix(String(t[r.lowerBound...])) }) {
            t = String(t[..<r.lowerBound])
        }
        return t
    }

    /// 번역 한 번. onText 는 큐(백그라운드)에서 불린다.
    func translate(prompt: String, profile: Profile = .app, maxTokens: Int = 2048,
                   onText: @escaping (String) -> Void = { _ in }) async throws -> String {
        #if canImport(llama)
        let path = TLPlamoFiles.modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw GeminiError(message: "PLaMo 모델 파일이 없어요. 설정 → 번역에서 가져와 주세요.")
        }
        setCancel(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                queue.async { [self] in
                    do { cont.resume(returning: try run(path: path, profile: profile, prompt: prompt, maxTokens: maxTokens, onText: onText)) }
                    catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: { [weak self] in
            self?.setCancel(true)
        }
        #else
        throw GeminiError(message: "이 빌드에는 기기 안 번역 엔진이 들어 있지 않아요.")
        #endif
    }

    /// 하던 번역을 멈추게 한다
    func cancelCurrent() { setCancel(true) }

    /// 모델을 메모리에서 내린다 (모델을 바꾸거나 지울 때, 메모리 경고 때). 하던 번역이 끝난 뒤 내린다.
    func unload(wait: Bool = false) {
        #if canImport(llama)
        let job = { [self] in freeAll() }
        if wait { queue.sync(execute: job) } else { queue.async(execute: job) }
        #endif
    }
}
