import AVFoundation
import Foundation
import Speech

// 말로 입력 — 기기 안 음성 인식. 설정 → 말로 입력에서 Soniox 와 바꿔 쓴다.
// 무료이고 인터넷 없이도 되지만, 한 번에 한 언어만 듣고 화자 구분·번역은 없다.

@MainActor
final class TLDeviceDictation: ObservableObject {
    static let shared = TLDeviceDictation()
    static let locales = ["ko": "ko-KR", "ja": "ja-JP", "en": "en-US", "zh-cn": "zh-CN", "zh-tw": "zh-TW"]
    /// 이만큼 새 글자가 없으면 말이 끝난 걸로 보고 멈춘다
    static let idleSeconds: TimeInterval = 2.5

    @Published private(set) var active = false
    @Published var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var idle: Timer?
    private var onDone: (() -> Void)?

    func toggle(lang: String, glossaryLang: String, base: String,
                onText: @escaping (String) -> Void, onDone: (() -> Void)? = nil) {
        if active { stop() } else { start(lang: lang, glossaryLang: glossaryLang, base: base, onText: onText, onDone: onDone) }
    }

    func start(lang: String, glossaryLang: String, base: String,
               onText: @escaping (String) -> Void, onDone: (() -> Void)? = nil) {
        guard !active else { return }
        active = true
        error = nil
        self.onDone = onDone
        Task {
            let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            guard auth == .authorized else { fail("음성 인식을 허용해 주세요."); return }
            guard await AVAudioApplication.requestRecordPermission() else { fail("마이크를 못 열었어."); return }
            guard self.active else { return }
            let loc = Locale(identifier: Self.locales[lang] ?? "ko-KR")
            guard let rec = SFSpeechRecognizer(locale: loc), rec.isAvailable else { fail("이 언어는 기기에서 못 알아들어요."); return }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.addsPunctuation = true
            // 기기 안에서만 — 애플 서버로 안 보낸다
            if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            // 용어집 낱말을 힌트로 (고유명사가 제일 잘 틀린다)
            var hints: [String] = []
            for p in TLStore.shared.glossary(glossaryLang).prefix(100) {
                if !p.from.isEmpty { hints.append(p.from) }
                if !p.to.isEmpty { hints.append(p.to) }
            }
            req.contextualStrings = hints
            request = req

            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try? s.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
            engine.prepare()
            do { try engine.start() } catch { fail("마이크를 못 열었어."); return }

            let lead = base.trimmed.isEmpty ? "" : base + (base.hasSuffix(" ") || base.hasSuffix("\n") ? "" : " ")
            task = rec.recognitionTask(with: req) { [weak self] result, err in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    if let text { onText(String((lead + text).prefix(2000))); self.bumpIdle() }
                    if final || err != nil { self.stop() }
                }
            }
            bumpIdle()
        }
    }

    func stop() {
        guard active else { return }
        active = false
        idle?.invalidate(); idle = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); request = nil
        task?.finish(); task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        TLHaptic.select()
        onDone?(); onDone = nil
    }

    private func bumpIdle() {
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: Self.idleSeconds, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.stop() }
        }
    }

    private func fail(_ msg: String) {
        error = msg
        active = false
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request = nil
        TLHaptic.error()
    }
}
