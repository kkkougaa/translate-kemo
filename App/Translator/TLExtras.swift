import AVFoundation
import Foundation
import SwiftUI
import UIKit

// 2단계 기능의 알맹이: 역번역 · 독음 · 사전 · 바꾸기 · 문법 · 맞춤법 · TTS · 이미지 번역.
// 프롬프트 문구는 translator.html 과 같다. 한쪽을 고치면 다른 쪽도 고친다.

enum TLExtras {

    // MARK: 역번역

    static func backTranslatePrompt(_ result: String) -> String {
        """
        다음 문장을 자연스러운 한국어로 번역하세요. 번역 결과 텍스트만 출력하세요.

        \(result)
        """
    }

    /// 한국어는 같은 뜻이어도 표현이 많이 달라지므로, 확실히 이상할 때만 알린다 (API 를 더 쓰지 않는다)
    static func normText(_ s: String) -> String {
        s.lowercased().rxReplace("[\\s\\d]", "").rxReplace("[.,!?~…\"'「」『』()\\[\\]·:;\\-]", "")
    }

    static func textSim(_ a0: String, _ b0: String) -> Double {
        let a = Array(normText(a0)), b = Array(normText(b0))
        if a.count < 2 || b.count < 2 { return 1 }
        func gram(_ s: [Character]) -> [String: Int] {
            var m: [String: Int] = [:]
            for i in 0..<(s.count - 1) { m[String(s[i]) + String(s[i + 1]), default: 0] += 1 }
            return m
        }
        let A = gram(a), B = gram(b)
        var inter = 0
        for (k, v) in A { if let w = B[k] { inter += min(v, w) } }
        return 2 * Double(inter) / Double((a.count - 1) + (b.count - 1))
    }

    /// 역번역과 원문을 기기 안에서 비교한다. 숫자가 어긋나면 그 숫자를 짚어 준다.
    static func divergence(source: String, bt: String) -> (message: String, marks: [String]) {
        let a = source.rxMatches("\\d[\\d,.]*"), b = bt.rxMatches("\\d[\\d,.]*")
        if a != b {
            let onlyA = a.filter { !b.contains($0) }, onlyB = b.filter { !a.contains($0) }
            func j(_ xs: [String]) -> String { xs.prefix(2).joined(separator: ", ") }
            let msg: String
            if !onlyA.isEmpty && !onlyB.isEmpty { msg = "원문은 \(j(onlyA))인데 번역은 \(j(onlyB))입니다." }
            else if !onlyA.isEmpty { msg = "원문의 \(j(onlyA))가 번역에서 빠졌습니다." }
            else if !onlyB.isEmpty { msg = "번역에 원문에 없는 \(j(onlyB))가 있습니다." }
            else { msg = "원문과 숫자의 순서가 다릅니다. 날짜·시간·금액을 확인해 주세요." }
            return (msg, Array(onlyB.prefix(4)))
        }
        if normText(source).count >= 20 && textSim(source, bt) < 0.18 {
            return ("역번역이 원문과 많이 다릅니다. 뜻이 바뀌지 않았는지 확인해 주세요.", [])
        }
        return ("", [])
    }

    // MARK: 독음

    static func pronPrompt(tgtName: String, text: String) -> String {
        """
        다음 \(tgtName) 텍스트의 한국어 독음(발음)을 표기해줘.
        각 문장/어절의 원문 옆에 괄호로 한국어 발음을 적어줘.
        예시: 今日はいい天気ですね (쿄-와 이이 텐키데스네)
        원문만 독음 형식으로 출력하고 설명은 하지 마.

        [원문]
        \(text)
        """
    }

    // MARK: 사전 · 바꾸기

    static func dictPrompt(word: String, langName: String) -> String {
        """
        "\(word)"(\(langName))의 사전 정보를 알려줘.
        다음 형식으로만 답해줘 (다른 설명 없이):
        읽기: (발음/읽는 법, 없으면 생략)
        뜻: (한국어로 간단한 뜻 1~3가지)
        예문: (짧은 예문 1개와 한국어 번역)
        """
    }

    static func parseDict(_ out: String) -> (reading: String, meaning: String) {
        var reading = "", meaning: [String] = []
        for l in out.components(separatedBy: "\n") where !l.trimmed.isEmpty {
            if l.hasPrefix("읽기:") { reading = String(l.dropFirst(3)).trimmed } else { meaning.append(l) }
        }
        return (reading, meaning.joined(separator: "\n").trimmed)
    }

    static func altPrompt(full: String, selection: String, request: String) -> String {
        """
        아래 [전체 문장] 안의 [선택 구간]을 [요청]대로 바꿔줘.

        [규칙]
        1. 선택 구간을 그대로 대체할 표현 하나만 출력해. 문장 전체를 다시 쓰지 마.
        2. 요청이 바꿀 표현 자체면 그대로 쓰고, 방향만 말한 거면 그 방향으로 알맞게 바꿔.
        3. 전체 문장의 문맥과 말투에 어울려야 해.
        4. 따옴표, 설명, 번호, 마크다운 없이 대체할 표현만 출력해.

        [전체 문장]
        \(full)

        [선택 구간]
        \(selection)

        [요청]
        \(request)
        """
    }

    static func cleanAlt(_ out: String) -> String {
        (out.components(separatedBy: "\n").first ?? "").trimmed
            .rxReplace("^[\"'\\u300c\\u300e]|[\"'\\u300d\\u300f]$", "")
    }

    // MARK: 문법 · 맞춤법

    static func grammarPrompt(_ text: String) -> String {
        """
        다음 일본어 문장의 문법과 자연스러움을 체크해줘.

        [체크 항목]
        1. 문법 오류가 있으면 올바른 표현으로 수정
        2. 문법은 맞지만 일본 일상 표현에서 어색한 부분이 있으면 자연스러운 표현으로 제안
        3. 전체적으로 자연스러운 표현인지 평가

        [출력 형식]
        - 원문: (입력 문장)
        - 수정 표현: (수정된 문장, 문제 없으면 "✓ 자연스러운 표현입니다" 출력)
        - 설명: (수정 이유 또는 간단한 코멘트를 한국어로)

        [입력 문장]
        \(text)
        """
    }

    static func grammarFeedbackSystem(_ result: String) -> String {
        """
        당신은 번역 수정 도우미입니다. 아래는 원문과 번역 결과입니다.
        사용자의 수정 요청을 반드시 정확히 반영하세요.
        요청하지 않은 부분은 절대 바꾸지 마세요.
        수정된 번역 결과 텍스트만 출력하세요. 설명, 주석, 읽는 법(로마자·발음·독음) 표기는 절대 붙이지 마세요.

        [번역/분석 결과]
        \(result)
        """
    }

    static func spellPrompt(_ text: String) -> String {
        """
        다음 한국어 텍스트의 맞춤법, 띄어쓰기, 문법 오류를 검사해주세요.

        [검사 규칙]
        1. 틀린 부분이 있으면 원문을 먼저 보여주고, 수정된 텍스트를 보여주세요.
        2. 어떤 부분이 왜 틀렸는지 간단히 설명해주세요.
        3. 틀린 부분이 없으면 "맞춤법 오류가 없습니다."라고 답해주세요.
        4. 마크다운 없이 일반 텍스트로 출력해주세요.

        [텍스트]
        \(text)
        """
    }

    // MARK: 이미지

    static func imagePlainPrompt(tgtName: String) -> String {
        "이 이미지에 있는 텍스트를 \(tgtName)로 번역해줘. 번역 결과 텍스트만 출력해."
    }

    static func overlayPrompt(tgtName: String) -> String {
        """
        이 이미지 안의 모든 글자를 찾아 \(tgtName)로 번역해줘.

        [규칙]
        1. 글자를 줄 또는 말풍선 단위로 묶어. 너무 잘게 쪼개지 마.
        2. box_2d 는 그 글자 덩어리를 감싸는 사각형이고 [ymin, xmin, ymax, xmax] 순서야.
           값은 이미지 크기를 0~1000 으로 정규화한 정수로 줘.
        3. src 에는 원문 그대로, dst 에는 \(tgtName) 번역을 넣어.
        4. 숫자와 고유명사는 바꾸지 마.
        """
    }

    static let overlaySchema: [String: Any] = {
        let box: [String: Any] = ["type": "ARRAY", "items": ["type": "INTEGER"]]
        let props: [String: Any] = ["box_2d": box, "src": ["type": "STRING"], "dst": ["type": "STRING"]]
        let item: [String: Any] = ["type": "OBJECT", "properties": props, "required": ["box_2d", "dst"]]
        return ["type": "ARRAY", "items": item]
    }()

    static func makeImagePrompt(tgtName: String) -> String {
        """
        이 이미지의 모든 글자를 \(tgtName)로 바꾼 이미지를 만들어줘.

        [중요 규칙]
        1. 글자의 위치, 폰트 모양, 크기, 굵기, 기울기, 색, 그림자, 테두리를 원본과 최대한 똑같이 재현해.
        2. 글자가 놓여 있던 배경(말풍선, 띠, 박스)도 원본 그대로 살려.
        3. 번역문 길이가 달라지면 글자 크기나 줄바꿈으로 맞춰. 박스를 함부로 키우지 마.
        4. 구도, 색감, 배경, 인물, 그림은 절대 바꾸지 마.
        5. 결과 이미지만 출력해.
        """
    }

    static func parseOverlay(_ raw: String) -> [OverlayItem] {
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            let nums = (o["box_2d"] as? [Any] ?? []).map { v -> Int in
                let n = (v as? NSNumber)?.doubleValue ?? Double("\(v)") ?? 0
                return max(0, min(1000, Int(n.rounded())))
            }
            guard nums.count == 4, nums[2] > nums[0], nums[3] > nums[1] else { return nil }
            let dst = ((o["dst"] as? String) ?? "").trimmed
            if dst.isEmpty { return nil }
            return OverlayItem(box: nums, src: ((o["src"] as? String) ?? "").trimmed, dst: dst)
        }
    }

    /// Gemini 비전이 실제로 쓰는 해상도가 긴 변 1568px 이라 그 이상은 보내도 의미가 없다
    static func prepare(_ image: UIImage) -> (data: Data, mime: String, image: UIImage)? {
        let maxEdge: CGFloat = 1568
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let long = max(px.width, px.height)
        var img = image
        if long > maxEdge {
            let r = maxEdge / long
            let size = CGSize(width: (px.width * r).rounded(), height: (px.height * r).rounded())
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        guard let data = img.jpegData(compressionQuality: 0.92) else { return nil }
        return (data, "image/jpeg", img)
    }

    /// 박스 자리의 평균색을 배경으로 쓰면 원문이 자연스럽게 덮인다
    static func boxColor(_ image: UIImage, _ b: [Int]) -> (bg: Color, fg: Color)? {
        guard let cg = image.cgImage else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let rect = CGRect(x: CGFloat(b[1]) / 1000 * W, y: CGFloat(b[0]) / 1000 * H,
                          width: max(1, CGFloat(b[3] - b[1]) / 1000 * W), height: max(1, CGFloat(b[2] - b[0]) / 1000 * H)).integral
        guard let crop = cg.cropping(to: rect) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))   // 1픽셀로 줄이면 그 영역 평균색이 된다
            return true
        }
        if !ok { return nil }
        let r = Double(px[0]) / 255, g = Double(px[1]) / 255, bl = Double(px[2]) / 255
        let lum = 0.299 * r + 0.587 * g + 0.114 * bl
        return (Color(red: r, green: g, blue: bl), lum > 0.58 ? Color(white: 0.07) : .white)
    }
}

struct OverlayItem: Identifiable, Hashable {
    let id = UUID()
    let box: [Int]       // ymin, xmin, ymax, xmax (0~1000)
    let src: String
    let dst: String
}

// MARK: TTS

struct TLTTSStyle: Hashable { let id: String; let name: String; let instr: String }
struct TLVoice: Hashable { let id: String; let desc: String }

enum TLTTS {
    /// Gemini TTS 는 SSML 을 안 받는다. "이렇게 읽어줘: 본문" 형태의 짧은 지시를 따른다.
    static let styles: [TLTTSStyle] = [
        TLTTSStyle(id: "natural", name: "자연스럽게", instr: "평소 대화하듯 편안하게, 문장 사이에 숨 쉬는 호흡을 자연스럽게 살려서 읽어줘. 낭독하듯 과장하지 말고:"),
        TLTTSStyle(id: "calm", name: "차분하게", instr: "차분하고 낮은 톤으로 천천히, 과장 없이 읽어줘:"),
        TLTTSStyle(id: "bright", name: "밝게", instr: "밝고 친근한 톤으로 편안하게 읽어줘. 들뜨지는 말고:"),
        TLTTSStyle(id: "clear", name: "또박또박", instr: "조금 천천히, 한 마디씩 또렷하게 읽어줘:"),
        TLTTSStyle(id: "none", name: "그대로", instr: "")
    ]

    static let voices: [TLVoice] = [
        TLVoice(id: "Zephyr", desc: "밝음"), TLVoice(id: "Puck", desc: "경쾌함"), TLVoice(id: "Charon", desc: "설명조"), TLVoice(id: "Kore", desc: "단단함"), TLVoice(id: "Fenrir", desc: "들뜸"),
        TLVoice(id: "Leda", desc: "앳됨"), TLVoice(id: "Orus", desc: "단단함"), TLVoice(id: "Aoede", desc: "산뜻함"), TLVoice(id: "Callirrhoe", desc: "느긋함"), TLVoice(id: "Autonoe", desc: "밝음"),
        TLVoice(id: "Enceladus", desc: "숨소리 섞임"), TLVoice(id: "Iapetus", desc: "또렷함"), TLVoice(id: "Umbriel", desc: "느긋함"), TLVoice(id: "Algieba", desc: "부드러움"),
        TLVoice(id: "Despina", desc: "부드러움"), TLVoice(id: "Erinome", desc: "또렷함"), TLVoice(id: "Algenib", desc: "거친 음색"), TLVoice(id: "Rasalgethi", desc: "설명조"),
        TLVoice(id: "Laomedeia", desc: "경쾌함"), TLVoice(id: "Achernar", desc: "여림"), TLVoice(id: "Alnilam", desc: "단단함"), TLVoice(id: "Schedar", desc: "평탄함"),
        TLVoice(id: "Gacrux", desc: "중후함"), TLVoice(id: "Pulcherrima", desc: "적극적"), TLVoice(id: "Achird", desc: "친근함"), TLVoice(id: "Zubenelgenubi", desc: "편안함"),
        TLVoice(id: "Vindemiatrix", desc: "차분함"), TLVoice(id: "Sadachbia", desc: "활기참"), TLVoice(id: "Sadaltager", desc: "박식함"), TLVoice(id: "Sulafat", desc: "따뜻함")
    ]

    static let samples: [String: String] = [
        "ja": "こんにちは。今日はいい天気ですね。",
        "en": "Hello. It is a really nice day today.",
        "zh-cn": "你好，今天天气真好。",
        "zh-tw": "你好，今天天氣真好。"
    ]

    static func prompt(_ text: String, style: String) -> String {
        let st = styles.first { $0.id == style } ?? styles[0]
        return st.instr.isEmpty ? text : st.instr + " " + text
    }

    /// 같은 문장을 다시 들을 때마다 새로 만들지 않도록 8개까지 기억해 둔다
    @MainActor private static var cache: [(key: String, wav: Data)] = []

    @MainActor static func cacheKey(_ text: String, voice: String) -> String {
        let s = TLStore.shared
        return s.effectiveTTSModel + "|" + voice + "|" + s.ttsStyle + "|" + text
    }

    @MainActor static func cached(_ text: String, voice: String) -> Bool {
        let k = cacheKey(text, voice: voice)
        return cache.contains { $0.key == k }
    }

    @MainActor static func synthesize(_ text: String, voice: String, style: String? = nil) async throws -> Data {
        let s = TLStore.shared
        let st = style ?? s.ttsStyle
        let key = s.effectiveTTSModel + "|" + voice + "|" + st + "|" + text
        if let hit = cache.first(where: { $0.key == key }) { return hit.wav }
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt(text, style: st)]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]]
            ] as [String: Any]
        ]
        let obj = try await Gemini.generate(model: s.effectiveTTSModel, key: s.apiKey.trimmed, body: body, timeout: 60)
        guard let audio = Gemini.inlineData(obj) else { throw GeminiError(message: "오디오를 받지 못했습니다.") }
        let wav = pcmToWav(audio.data, sampleRate: 24000)
        cache.append((key, wav))
        if cache.count > 8 { cache.removeFirst(cache.count - 8) }
        return wav
    }

    static func pcmToWav(_ pcm: Data, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let channels: UInt16 = 1, bits: UInt16 = 16
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(channels); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate) * UInt32(channels) * UInt32(bits) / 8); u16(channels * bits / 8); u16(bits)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

/// 소리 하나만 낸다. 새로 틀면 앞의 것은 멈춘다.
@MainActor
final class TLAudio: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = TLAudio()
    /// 지금 울리는 것의 이름 (결과 · 미리듣기)
    @Published private(set) var playing: String?
    private var player: AVAudioPlayer?

    func play(_ wav: Data, tag: String) throws {
        stop()
        // 무음 스위치를 켜 둬도 들리게
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = try AVAudioPlayer(data: wav)
        p.delegate = self
        p.play()
        player = p
        playing = tag
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player { self.player = nil; self.playing = nil }
        }
    }
}
