import AVFoundation
import AVKit
import CoreMedia
import Network
import ReplayKit
import SwiftUI
import UIKit

// 화면 소리 번역 (네이티브 전용).
// 방송 확장(BroadcastExtension)이 다른 앱의 소리를 127.0.0.1:48231 로 보내 주면
// 여기서 Soniox 로 받아 적고 한국어로 옮겨, 흐르는 말풍선(시안 B) 모양으로 PIP 에 띄운다.

struct TLScreenLine: Identifiable, Hashable {
    let id = UUID()
    var src: String
    var dst: String
    /// 화자 색 번호 (처음 나온 순서대로 0, 1, 2…)
    var who: Int = 0
}

/// 화자 색 — 처음 나온 순서대로 파랑·주황·초록·분홍·보라
enum TLSpeaker {
    static let colors: [Color] = [
        Color(red: 0x31 / 255, green: 0x82 / 255, blue: 0xF6 / 255),
        Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255),
        Color(red: 0x10 / 255, green: 0xB9 / 255, blue: 0x81 / 255),
        Color(red: 0xEC / 255, green: 0x48 / 255, blue: 0x99 / 255),
        Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)
    ]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}

// MARK: 확장 → 앱 (로컬 소켓)

/// 방송 확장이 붙는 자리. 소리는 네트워크 큐에서 바로 넘긴다.
final class TLScreenLink {
    static let port: UInt16 = 48231

    var onAudio: ((Data) -> Void)?
    var onConnected: ((Bool) -> Void)?

    private let q = DispatchQueue(label: "com.kouga.kemotranslate.screenlink")
    private var listener: NWListener?
    private var conns: [ObjectIdentifier: NWConnection] = [:]
    private var odd: UInt8?

    func start() {
        q.async {
            guard self.listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: params, on: port) else { return }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self, weak l] st in
                if case .failed = st {
                    l?.cancel()
                    self?.listener = nil
                    // 포트가 아직 안 풀렸으면 잠깐 뒤 다시 연다
                    self?.q.asyncAfter(deadline: .now() + 1) { self?.start() }
                }
            }
            self.listener = l
            l.start(queue: self.q)
        }
    }

    private func accept(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        conns[id] = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.odd = nil
                self.onConnected?(true)
            case .failed, .cancelled:
                self.conns[id] = nil
                if self.conns.isEmpty { self.onConnected?(false) }
            default:
                break
            }
        }
        c.start(queue: q)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            if var d = data, !d.isEmpty {
                // TCP 는 바이트를 아무 데서나 자른다. 16비트 샘플이 반으로 갈리지 않게 맞춘다.
                if let o = self.odd { d.insert(o, at: d.startIndex); self.odd = nil }
                if d.count % 2 == 1 { self.odd = d.removeLast() }
                if !d.isEmpty { self.onAudio?(d) }
            }
            if done || err != nil { c.cancel(); return }
            self.receive(c)
        }
    }
}

// MARK: 뒤로 가도 살아 있게

/// PIP 만 떠 있을 때도 앱이 계속 돌아야 소리를 받아 옮길 수 있다.
/// 다른 앱 소리와 섞이는 무음을 틀어 두어 백그라운드 오디오로 남는다.
final class TLKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false

    func start() {
        guard !running else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
        let fmt = engine.mainMixerNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fmt.sampleRate)) else { return }
        buf.frameLength = buf.frameCapacity      // 0 으로 채워진 1초
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        do { try engine.start() } catch { return }
        player.scheduleBuffer(buf, at: nil, options: .loops)
        player.play()
        running = true
    }

    func stop() {
        guard running else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        running = false
    }
}

// MARK: PIP

/// 그림을 AVSampleBufferDisplayLayer 에 한 장씩 넣어 PIP 로 띄운다. PIP 창은 영상이라 배경이 불투명하다.
final class TLPiP: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    let layer = AVSampleBufferDisplayLayer()
    @Published private(set) var active = false
    @Published private(set) var possible = false
    /// 시스템 일시정지 버튼 → 번역 멈춤
    var onPause: ((Bool) -> Void)?
    private var controller: AVPictureInPictureController?
    private var possibleObs: NSKeyValueObservation?
    private let lock = NSLock()
    private var _paused = false
    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
    }

    func setup() {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let src = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: src)
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = true
        possibleObs = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let p = c.isPictureInPicturePossible
            DispatchQueue.main.async { self?.possible = p }
        }
        controller = c
    }

    func toggle() {
        guard let c = controller else { return }
        if c.isPictureInPictureActive { c.stopPictureInPicture() } else { c.startPictureInPicture() }
    }

    func stop() { controller?.stopPictureInPicture() }

    func show(_ cg: CGImage) {
        guard let sb = Self.sampleBuffer(cg) else { return }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sb)
    }

    private static func sampleBuffer(_ cg: CGImage) -> CMSampleBuffer? {
        let w = cg.width, h = cg.height
        var pbOut: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pbOut) == kCVReturnSuccess,
              let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        var fdOut: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fdOut)
        guard let fd = fdOut else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sbOut: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fd,
                                                 sampleTiming: &timing, sampleBufferOut: &sbOut)
        guard let sb = sbOut else { return nil }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    // 재생 위임 — 끝이 없는 실시간이라 시간 막대가 안 뜨게 무한 구간을 준다
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        paused = !playing
        DispatchQueue.main.async { self.onPause?(!playing) }
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { paused }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) { completionHandler() }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.active = true }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.active = false }
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async { self.active = false }
    }
}

/// 디스플레이 레이어를 화면 안에 붙여 둔다. PIP 는 화면에 보이는 레이어에서만 시작된다.
struct TLPiPHost: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    final class HostView: UIView {
        var hosted: CALayer? {
            didSet { oldValue?.removeFromSuperlayer(); if let l = hosted { layer.addSublayer(l) } }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.backgroundColor = .white
        v.hosted = layer
        return v
    }

    func updateUIView(_ v: HostView, context: Context) {
        if v.hosted !== layer { v.hosted = layer }
    }
}

// MARK: 상태

@MainActor
final class TLScreenModel: ObservableObject {
    static let shared = TLScreenModel()
    static let langs = ["ja", "en", "zh-cn"]
    static let wake: Float = 0.012
    static let quietSeconds: TimeInterval = 15

    @Published private(set) var broadcasting = false
    @Published private(set) var live = false
    @Published private(set) var lines: [TLScreenLine] = []
    @Published private(set) var pSrc = ""
    @Published private(set) var pDst = ""
    @Published private(set) var error: String?
    @Published private(set) var paused = false
    @Published private(set) var startedAt: Date?
    @Published var lang: String { didSet { d.set(lang, forKey: "tl.screen_lang"); reconnect() } }
    @Published var showSrc: Bool { didSet { d.set(showSrc, forKey: "tl.screen_src"); redraw() } }
    @Published var fontScale: Double { didSet { d.set(fontScale, forKey: "tl.screen_fs"); redraw() } }
    /// 자막 창 모양: 기본(4:3) · 가로로 길게(화면 위에 띠처럼)
    @Published var wide: Bool { didSet { d.set(wide, forKey: "tl.screen_wide"); redraw() } }
    /// 지금 말 위에 이전 대화를 몇 줄까지 남기나
    @Published var history: Int { didSet { d.set(history, forKey: "tl.screen_hist"); redraw() } }
    /// 자막 테마 — 글꼴(default·rounded·serif) · 띠 색 · 줄 간격
    @Published var captionFont: String { didSet { d.set(captionFont, forKey: "tl.screen_font"); redraw() } }
    @Published var captionBar: String { didSet { d.set(captionBar, forKey: "tl.screen_bar"); redraw() } }
    @Published var captionSpacing: Double { didSet { d.set(captionSpacing, forKey: "tl.screen_spacing"); redraw() } }

    /// PIP 에 넣는 그림 크기 (pt). 창 비율이 이걸 따라간다.
    var canvas: CGSize { wide ? CGSize(width: 480, height: 150) : CGSize(width: 320, height: 240) }

    let pip = TLPiP()
    private let d = UserDefaults.standard
    private let link = TLScreenLink()
    private let pump = TLAudioPump()
    private let keep = TLKeepAlive()
    private let store = TLStore.shared
    private var conn: TLSonioxConn?
    private var quietAt = Date()
    private var cur: TLScreenLine?
    private var lastID: UUID?
    /// Soniox 화자 번호 → 색 번호
    private var speakers: [String: Int] = [:]
    private var drawPending = false
    private var started = false

    private init() {
        lang = d.string(forKey: "tl.screen_lang") ?? "ja"
        showSrc = d.object(forKey: "tl.screen_src") as? Bool ?? true
        fontScale = d.object(forKey: "tl.screen_fs") as? Double ?? 1
        wide = d.object(forKey: "tl.screen_wide") as? Bool ?? false
        history = d.object(forKey: "tl.screen_hist") as? Int ?? 3
        captionFont = d.string(forKey: "tl.screen_font") ?? "default"
        captionBar = d.string(forKey: "tl.screen_bar") ?? "blue"
        captionSpacing = d.object(forKey: "tl.screen_spacing") as? Double ?? 1
    }

    /// 화면에 처음 들어올 때 한 번. 소켓을 열어 두면 방송을 먼저 켜도 여기로 붙는다.
    func start() {
        guard !started else { redraw(); return }
        started = true
        pip.setup()
        pip.onPause = { [weak self] p in self?.setPaused(p) }
        let pump = self.pump
        link.onAudio = { [weak self] data in
            // 네트워크 큐: 소리는 바로 넘기고, 크기만 메인으로 올린다
            pump.push(data)
            let lvl = Self.rms(data)
            DispatchQueue.main.async { self?.level(lvl) }
        }
        link.onConnected = { [weak self] on in DispatchQueue.main.async { self?.setBroadcasting(on) } }
        link.start()
        redraw()
    }

    var langName: String { lang == "ko" ? "한국어" : TLLang.cfg(lang).label }

    func clear() {
        lines = []; cur = nil; lastID = nil; pSrc = ""; pDst = ""; speakers = [:]
        redraw()
    }

    func togglePiP() {
        if !pip.active { keep.start() }
        pip.toggle()
    }

    private func setBroadcasting(_ on: Bool) {
        broadcasting = on
        if on {
            startedAt = Date()
            error = nil
            keep.start()
        } else {
            startedAt = nil
            disconnect()
            if !pip.active { keep.stop() }
        }
        redraw()
    }

    private func setPaused(_ p: Bool) {
        paused = p
        if p { disconnect() }
        redraw()
    }

    /// 네트워크 큐에서 부른다. 두 샘플에 하나만 봐도 크기는 충분히 잡힌다.
    nonisolated private static func rms(_ d: Data) -> Float {
        d.withUnsafeBytes { raw -> Float in
            let n = raw.count / 2
            if n == 0 { return 0 }
            var sum: Float = 0, cnt = 0
            var i = 0
            while i < n {
                let v = Float(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) / 32768
                sum += v * v; cnt += 1; i += 2
            }
            return (sum / Float(max(1, cnt))).squareRoot()
        }
    }

    /// 소리가 나면 붙고, 한동안 조용하면 연결만 닫는다 (Soniox 는 보낸 시간만큼 과금된다)
    private func level(_ v: Float) {
        guard broadcasting, !paused else { return }
        if v > Self.wake {
            quietAt = Date()
            if conn == nil { connect() }
        } else if conn != nil && Date().timeIntervalSince(quietAt) > Self.quietSeconds {
            disconnect()
        }
    }

    private func connect() {
        let key = store.sonioxKey.trimmed
        guard conn == nil else { return }
        guard !key.isEmpty else { error = "설정에서 Soniox 키를 넣어 주세요."; redraw(); return }
        var cfg: [String: Any] = [
            "model": TLSoniox.model,
            "language_hints": [lang],
            "translation": ["type": "one_way", "target_language": "ko"],
            "enable_speaker_diarization": true,
            "enable_endpoint_detection": true
        ]
        if let ctx = TLSoniox.context(store.glossary(lang), withTranslation: true) { cfg["context"] = ctx }
        let c = TLSonioxConn(key: key, config: cfg)
        c.onTokens = { [weak self] toks in self?.take(toks) }
        c.onFinished = { [weak self, weak c] in
            guard let self, self.conn === c else { return }
            self.conn = nil; self.live = false; self.pump.attach(nil); self.redraw()
        }
        c.onError = { [weak self, weak c] code, msg in
            guard let self, self.conn === c else { return }
            self.conn = nil; self.live = false; self.pump.attach(nil)
            self.error = TLSoniox.errorText(code, msg)
            self.redraw()
        }
        conn = c
        live = true
        error = nil
        quietAt = Date()
        c.start()
        pump.attach(c)
        redraw()
    }

    private func disconnect() {
        guard let c = conn else { return }
        conn = nil
        live = false
        pump.attach(nil)
        c.stop()
        endLine()
    }

    private func reconnect() {
        guard conn != nil else { return }
        disconnect()
        connect()
    }

    private func who(_ spk: String?) -> Int {
        guard let s = spk, !s.isEmpty else { return cur?.who ?? lines.last?.who ?? 0 }
        if let i = speakers[s] { return i }
        let i = speakers.count
        speakers[s] = i
        return i
    }

    /// 지금 말하는 중인 사람 (확정 전 글자의 화자)
    @Published private(set) var pWho = 0

    private func take(_ tokens: [TLSoniox.Token]) {
        var ps = "", pd = ""
        for t in tokens {
            if t.text == "<end>" { endLine(); continue }
            if t.isFinal {
                if !t.isTranslation {
                    let w = who(t.speaker)
                    // 말하는 사람이 바뀌면 줄을 나눈다
                    if let c = cur, c.who != w, !c.src.trimmed.isEmpty { endLine() }
                    if cur == nil { cur = TLScreenLine(src: "", dst: "", who: w) }
                    cur?.src += t.text
                } else if cur != nil && !(cur?.src.isEmpty ?? true) {
                    cur?.dst += t.text
                } else if let id = lastID, let k = lines.firstIndex(where: { $0.id == id }) {
                    // 번역이 <end> 뒤에 늦게 오면 방금 끝난 줄에 붙인다
                    lines[k].dst += t.text
                }
            } else {
                if t.isTranslation { pd += t.text } else { ps += t.text; if cur == nil { pWho = who(t.speaker) } }
            }
        }
        pSrc = ps; pDst = pd
        if let c = cur { pWho = c.who }
        redraw()
    }

    private func endLine() {
        guard var c = cur else { return }
        c.src = c.src.trimmed; c.dst = c.dst.trimmed
        cur = nil
        if c.src.isEmpty && c.dst.isEmpty { return }
        lines.append(c)
        lastID = c.id
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        redraw()
    }

    // MARK: 그리기

    /// 지금 PIP 에 보일 줄들: 이전 대화 몇 줄 + 말하는 중인 줄
    var captionLines: [TLCaptionLine] {
        var out = lines.suffix(max(0, history)).map { TLCaptionLine(src: $0.src, dst: $0.dst, temp: false, who: $0.who) }
        let s = (cur?.src ?? "") + pSrc, t = (cur?.dst ?? "") + pDst
        if !s.trimmed.isEmpty || !t.trimmed.isEmpty { out.append(TLCaptionLine(src: s, dst: t, temp: true, who: pWho)) }
        return out
    }

    var message: (text: String, error: Bool)? {
        if let e = error { return (e, true) }
        if paused { return ("멈춤", false) }
        if captionLines.isEmpty { return (broadcasting ? "듣는 중…" : "", false) }
        return nil
    }

    /// 말이 들어올 때마다 그리면 버겁다. 0.12초에 한 번으로 묶는다.
    func redraw() {
        guard !drawPending else { return }
        drawPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.drawPending = false
            let size = self.canvas
            let view = TLCaptionView(lines: self.captionLines, message: self.message,
                                     showSrc: self.showSrc, scale: CGFloat(self.fontScale), wide: self.wide,
                                     font: self.captionFont, barColor: TLCaptionView.barColor(self.captionBar),
                                     spacing: CGFloat(self.captionSpacing))
                .frame(width: size.width, height: size.height)
            let r = ImageRenderer(content: view)
            r.scale = 3
            if let cg = r.cgImage { self.pip.show(cg) }
        }
    }
}

// MARK: 자막 (시안 B · 흐르는 말풍선)

struct TLCaptionLine {
    let src: String
    let dst: String
    let temp: Bool
    let who: Int
}

struct TLCaptionView: View {
    static let ink = Color(red: 0x19 / 255, green: 0x1f / 255, blue: 0x28 / 255)
    static let bar = Color(red: 0x31 / 255, green: 0x82 / 255, blue: 0xF6 / 255)

    let lines: [TLCaptionLine]
    let message: (text: String, error: Bool)?
    let showSrc: Bool
    let scale: CGFloat
    var wide = false
    var font = "default"
    var barColor: Color = TLCaptionView.bar
    var spacing: CGFloat = 1

    /// 띠 색 고르기 — 이름 → 색 (TLBarChoice 는 아래)
    static let barChoices: [TLBarChoice] = [
        TLBarChoice(id: "blue", color: Color(red: 0x31 / 255, green: 0x82 / 255, blue: 0xF6 / 255)),
        TLBarChoice(id: "green", color: Color(red: 0x0E / 255, green: 0x8A / 255, blue: 0x6F / 255)),
        TLBarChoice(id: "pink", color: Color(red: 0xE8 / 255, green: 0x5D / 255, blue: 0x9A / 255)),
        TLBarChoice(id: "orange", color: Color(red: 0xF0 / 255, green: 0x8A / 255, blue: 0x24 / 255)),
        TLBarChoice(id: "purple", color: Color(red: 0x7C / 255, green: 0x5C / 255, blue: 0xE6 / 255)),
        TLBarChoice(id: "black", color: Color(red: 0x19 / 255, green: 0x1f / 255, blue: 0x28 / 255))
    ]
    static func barColor(_ id: String) -> Color { barChoices.first { $0.id == id }?.color ?? bar }

    private var design: Font.Design {
        switch font {
        case "rounded": return .rounded
        case "serif": return .serif
        default: return .default
        }
    }

    /// 위 파란 띠 높이
    private var barH: CGFloat { wide ? 20 : 24 }
    /// PIP 창은 모서리가 둥글어서 오른쪽 위 끝에 두면 잘린다. 안쪽으로 들인다.
    private var logoInset: CGFloat { wide ? 26 : 20 }

    var body: some View {
        ZStack(alignment: .top) {
            Color.white
            VStack(alignment: .leading, spacing: 7 * spacing) {
                Spacer(minLength: 0)
                if let m = message {
                    if !m.text.isEmpty {
                        Text(m.text)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(m.error ? Color(red: 0xE5 / 255, green: 0x50 / 255, blue: 0x3A / 255) : Self.ink.opacity(0.45))
                    }
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        line(l, age: lines.count - 1 - i)
                    }
                }
            }
            .padding(.horizontal, wide ? 16 : 12)
            .padding(.top, barH + 10)
            .padding(.bottom, wide ? 10 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .mask(GeometryReader { g in
                let a = barH / max(1, g.size.height)
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: a),
                                       .init(color: .black, location: min(0.6, a + (wide ? 0.2 : 0.16))),
                                       .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            })
            // 위의 파란 띠, 오른쪽에 앱 아이콘
            HStack {
                Spacer()
                Image("logo")
                    .resizable()
                    .frame(width: barH - 9, height: barH - 9)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).stroke(Color.white.opacity(0.55), lineWidth: 1))
            }
            .padding(.trailing, logoInset)
            .frame(height: barH)
            .background(barColor)
        }
        .fontDesign(design)
        .environment(\.colorScheme, .light)
    }

    private func line(_ l: TLCaptionLine, age: Int) -> some View {
        let src = showSrc && !l.src.trimmed.isEmpty
        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(TLSpeaker.color(l.who))
                .frame(width: 7, height: 7)
                .padding(.top, (src ? 5 : 7) * scale)
            VStack(alignment: .leading, spacing: 1 + 2 * (spacing - 1)) {
                if src {
                    Text(l.src.trimmed)
                        .font(.system(size: 11 * scale, design: design))
                        .foregroundStyle(Self.ink.opacity(0.45))
                        .lineLimit(2)
                }
                Text(l.dst.trimmed.isEmpty ? "…" : l.dst.trimmed)
                    .font(.system(size: 15 * scale, weight: .semibold, design: design))
                    .foregroundStyle(l.temp ? Self.ink.opacity(0.45) : Self.ink)
                    .lineSpacing(max(0, 1 + 4 * (spacing - 1)))
            }
        }
        .opacity(age == 0 ? 1 : age == 1 ? 0.72 : 0.5)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: 화면 기록 시작 버튼

/// iOS 화면 기록 시트를 띄우는 시스템 버튼. 모양은 우리가 그리고, 시스템 버튼은 투명하게 위에 덮는다.
struct TLBroadcastPicker: UIViewRepresentable {
    static let extensionID = "com.kouga.kemotranslate.broadcast"

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        let p = RPSystemBroadcastPickerView(frame: .zero)
        p.preferredExtension = Self.extensionID
        p.showsMicrophoneButton = false
        p.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(p)
        NSLayoutConstraint.activate([
            p.leadingAnchor.constraint(equalTo: host.leadingAnchor), p.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            p.topAnchor.constraint(equalTo: host.topAnchor), p.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        DispatchQueue.main.async { Self.hideIcon(p) }
        return host
    }

    func updateUIView(_ v: UIView, context: Context) {
        if let p = v.subviews.first as? RPSystemBroadcastPickerView { Self.hideIcon(p) }
    }

    private static func hideIcon(_ p: RPSystemBroadcastPickerView) {
        for case let b as UIButton in p.subviews {
            b.setImage(nil, for: .normal)
            b.setImage(nil, for: .selected)
            b.imageView?.tintColor = .clear
            b.frame = p.bounds
            b.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
    }
}

struct TLBarChoice: Identifiable {
    let id: String
    let color: Color
}
