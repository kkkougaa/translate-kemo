import AVFoundation
import Foundation
import SwiftUI

// Soniox 실시간 전사. HTML 판은 @soniox/speech-to-text-web 를 썼는데, 그 SDK 가 하는 일은
// 웹소켓을 열고 설정 JSON 한 번 → 오디오 바이너리 → 끝낼 때 빈 문자열 한 번이 전부다. 그대로 옮겼다.
// 오디오는 MediaRecorder 대신 AVAudioEngine 으로 받아 16kHz 모노 s16le 로 바꿔 보낸다.

enum TLSoniox {
    static let url = "wss://stt-rt.soniox.com/transcribe-websocket"
    static let model = "stt-rt-v5"

    struct Token {
        let text: String
        let isFinal: Bool
        let speaker: String?
        let language: String?
        let isTranslation: Bool
    }

    /// 용어집을 인식 힌트로 같이 보낸다.
    /// 서브컬쳐 고유명사처럼 모델이 모르는 말이 제일 잘 틀리는데, 이걸로 잡힌다.
    /// terms 는 "이런 말이 나올 수 있다", translation_terms 는 "이건 이렇게 옮겨라".
    static func context(_ pairs: [GlossaryPair], withTranslation: Bool) -> [String: Any]? {
        if pairs.isEmpty { return nil }
        var terms: [String] = []
        var tt: [[String: String]] = []
        for p in pairs.prefix(100) {
            if !p.from.isEmpty, !terms.contains(p.from) { terms.append(p.from) }
            if !p.to.isEmpty, !terms.contains(p.to) { terms.append(p.to) }
            if withTranslation && !p.from.isEmpty && !p.to.isEmpty {
                tt.append(["source": p.from, "target": p.to])
                tt.append(["source": p.to, "target": p.from])   // 어느 쪽으로 말해도 걸리게
            }
        }
        var ctx: [String: Any] = ["terms": terms]
        if !tt.isEmpty { ctx["translation_terms"] = tt }
        return ctx
    }

    static func errorText(_ code: Int?, _ msg: String) -> String {
        if code == 401 { return "Soniox 키가 잘못됐어." }
        if code == 402 { return "Soniox 잔액이 없어." }
        return msg.isEmpty ? "음성 인식이 끊겼어." : msg
    }
}

// MARK: 연결

/// 웹소켓 하나. 결과 콜백은 메인 스레드로 돌려준다. 오디오는 어느 스레드에서 보내도 된다.
final class TLSonioxConn {
    var onTokens: (([TLSoniox.Token]) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((Int?, String) -> Void)?

    private let key: String
    private let config: [String: Any]
    private var task: URLSessionWebSocketTask?
    private var keepAlive: Timer?
    private let lock = NSLock()
    private var ending = false
    private var closed = false
    /// 직접 끊었거나 오류로 끊긴 경우. 이때는 늦게 온 결과도 버린다.
    private var dropped = false

    init(key: String, config: [String: Any]) {
        self.key = key
        self.config = config
    }

    func start() {
        guard let u = URL(string: TLSoniox.url) else { return }
        var req = URLRequest(url: u)
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let t = URLSession.shared.webSocketTask(with: req)
        lock.lock(); task = t; lock.unlock()
        t.resume()
        var cfg = config
        cfg["api_key"] = key            // SDK 와 같게. 헤더로도 보낸다
        cfg["audio_format"] = "pcm_s16le"
        cfg["sample_rate"] = 16000
        cfg["num_channels"] = 1
        if let data = try? JSONSerialization.data(withJSONObject: cfg), let s = String(data: data, encoding: .utf8) {
            t.send(.string(s)) { [weak self] err in
                if let err { self?.fail(nil, err.localizedDescription) }
            }
        }
        receive()
        // 조용한 동안에도 40초 안에 한 번은 신호를 보내야 끊기지 않는다
        DispatchQueue.main.async {
            self.keepAlive = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                self?.sendText("{\"type\":\"keepalive\"}")
            }
        }
    }

    func send(_ audio: Data) {
        lock.lock()
        let t = (ending || closed) ? nil : task
        lock.unlock()
        t?.send(.data(audio)) { _ in }
    }

    /// 남은 결과를 받고 끝낸다 (빈 문자열 한 번)
    func stop() {
        lock.lock()
        if ending || closed { lock.unlock(); return }
        ending = true
        let t = task
        lock.unlock()
        t?.send(.string("")) { _ in }
        // 서버가 finished 를 안 보내고 머무르면 3초 뒤 닫는다
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.close(notify: true) }
    }

    /// 바로 닫는다. 콜백은 부르지 않는다.
    func cancel() {
        lock.lock(); dropped = true; lock.unlock()
        close(notify: false)
    }

    private func sendText(_ s: String) {
        lock.lock()
        let t = closed ? nil : task
        lock.unlock()
        t?.send(.string(s)) { _ in }
    }

    private func receive() {
        lock.lock()
        let t = closed ? nil : task
        lock.unlock()
        t?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                let code = (t?.response as? HTTPURLResponse)?.statusCode
                self.lock.lock()
                let wasEnding = self.ending, wasClosed = self.closed
                self.lock.unlock()
                if wasClosed { return }
                if wasEnding { self.close(notify: true) }
                else { self.fail(code.flatMap { $0 >= 400 ? $0 : nil }, e.localizedDescription) }
            case .success(let msg):
                var text: String?
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: break
                }
                if let text, let d = text.data(using: .utf8),
                   let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    self.handle(obj)
                }
                self.receive()
            }
        }
    }

    private func handle(_ obj: [String: Any]) {
        if obj["error_code"] != nil || obj["error_message"] != nil {
            let code = (obj["error_code"] as? NSNumber)?.intValue
            fail(code, obj["error_message"] as? String ?? "")
            return
        }
        let raw = obj["tokens"] as? [[String: Any]] ?? []
        let tokens = raw.map { t -> TLSoniox.Token in
            var spk: String?
            if let s = t["speaker"] as? String { spk = s } else if let n = t["speaker"] as? NSNumber { spk = n.stringValue }
            return TLSoniox.Token(text: t["text"] as? String ?? "",
                                  isFinal: (t["is_final"] as? Bool) ?? false,
                                  speaker: spk,
                                  language: t["language"] as? String,
                                  isTranslation: (t["translation_status"] as? String) == "translation")
        }
        if !tokens.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDropped else { return }
                self.onTokens?(tokens)
            }
        }
        if (obj["finished"] as? Bool) == true { close(notify: true) }
    }

    private var isDropped: Bool { lock.lock(); defer { lock.unlock() }; return dropped }

    private func fail(_ code: Int?, _ msg: String) {
        lock.lock()
        if closed { lock.unlock(); return }
        dropped = true
        lock.unlock()
        let cb = onError
        close(notify: false)
        DispatchQueue.main.async { cb?(code, msg) }
    }

    private func close(notify: Bool) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let t = task
        task = nil
        lock.unlock()
        t?.cancel(with: .normalClosure, reason: nil)
        DispatchQueue.main.async { [weak self] in
            self?.keepAlive?.invalidate()
            self?.keepAlive = nil
            if notify { self?.onFinished?() }
        }
    }
}

// MARK: 마이크

/// 마이크 → 16kHz 모노 s16le 조각. 세기(0~1 최대 진폭)도 같이 알려 준다. 둘 다 오디오 스레드에서 부른다.
final class TLMic {
    var onChunk: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private(set) var running = false

    static func permission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        if running { return }
        let session = AVAudioSession.sharedInstance()
        // 잡음 억제·자동 음량은 통화용이라 인식을 갉아먹는다. 기본 모드로 둔다.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "TLMic", code: 1, userInfo: [NSLocalizedDescriptionKey: "마이크를 못 열었어."])
        }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            self?.handle(buf)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handle(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        if let ch = buf.floatChannelData, n > 0 {
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, abs(ch[0][i])) }
            onLevel?(peak)
        }
        guard let conv = converter else { return }
        let ratio = outFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if err != nil || out.frameLength == 0 { return }
        if let p = out.int16ChannelData {
            onChunk?(Data(bytes: p[0], count: Int(out.frameLength) * 2))
        }
    }
}

/// 오디오 스레드와 연결 사이. 연결이 붙기 전 0.5초쯤은 모아 뒀다가 붙자마자 보낸다 — 말 첫머리가 안 잘리게.
final class TLAudioPump {
    private let lock = NSLock()
    private var conn: TLSonioxConn?
    private var preroll: [Data] = []

    func attach(_ c: TLSonioxConn?) {
        lock.lock()
        conn = c
        let pending = c == nil ? [] : preroll
        if c != nil { preroll = [] }
        lock.unlock()
        for d in pending { c?.send(d) }
    }

    func push(_ d: Data) {
        lock.lock()
        let c = conn
        if c == nil {
            preroll.append(d)
            if preroll.count > 12 { preroll.removeFirst(preroll.count - 12) }
        }
        lock.unlock()
        c?.send(d)
    }

    func reset() { lock.lock(); preroll = []; conn = nil; lock.unlock() }
}

// MARK: 받아쓰기 (메인 입력칸 마이크)

/// 메인 화면 "말로 입력". 누르면 듣기 시작, 다시 누르면 멈춘다.
/// 사용: `TLDictation.shared.toggle(lang: srcLang 이 ko 면 "ko" 아니면 tgtLang, glossaryLang: tgtLang, base: input) { text in input = text }`
@MainActor
final class TLDictation: ObservableObject {
    static let shared = TLDictation()
    @Published private(set) var active = false
    @Published var error: String?

    private let mic = TLMic()
    private let pump = TLAudioPump()
    private var conn: TLSonioxConn?
    private var base = ""
    private var fin = ""
    private var onText: ((String) -> Void)?
    private var onDone: (() -> Void)?

    /// Soniox 키가 없으면 마이크 버튼을 아예 숨긴다
    var available: Bool { !TLStore.shared.sonioxKey.trimmed.isEmpty }

    func toggle(lang: String, glossaryLang: String, base: String,
                onText: @escaping (String) -> Void, onDone: (() -> Void)? = nil) {
        if active { stop() } else { start(lang: lang, glossaryLang: glossaryLang, base: base, onText: onText, onDone: onDone) }
    }

    func start(lang: String, glossaryLang: String, base: String,
               onText: @escaping (String) -> Void, onDone: (() -> Void)? = nil) {
        let key = TLStore.shared.sonioxKey.trimmed
        guard !active, !key.isEmpty else { return }
        active = true
        error = nil
        self.base = base
        self.fin = ""
        self.onText = onText
        self.onDone = onDone
        Task {
            guard await TLMic.permission() else { self.error = "마이크를 못 열었어."; self.finish(); return }
            guard self.active else { return }
            var cfg: [String: Any] = ["model": TLSoniox.model, "language_hints": [lang],
                                      "enable_endpoint_detection": true]
            if let ctx = TLSoniox.context(TLStore.shared.glossary(glossaryLang), withTranslation: false) { cfg["context"] = ctx }
            let c = TLSonioxConn(key: key, config: cfg)
            c.onTokens = { [weak self] toks in self?.take(toks) }
            c.onFinished = { [weak self, weak c] in if self?.conn === c { self?.finish() } }
            c.onError = { [weak self, weak c] code, msg in
                guard let self, self.conn === c else { return }
                self.error = TLSoniox.errorText(code, msg)
                self.finish()
            }
            self.conn = c
            let pump = self.pump
            self.mic.onChunk = { d in pump.push(d) }
            self.mic.onLevel = nil
            do { try self.mic.start() } catch { self.error = "마이크를 못 열었어."; self.finish(); return }
            c.start()
            pump.attach(c)
        }
    }

    func stop() {
        guard active else { return }
        mic.stop()
        pump.attach(nil)
        if let c = conn { c.stop() } else { finish() }
    }

    private func take(_ toks: [TLSoniox.Token]) {
        var pend = ""
        for t in toks where t.text != "<end>" {
            if t.isFinal { fin += t.text } else { pend += t.text }
        }
        let joined = (base.isEmpty ? "" : base + " ") + fin + pend
        onText?(String(joined.prefix(2000)))
    }

    private func finish() {
        mic.stop()
        pump.reset()
        conn?.cancel()
        conn = nil
        let done = onDone
        onText = nil
        onDone = nil
        active = false
        done?()
    }
}
