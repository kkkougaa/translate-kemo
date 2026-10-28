import CoreText
import Foundation
import UIKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

// 기기 안에서 끝내는 일들 — API 를 안 쓰니 빠르고 공짜다.
// · 일본어 독음: iOS 형태소 분석기(CFStringTokenizer)가 주는 읽기 → 한글 표기 규칙
// · 사전·다른 언어 독음: iOS 26 기기 안 AI(Foundation Models). 못 쓰면 Gemini 로 넘긴다
// · 사진 속 글자 위치: Vision 글자 인식

enum TLLocal {

    // MARK: 기기 안 AI

    static var aiAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// 기기 안 AI 에 한 번 묻는다. 쓸 수 없으면 던진다 (부르는 쪽이 Gemini 로 넘긴다).
    static func ask(_ prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), aiAvailable {
            let session = LanguageModelSession()
            let r = try await session.respond(to: prompt)
            let out = r.content.trimmed
            if out.isEmpty { throw GeminiError(message: "결과를 가져오지 못했어요.") }
            return out
        }
        #endif
        throw GeminiError(message: "기기 안 AI 를 쓸 수 없어요.")
    }

    /// 기기 안 AI 먼저, 안 되면 Gemini
    @MainActor
    static func askLocalFirst(_ prompt: String, maxTokens: Int) async throws -> String {
        if aiAvailable, let out = try? await ask(prompt) { return out }
        let s = TLStore.shared
        guard s.hasKey else { throw GeminiError(message: "API 키를 설정해주세요.") }
        return try await Gemini.ask(model: s.effectiveModel, key: s.apiKey.trimmed, prompt: prompt, maxTokens: maxTokens)
    }

    // MARK: 일본어 독음

    /// "今日はいい天気ですね" → "今日はいい天気ですね (쿄-와 이이 텐키데스네)" — 줄마다
    static func japaneseReading(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmed
            if t.isEmpty || !t.rxTest("[\\u3040-\\u30FF\\u4E00-\\u9FFF]") { return line }
            let r = hangulReading(t)
            return r.isEmpty ? line : line + " (" + r + ")"
        }.joined(separator: "\n")
    }

    /// 낱말 뒤에 붙는 조사·어미 — 앞 낱말에 붙여 한 덩어리로 읽는다 (今日は → 쿄-와)
    private static let clitics: Set<String> = [
        "は", "が", "を", "に", "で", "と", "も", "へ", "の", "ね", "よ", "か", "な", "わ", "さ", "ぞ", "ぜ",
        "です", "ます", "でした", "ました", "ません", "でしょ", "でしょう", "だ", "だっ", "た", "て", "で", "ない",
        "なかっ", "たい", "れる", "られる", "せる", "させる", "う", "よう", "けど", "から", "まで", "より", "って",
        "じゃ", "しか", "ば", "たら", "なら", "ので", "のに", "ちゃ", "ん", "し", "ている", "てる", "でる"
    ]

    static func hangulReading(_ text: String) -> String {
        let ns = text as NSString
        let len = ns.length
        guard let tok = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: len),
                                                kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale) else { return "" }
        var groups: [String] = []
        var type = CFStringTokenizerAdvanceToNextToken(tok)
        while type.rawValue != 0 {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            let surface = ns.substring(with: NSRange(location: r.location, length: r.length))
            defer { type = CFStringTokenizerAdvanceToNextToken(tok) }
            // 문장부호·숫자·영문은 읽기를 안 단다
            if !surface.rxTest("[\\u3040-\\u30FF\\u4E00-\\u9FFF]") { continue }
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String
            var kana = surface.applyingTransform(.hiraganaToKatakana, reverse: true) ?? surface
            if surface.rxTest("[\\u4E00-\\u9FFF]"), let l = latin {
                let fixed = l.replacingOccurrences(of: "ā", with: "aa").replacingOccurrences(of: "ī", with: "ii")
                    .replacingOccurrences(of: "ū", with: "uu").replacingOccurrences(of: "ē", with: "ee")
                    .replacingOccurrences(of: "ō", with: "ou")
                kana = fixed.applyingTransform(.latinToHiragana, reverse: false) ?? kana
            }
            var h = kanaToHangul(kana)
            // 조사로 쓰인 は·へ·を 는 와·에·오로 읽는다
            if surface == "は" { h = "와" } else if surface == "へ" { h = "에" } else if surface == "を" { h = "오" }
            if h.isEmpty { continue }
            if clitics.contains(surface), !groups.isEmpty { groups[groups.count - 1] += h } else { groups.append(h) }
        }
        return groups.joined(separator: " ")
    }

    // MARK: 후리가나 (루비)

    private static let kanjiClass = "[\\u4E00-\\u9FFF\\u3400-\\u4DBF々〆ヶ]"

    /// 글을 [글, 읽기] 조각으로 나눈다. 한자가 있는 조각에만 읽기가 붙는다.
    static func rubySegments(_ text: String) -> [(text: String, ruby: String?)] {
        let ns = text as NSString
        let len = ns.length
        guard len > 0, let tok = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: len),
                                                          kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale) else {
            return [(text, nil)]
        }
        var out: [(text: String, ruby: String?)] = []
        var last = 0
        var type = CFStringTokenizerAdvanceToNextToken(tok)
        while type.rawValue != 0 {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            if r.location > last { out.append((ns.substring(with: NSRange(location: last, length: r.location - last)), nil)) }
            let surface = ns.substring(with: NSRange(location: r.location, length: r.length))
            last = r.location + r.length
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String
            type = CFStringTokenizerAdvanceToNextToken(tok)
            guard surface.rxTest(kanjiClass), let l = latin else { out.append((surface, nil)); continue }
            let fixed = l.replacingOccurrences(of: "ā", with: "aa").replacingOccurrences(of: "ī", with: "ii")
                .replacingOccurrences(of: "ū", with: "uu").replacingOccurrences(of: "ē", with: "ee")
                .replacingOccurrences(of: "ō", with: "ou")
            guard let reading = fixed.applyingTransform(.latinToHiragana, reverse: false), !reading.isEmpty else {
                out.append((surface, nil)); continue
            }
            out.append(contentsOf: align(surface, reading))
        }
        if last < len { out.append((ns.substring(from: last), nil)) }
        return out
    }

    /// 食べる(たべる) → [食|た][べる] — 가나 부분을 맞춰 한자에만 읽기를 붙인다
    private static func align(_ surface: String, _ reading: String) -> [(text: String, ruby: String?)] {
        var runs: [(String, Bool)] = []
        for ch in surface {
            let k = String(ch).rxTest(kanjiClass)
            if let lastRun = runs.last, lastRun.1 == k { runs[runs.count - 1].0 += String(ch) } else { runs.append((String(ch), k)) }
        }
        let hira = { (s: String) in s.applyingTransform(.hiraganaToKatakana, reverse: true) ?? s }
        var pattern = "^"
        for (t, k) in runs { pattern += k ? "(.+?)" : NSRegularExpression.escapedPattern(for: hira(t)) }
        pattern += "$"
        let target = hira(reading)
        guard let m = target.rxFirst(pattern) else { return [(surface, target)] }
        var out: [(text: String, ruby: String?)] = []
        var g = 1
        for (t, k) in runs {
            if k { out.append((t, (target as NSString).substring(with: m.range(at: g)))); g += 1 } else { out.append((t, nil)) }
        }
        return out
    }

    /// 루비가 달린 글. 복사할 땐 글자만 나가고 읽기는 따라가지 않는다 (속성일 뿐이라).
    static func rubyAttributed(_ text: String, font: UIFont, color: UIColor, lineSpacing: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let out = NSMutableAttributedString()
        for seg in rubySegments(text) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            if let r = seg.ruby {
                let rubyAttrs: [CFString: Any] = [kCTRubyAnnotationSizeFactorAttributeName: 0.5]
                let ann = CTRubyAnnotationCreateWithAttributes(.auto, .auto, .before, r as CFString, rubyAttrs as CFDictionary)
                attrs[NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)] = ann
            }
            out.append(NSAttributedString(string: seg.text, attributes: attrs))
        }
        return out
    }

    // MARK: 가나 → 한글

    private static let youon: [String: String] = [
        "きゃ": "캬", "きゅ": "큐", "きょ": "쿄", "しゃ": "샤", "しゅ": "슈", "しょ": "쇼", "ちゃ": "차", "ちゅ": "추", "ちょ": "초",
        "にゃ": "냐", "にゅ": "뉴", "にょ": "뇨", "ひゃ": "햐", "ひゅ": "휴", "ひょ": "효", "みゃ": "먀", "みゅ": "뮤", "みょ": "묘",
        "りゃ": "랴", "りゅ": "류", "りょ": "료", "ぎゃ": "갸", "ぎゅ": "규", "ぎょ": "교", "じゃ": "자", "じゅ": "주", "じょ": "조",
        "びゃ": "뱌", "びゅ": "뷰", "びょ": "뵤", "ぴゃ": "퍄", "ぴゅ": "퓨", "ぴょ": "표", "ぢゃ": "자", "ぢゅ": "주", "ぢょ": "조",
        "ふぁ": "화", "ふぃ": "휘", "ふぇ": "훼", "ふぉ": "훠", "てぃ": "티", "でぃ": "디", "とぅ": "투", "どぅ": "두",
        "うぃ": "위", "うぇ": "웨", "うぉ": "워", "ちぇ": "체", "しぇ": "셰", "じぇ": "제", "いぇ": "예", "ゔぁ": "바", "ゔぃ": "비"
    ]

    private static let mora: [Character: String] = [
        "あ": "아", "い": "이", "う": "우", "え": "에", "お": "오", "か": "카", "き": "키", "く": "쿠", "け": "케", "こ": "코",
        "が": "가", "ぎ": "기", "ぐ": "구", "げ": "게", "ご": "고", "さ": "사", "し": "시", "す": "스", "せ": "세", "そ": "소",
        "ざ": "자", "じ": "지", "ず": "즈", "ぜ": "제", "ぞ": "조", "た": "타", "ち": "치", "つ": "츠", "て": "테", "と": "토",
        "だ": "다", "ぢ": "지", "づ": "즈", "で": "데", "ど": "도", "な": "나", "に": "니", "ぬ": "누", "ね": "네", "の": "노",
        "は": "하", "ひ": "히", "ふ": "후", "へ": "헤", "ほ": "호", "ば": "바", "び": "비", "ぶ": "부", "べ": "베", "ぼ": "보",
        "ぱ": "파", "ぴ": "피", "ぷ": "푸", "ぺ": "페", "ぽ": "포", "ま": "마", "み": "미", "む": "무", "め": "메", "も": "모",
        "や": "야", "ゆ": "유", "よ": "요", "ら": "라", "り": "리", "る": "루", "れ": "레", "ろ": "로", "わ": "와", "を": "오",
        "ゔ": "부", "ぁ": "아", "ぃ": "이", "ぅ": "우", "ぇ": "에", "ぉ": "오", "ゃ": "야", "ゅ": "유", "ょ": "요", "ゎ": "와"
    ]

    /// 오-단 뒤의 う, 장음 기호는 '-' 로 (쿄-와)
    static func kanaToHangul(_ kanaIn: String) -> String {
        let kana = kanaIn.applyingTransform(.hiraganaToKatakana, reverse: true) ?? kanaIn
        let cs = Array(kana)
        var out = ""
        var lastVowel: Character = " "
        var i = 0
        func addJong(_ j: Int) {
            guard let last = out.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value),
                  (last.value - 0xAC00) % 28 == 0, let s = Unicode.Scalar(last.value + UInt32(j)) else {
                out += j == 4 ? "응" : "ㅅ"
                return
            }
            out.unicodeScalars.removeLast()
            out.unicodeScalars.append(s)
        }
        while i < cs.count {
            let c = cs[i]
            if i + 1 < cs.count, let y = youon[String(cs[i...i + 1])] {
                out += y; lastVowel = vowelOf(y); i += 2; continue
            }
            if c == "ん" { addJong(4); i += 1; continue }                  // ㄴ 받침
            if c == "っ" { addJong(19); i += 1; continue }                 // ㅅ 받침
            if c == "ー" || c == "〜" { out += "-"; i += 1; continue }
            if c == "う" && (lastVowel == "o" || lastVowel == "u") && !out.isEmpty { out += "-"; i += 1; continue }
            if let h = mora[c] { out += h; lastVowel = vowelOf(h) } else if c.isLetter || c.isNumber { out.append(c) }
            i += 1
        }
        return out
    }

    private static func vowelOf(_ h: String) -> Character {
        guard let s = h.unicodeScalars.last, (0xAC00...0xD7A3).contains(s.value) else { return " " }
        let jung = ((s.value - 0xAC00) / 28) % 21
        switch jung {
        case 0, 2: return "a"          // ㅏ ㅑ
        case 20, 1, 3: return "i"      // ㅣ (ㅐㅒ 는 거의 안 나온다)
        case 13, 17, 18: return "u"    // ㅜ ㅠ ㅡ
        case 5, 7: return "e"          // ㅔ ㅖ
        case 8, 12: return "o"         // ㅗ ㅛ
        default: return " "
        }
    }

    // MARK: 사진 속 글자 위치 (Vision)

    struct OCRLine { let text: String; let box: [Int] }   // box: ymin, xmin, ymax, xmax (0~1000)

    static func recognize(_ image: UIImage) async -> [OCRLine] {
        guard let cg = image.cgImage else { return [] }
        let orient = cgOrientation(image.imageOrientation)
        return await withCheckedContinuation { (cont: CheckedContinuation<[OCRLine], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                req.recognitionLanguages = ["ja-JP", "ko-KR", "zh-Hans", "zh-Hant", "en-US"]
                let handler = VNImageRequestHandler(cgImage: cg, orientation: orient, options: [:])
                do { try handler.perform([req]) } catch { cont.resume(returning: []); return }
                let out: [OCRLine] = (req.results ?? []).compactMap { o in
                    guard let s = o.topCandidates(1).first?.string.trimmed, !s.isEmpty else { return nil }
                    let b = o.boundingBox          // 0~1, 원점이 왼쪽 아래
                    let box = [Int((1 - b.maxY) * 1000), Int(b.minX * 1000), Int((1 - b.minY) * 1000), Int(b.maxX * 1000)]
                        .map { max(0, min(1000, $0)) }
                    return OCRLine(text: s, box: box)
                }
                cont.resume(returning: out)
            }
        }
    }

    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    /// 글자만 Gemini 에 보내 옮긴다 (사진을 안 보내니 빠르고 싸다). 같은 순서·같은 개수로 받는다.
    static func overlayTranslatePrompt(_ lines: [String], tgtName: String, glossary: String) -> String {
        let arr = (try? JSONSerialization.data(withJSONObject: lines)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        아래 JSON 배열의 글은 한 장의 이미지에서 위에서부터 읽어 낸 줄들이야. 각 줄을 \(tgtName)로 번역해줘.

        [규칙]
        1. 같은 순서, 같은 개수의 JSON 문자열 배열로만 답해.
        2. 줄들은 이어진 문맥이니 앞뒤를 보고 자연스럽게 옮겨. 그래도 줄을 합치거나 나누지는 마.
        3. 숫자와 고유명사는 바꾸지 마. 이미 \(tgtName)인 줄은 그대로 둬.\(glossary)

        \(arr)
        """
    }
}
