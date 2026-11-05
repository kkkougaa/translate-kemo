import Foundation
import SwiftUI
import UIKit
#if canImport(llama)
import llama
#endif

// 기기 안 번역 — PLaMo 3 Translate (Preferred Networks) 를 llama.cpp 로 돌린다.
// 모델(GGUF)은 앱에 넣지 않는다. 이용자가 Hugging Face 에서 받은 .gguf 를 설정에서 가져오면
// Application Support/PLaMo/model.gguf 로 복사해 두고 쓴다 (iCloud 백업 제외).
// 번역만 PLaMo 가 하고, 코멘트·피드백·역번역·사진은 Gemini 가 맡는다.
//
// 프롬프트는 모델 카드의 PFML3 형식을 그대로 만든다:
//   <|plamo:tag|>dataset<|plamo:msg|>translation
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
    static func build(text: String, src: String, tgt: String, form: String?, glossary: [(src: String, dst: String)]) -> String {
        var p = "<|plamo:tag|>dataset<|plamo:msg|>translation"
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

    private let queue = DispatchQueue(label: "com.kouga.kemotranslate.plamo", qos: .userInitiated)
    private let lock = NSLock()
    private var _cancel = false
    private var _loaded = false
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancel }
    private func setCancel(_ v: Bool) { lock.lock(); _cancel = v; lock.unlock() }
    /// 모델이 메모리에 올라와 있나 (처음 번역은 올리느라 몇 초 걸린다)
    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return _loaded }

    /// 입력 + 출력 토큰 한도. 입력칸이 2000자라 이 정도면 충분하다.
    static let contextSize: Int32 = 6144

    #if canImport(llama)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var backendReady = false

    private func load(_ path: String) throws {
        if model != nil, ctx != nil { return }
        if !backendReady {
            llama_backend_init()
            // llama.cpp 로그는 콘솔만 어지럽힌다
            llama_log_set({ _, _, _ in }, nil)
            backendReady = true
        }
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999   // 전부 Metal(GPU) 로
        guard let m = llama_model_load_from_file(path, mp) else {
            throw GeminiError(message: "PLaMo 모델을 열지 못했어요. 파일이 깨졌거나 PLaMo 3 Translate GGUF 가 아닐 수 있어요.")
        }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(Self.contextSize)
        cp.n_batch = 1024
        cp.n_ubatch = 512
        let th = Int32(max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = th
        cp.n_threads_batch = th
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw GeminiError(message: "PLaMo 를 올릴 메모리가 모자라요. 더 작은 모델(0.8B)을 써 보세요.")
        }
        model = m; ctx = c
        lock.lock(); _loaded = true; lock.unlock()
    }

    private func freeAll() {
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        ctx = nil; model = nil
        lock.lock(); _loaded = false; lock.unlock()
    }

    /// 큐 위에서 돈다. onText 에는 지금까지 나온 번역 전체를 넘긴다.
    private func run(path: String, prompt: String, maxTokens: Int, onText: (String) -> Void) throws -> String {
        try load(path)
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

        let room = Int(Self.contextSize) - tokens.count - 8
        guard room > 32 else { throw GeminiError(message: "글이 너무 길어요. 나눠서 번역해 주세요.") }
        let limit = min(maxTokens, room)

        // 원문 읽히기 — 한 번에 n_batch 만큼씩
        let step = 1024
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
    func translate(path: String, prompt: String, maxTokens: Int = 2048,
                   onText: @escaping (String) -> Void) async throws -> String {
        #if canImport(llama)
        setCancel(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                queue.async { [self] in
                    do { cont.resume(returning: try run(path: path, prompt: prompt, maxTokens: maxTokens, onText: onText)) }
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

// MARK: 모델 파일

@MainActor
final class TLPlamo: ObservableObject {
    static let shared = TLPlamo()
    private let d = UserDefaults.standard

    /// 가져온 파일의 원래 이름 (예: plamo-3-translate-2b-Q4_K_M.gguf)
    @Published private(set) var fileName: String
    @Published private(set) var fileSize: Int64 = 0
    @Published private(set) var importing = false
    @Published var message: String?

    static let collectionURL = URL(string: "https://huggingface.co/collections/pfnet/plamo-3-translate")!

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PLaMo", isDirectory: true)
    }
    nonisolated static var modelURL: URL { folder.appendingPathComponent("model.gguf") }

    var installed: Bool { FileManager.default.fileExists(atPath: Self.modelURL.path) }
    /// 이름에서 크기를 읽는다 (0.8b · 2b · 8b · 31b)
    var sizeLabel: String {
        let n = fileName.lowercased()
        for s in ["0.8b", "31b", "8b", "2b"] where n.contains("-" + s) { return s.uppercased() }
        return ""
    }

    private init() {
        fileName = d.string(forKey: "tl.plamo_file") ?? ""
        refreshSize()
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { _ in
            TLPlamoEngine.shared.unload()
        }
    }

    private func refreshSize() {
        let a = try? FileManager.default.attributesOfItem(atPath: Self.modelURL.path)
        fileSize = (a?[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize == 0 && !installed { fileName = "" }
    }

    /// 파일 앱에서 고른 .gguf 를 앱 안으로 복사한다. 1~2GB 라 백그라운드에서.
    func importModel(from url: URL) {
        guard !importing else { return }
        importing = true
        message = nil
        let name = url.lastPathComponent
        Task.detached(priority: .userInitiated) {
            let result: Result<Void, Error> = Result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // GGUF 파일은 'GGUF' 네 글자로 시작한다
                let h = try FileHandle(forReadingFrom: url)
                let magic = try h.read(upToCount: 4) ?? Data()
                try? h.close()
                guard magic == Data("GGUF".utf8) else {
                    throw GeminiError(message: "GGUF 파일이 아니에요. Hugging Face 의 …-GGUF 저장소에서 .gguf 파일을 받아 주세요.")
                }
                let fm = FileManager.default
                try fm.createDirectory(at: TLPlamo.folder, withIntermediateDirectories: true)
                let tmp = TLPlamo.folder.appendingPathComponent("incoming.gguf")
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: url, to: tmp)
                // 쓰던 모델을 내리고 바꿔 끼운다
                TLPlamoEngine.shared.cancelCurrent()
                TLPlamoEngine.shared.unload(wait: true)
                try? fm.removeItem(at: TLPlamo.modelURL)
                try fm.moveItem(at: tmp, to: TLPlamo.modelURL)
                var dest = TLPlamo.modelURL
                var rv = URLResourceValues()
                rv.isExcludedFromBackup = true
                try? dest.setResourceValues(rv)
            }
            await MainActor.run {
                let s = TLPlamo.shared
                s.importing = false
                switch result {
                case .success:
                    s.fileName = name
                    s.d.set(name, forKey: "tl.plamo_file")
                    s.message = "가져왔어요"
                    TLHaptic.done()
                case .failure(let e):
                    try? FileManager.default.removeItem(at: TLPlamo.folder.appendingPathComponent("incoming.gguf"))
                    s.message = (e as? GeminiError)?.message ?? "가져오지 못했어요: " + e.localizedDescription
                    TLHaptic.error()
                }
                s.refreshSize()
            }
        }
    }

    func removeModel() {
        TLPlamoEngine.shared.cancelCurrent()
        TLPlamoEngine.shared.unload(wait: true)
        try? FileManager.default.removeItem(at: Self.modelURL)
        fileName = ""
        d.removeObject(forKey: "tl.plamo_file")
        message = nil
        refreshSize()
    }
}
