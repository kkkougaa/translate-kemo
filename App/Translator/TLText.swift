import Foundation

// 번역 결과 뒷정리와 검사. translator.html 의 같은 이름 함수를 그대로 옮겼다.
// 결과가 HTML 판과 어긋나면 안 되므로 규칙을 바꿀 땐 양쪽을 같이 고친다.

// MARK: 정규식

enum RX {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func get(_ pattern: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        let key = pattern + "|" + String(opts.rawValue)
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        let r = try! NSRegularExpression(pattern: pattern, options: opts)
        cache[key] = r
        return r
    }
}

extension String {
    var ns: NSString { self as NSString }
    var fullRange: NSRange { NSRange(location: 0, length: (self as NSString).length) }

    func rxTest(_ p: String, _ o: NSRegularExpression.Options = []) -> Bool {
        RX.get(p, o).firstMatch(in: self, range: fullRange) != nil
    }
    func rxReplace(_ p: String, _ template: String, _ o: NSRegularExpression.Options = []) -> String {
        RX.get(p, o).stringByReplacingMatches(in: self, range: fullRange, withTemplate: template)
    }
    func rxCount(_ p: String, _ o: NSRegularExpression.Options = []) -> Int {
        RX.get(p, o).numberOfMatches(in: self, range: fullRange)
    }
    func rxMatches(_ p: String, _ o: NSRegularExpression.Options = []) -> [String] {
        RX.get(p, o).matches(in: self, range: fullRange).map { ns.substring(with: $0.range) }
    }
    func rxFirst(_ p: String, _ o: NSRegularExpression.Options = []) -> NSTextCheckingResult? {
        RX.get(p, o).firstMatch(in: self, range: fullRange)
    }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// JS 의 trimStart
    var trimmedStart: String { rxReplace("^\\s+", "") }
    /// JS 의 trimEnd
    var trimmedEnd: String { rxReplace("\\s+$", "") }
}

// MARK: 문자 계열

enum Script: String { case hangul, kana, han, latin, cyril, greek, arabic, hebrew, thai, deva }

enum TLText {
    static func scriptOf(_ s: Unicode.Scalar) -> Script? {
        switch s.value {
        case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: return .hangul
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF: return .kana
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: return .han
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return .latin
        case 0x0400...0x04FF: return .cyril
        case 0x0370...0x03FF: return .greek
        case 0x0600...0x06FF, 0x0750...0x077F: return .arabic
        case 0x0590...0x05FF: return .hebrew
        case 0x0E00...0x0E7F: return .thai
        case 0x0900...0x097F: return .deva
        default: return nil     // 숫자·구두점·이모지는 언어를 안 가린다
        }
    }

    /// 그 언어 번역문에 섞여 있어도 이상하지 않은 문자 계열
    static let okScripts: [String: [Script]] = [
        "ja": [.kana, .han, .latin], "ko": [.hangul, .latin, .han], "en": [.latin],
        "zh-cn": [.han, .latin], "zh-tw": [.han, .latin]
    ]
    /// 그 언어가 주로 쓰는 문자 계열
    static let mainScripts: [String: [Script]] = [
        "ko": [.hangul], "ja": [.kana, .han], "en": [.latin], "zh-cn": [.han], "zh-tw": [.han]
    ]

    static let readingLangs: Set<String> = ["ja", "zh-cn", "zh-tw"]

    // MARK: 섞임 검사

    /// 사용자가 "이렇게 써 달라"고 넘긴 글(용어집·금지어·요청문·말투)에 있던 글자는 봐준다.
    /// 다만 원문 언어의 주 문자는 빼고 담는다 — 안 그러면 한글이 섞여도 못 잡는다.
    static func allowedExtraChars(srcLang: String, srcBody: String, pool: String) -> Set<Unicode.Scalar> {
        let main = mainScripts[srcLang] ?? []
        var out = Set<Unicode.Scalar>()
        for s in (pool + srcBody).unicodeScalars {
            if let sc = scriptOf(s), !main.contains(sc) { out.insert(s) }
        }
        return out
    }

    static func strayChars(_ text: String, tgtLang: String, allow: Set<Unicode.Scalar>) -> [String] {
        let ok = okScripts[tgtLang] ?? okScripts["ja"]!
        var out: [String] = []
        for s in text.unicodeScalars {
            guard let sc = scriptOf(s), !ok.contains(sc), !allow.contains(s) else { continue }
            let c = String(s)
            if !out.contains(c) { out.append(c) }
        }
        return out
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    /// 모델이 흘리는 영어는 대개 이 목록 안에 있다. 대소문자를 가리지 않고 잡는다.
    static let strayEN: Set<String> = words("""
        an the and or but nor so if then than that this these those there here where when what which who
        whom whose why how is are was were be been being am have has had having do does did doing will
        would shall should can could may might must not yes of in on at to for with from by about into
        over under after before until because since while during through without within between among
        against around already almost always never sometimes often usually still yet again just only
        even very quite much more most less really truly simply surely indeed instead besides therefore
        however anyway somehow although though maybe perhaps actually officially honestly basically
        seriously probably definitely totally literally obviously apparently certainly something
        anything everything nothing someone anyone everyone get got going come came know think want need
        like make made take say said see look feel
        """)

    /// 소문자 짧은 말이라도 일본어·한국어 글에 그냥 나오는 것들. 단위가 대부분이다.
    static let shortOK: Set<String> = words("""
        cm mm km kg mg ml cc kcal kw hz db fps dpi px pt em rem kb mb gb tb ver vol etc vs tel fax ok ng
        pc tv cd dvd bd bl gl sns url id qr mv pv ad bc orz lol rt dm
        """)

    static func strayWords(_ text: String, tgtLang: String, srcBody: String, pool userPool: String) -> [String] {
        if tgtLang == "en" { return [] }
        let body = text
            .rxReplace("https?://\\S+|\\S+@\\S+\\.\\S+", " ")
            // 「」『』 안은 작품 제목일 때가 많다
            .rxReplace("[「『《〈][^」』》〉]*[」』》〉]", " ")
        let pool = " " + (srcBody + " " + userPool).lowercased().rxReplace("[^a-z'’-]+", " ") + " "
        let nb = body as NSString
        var out: [String] = []
        for m in RX.get("[A-Za-z][A-Za-z'’-]*").matches(in: body, range: body.fullRange) {
            let w = nb.substring(with: m.range), low = w.lowercased()
            let before = String(nb.substring(to: m.range.location).rxReplace("[ \\t]+$", "").suffix(1))
            let after = String(nb.substring(from: m.range.location + m.range.length).rxReplace("^[ \\t]+", "").prefix(1))
            // 숫자에 붙어 있으면 단위다 (3cm, 9 am)
            if before.rxTest("[0-9０-９]") || after.rxTest("[0-9０-９]") { continue }
            // 확장자 · 멘션 · 해시태그
            if before == "." || before == "@" || before == "#" { continue }
            if pool.contains(" " + low + " ") { continue }
            if strayEN.contains(low) { if !out.contains(w) { out.append(w) }; continue }
            // 대문자가 섞이면 고유명사로 본다
            if !w.rxTest("^[a-z'’-]+$") { continue }
            if shortOK.contains(low) || low.rxTest("^w+$") { continue }
            if !out.contains(w) { out.append(w) }
        }
        return out
    }

    // MARK: 뒷정리

    static func latinRatio(_ t: String) -> Double {
        let latin = t.rxCount("[A-Za-z]")
        let letters = t.rxCount("[A-Za-z぀-ヿ一-鿿가-힣]")
        return letters > 0 ? Double(latin) / Double(letters) : 0
    }

    /// 로마자 표기는 단어마다 띄어 쓴다
    static func looksRomaji(_ t: String, minWords: Int) -> Bool {
        if t.rxTest("https?://|www\\.|@") { return false }
        return t.rxCount("[A-Za-z][ \\n][A-Za-z]") >= minWords
    }

    /// 번역문 뒤에 읽는 법을 덧붙여 오는 때가 있다. 모양으로 잡아 떼어낸다.
    static func stripReading(_ text: String, tgtLang: String) -> String {
        guard readingLangs.contains(tgtLang) else { return text }
        var out = text
        // 1) 마지막 문단이 통째로 괄호에 싸여 있고 로마자가 절반 넘으면 읽는 법이다
        for _ in 0..<2 {
            guard let m = out.rxFirst("\\n\\s*[(（]([\\s\\S]+?)[)）]\\s*$") else { break }
            let inner = out.ns.substring(with: m.range(at: 1))
            if (inner as NSString).length < 15 || latinRatio(inner) < 0.5 || !looksRomaji(inner, minWords: 2) { break }
            out = out.ns.substring(to: m.range.location).trimmedEnd
        }
        // 2) 빈 줄 하나 띄우고 붙이는 경우. 조건을 빡빡하게 둔다
        let parts = RX.get("\\n[ \\t]*\\n").stringByReplacingMatches(in: out, range: out.fullRange, withTemplate: "\u{1F}")
            .components(separatedBy: "\u{1F}")
        if parts.count > 1 {
            let last = parts[parts.count - 1]
            let head = parts.dropLast().joined(separator: "\n\n")
            let headJa = head.rxCount("[぀-ヿ一-鿿]")
            let lastLen = (last as NSString).length, headLen = (head as NSString).length
            if lastLen >= 15 && latinRatio(last) >= 0.7 && headJa >= 5
                && looksRomaji(last, minWords: 3) && Double(lastLen) >= Double(headLen) * 0.4 {
                out = head.trimmedEnd
            }
        }
        return out
    }

    /// 전각은 일본어와 기호만. 숫자와 영문자는 반각으로.
    static func toHalfWidth(_ text: String, tgtLang: String) -> String {
        guard readingLangs.contains(tgtLang) else { return text }
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            switch s.value {
            case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
                scalars.append(Unicode.Scalar(s.value - 0xFEE0)!)
            default:
                scalars.append(s)
            }
        }
        var out = String(scalars)
        for _ in 0..<4 {
            out = out.rxReplace("(\\d)[，](\\d)", "$1,$2").rxReplace("(\\d)[．](\\d)", "$1.$2")
        }
        return out
    }

    static func tidyOut(_ text: String, tgtLang: String) -> String {
        toHalfWidth(stripReading(text, tgtLang: tgtLang), tgtLang: tgtLang)
    }

    /// 모델 응답 끝의 빈 줄, 중간에 겹친 빈 줄을 정리한다
    static func cleanForCopy(_ t: String) -> String {
        t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .rxReplace("[ \\t]+$", "", .anchorsMatchLines)
            .rxReplace("\\n{3,}", "\n\n")
            .trimmed
    }

    // MARK: 코멘트·요청문

    static let commentSep = "---COMMENT---"

    /// 스트림 도중 구분자가 반쯤 들어온 꼬리도 숨긴다
    static func splitComment(_ full: String) -> (body: String, comment: String?) {
        if let r = full.range(of: commentSep) {
            return (String(full[..<r.lowerBound]), String(full[r.upperBound...]))
        }
        let n = min(commentSep.count - 1, full.count)
        if n > 0 {
            for k in stride(from: n, to: 0, by: -1) where commentSep.hasPrefix(String(full.suffix(k))) {
                return (String(full.dropLast(k)), nil)
            }
        }
        return (full, nil)
    }

    /// ((...)) 안의 글은 번역할 문장이 아니라 이번 번역에만 적용할 요청이다
    static func parseInput(_ text: String) -> (body: String, reqs: [String]) {
        var reqs: [String] = []
        let re = RX.get("\\(\\(([\\s\\S]*?)\\)\\)")
        let ns = text as NSString
        var body = ""
        var last = 0
        for m in re.matches(in: text, range: text.fullRange) {
            body += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + " "
            let inner = ns.substring(with: m.range(at: 1)).trimmed
            if !inner.isEmpty { reqs.append(inner) }
            last = m.range.location + m.range.length
        }
        body += ns.substring(from: last)
        body = body.rxReplace("[ \\t]{2,}", " ").rxReplace("[ \\t]*\\n[ \\t]*", "\n").trimmed
        return (body, reqs)
    }

    // MARK: 언어 감지

    /// 글자 종류 비율로 판별한다. 한자만 있으면 일본어/중국어 구분이 안 돼 foreign 으로만 본다.
    static func detectInputLang(_ text: String) -> String? {
        let t = text.rxReplace("\\s", "")
        if t.count < 2 { return nil }
        let hangul = t.rxCount("[\\uAC00-\\uD7A3\\u1100-\\u11FF\\u3130-\\u318F]")
        let kana = t.rxCount("[\\u3040-\\u309F\\u30A0-\\u30FF]")
        let han = t.rxCount("[\\u4E00-\\u9FFF\\u3400-\\u4DBF]")
        let latin = t.rxCount("[A-Za-z]")
        let total = Double(hangul + kana + han + latin)
        if total < 2 { return nil }
        if Double(hangul) / total > 0.2 { return "ko" }
        if kana > 0 { return "ja" }
        if Double(han) / total > 0.3 { return "foreign" }
        let words = text.rxCount("[A-Za-z][A-Za-z'’-]*")
        if Double(latin) / total > 0.6 && latin >= 8 && words >= 2 { return "en" }
        return nil
    }

    // MARK: 말투 추정 (API 를 더 쓰지 않는다)

    static func politeness(_ text: String, lang: String) -> String {
        let t = text.trimmed
        if t.isEmpty { return "" }
        if lang == "ja" {
            if t.rxTest("(でございます|いたします|申し上げ|くださいませ)") { return "격식체" }
            if t.rxTest("(です|ます|まし|ましょ|ません|でしょ|ください|ございま)") { return "정중체" }
            if t.rxTest("(だよ|だね|じゃん|だろ|かな|さ|ぜ|ぞ)[。！？]?\\s*$", .anchorsMatchLines) { return "반말" }
            return ""
        }
        if lang == "ko" {
            if t.rxTest("(습니다|습니까|십시오|드립니다|세요|예요|이에요|시죠|요[.!?]?\\s*$)", .anchorsMatchLines) { return "정중체" }
            if t.rxTest("[가-힣](야|어|지|다|래|자|니|군|네)[.!?]?\\s*$", .anchorsMatchLines) { return "반말" }
        }
        return ""
    }
}

// MARK: 용어집

struct GlossaryPair: Codable, Hashable, Identifiable {
    var from: String
    var to: String
    var id: String { from + "=" + to }
}

enum Glossary {
    /// 저장 형식은 HTML 판과 같은 '원문=번역' 줄 목록이다
    static func parse(_ raw: String) -> [GlossaryPair] {
        raw.components(separatedBy: "\n").compactMap { line in
            let p = line.components(separatedBy: "=")
            guard p.count >= 2 else { return nil }
            let from = p[0].trimmed, to = p.dropFirst().joined(separator: "=").trimmed
            return from.isEmpty || to.isEmpty ? nil : GlossaryPair(from: from, to: to)
        }.prefix(200).map { $0 }
    }

    static func serialize(_ list: [GlossaryPair]) -> String {
        list.filter { !$0.from.isEmpty && !$0.to.isEmpty }.map { $0.from + "=" + $0.to }.joined(separator: "\n")
    }

    /// 입력한 글에 실제로 등장하는 항목만 프롬프트에 붙인다
    static func instr(_ text: String, pairs: [GlossaryPair], toKO: Bool) -> String {
        let t = text.lowercased()
        let hits = pairs.filter { t.contains((toKO ? $0.to : $0.from).lowercased()) }
        if hits.isEmpty { return "" }
        let lines = hits.map { toKO ? "- \($0.to) → \($0.from)" : "- \($0.from) → \($0.to)" }
        return "\n\n[용어집] 아래 단어는 반드시 지정한 번역을 그대로 사용하세요.\n" + lines.joined(separator: "\n")
    }

    /// 프롬프트로 시켜도 모델이 원문 표기를 그대로 두거나(케모켓) 반만 옮긴다(ポ도くん).
    /// 결과가 나온 뒤에 직접 바꿔 끼운다.
    static func enforce(_ text: String, srcText: String, outLang: String, pairs all: [GlossaryPair], toKO: Bool) -> String {
        let t = srcText.lowercased()
        var pairs = all.map { toKO ? (src: $0.to, dst: $0.from) : (src: $0.from, dst: $0.to) }
            .filter { $0.src.count >= 2 && t.contains($0.src.lowercased()) }
        if pairs.isEmpty { return text }
        let ok = TLText.okScripts[outLang] ?? TLText.okScripts["ja"]!
        func foreign(_ c: Character) -> Bool {
            guard let s = c.unicodeScalars.first, let sc = TLText.scriptOf(s) else { return false }
            return !ok.contains(sc)
        }
        pairs.sort { $0.src.count > $1.src.count }
        var out = text
        for p in pairs {
            // ① 원문 표기가 그대로 남은 자리
            if p.src.rxTest("^[A-Za-z0-9 .'’-]+$") {
                let pat = "(^|[^A-Za-z])" + NSRegularExpression.escapedPattern(for: p.src) + "(?![A-Za-z])"
                let tmpl = "$1" + NSRegularExpression.escapedTemplate(for: p.dst)
                out = out.rxReplace(pat, tmpl, .caseInsensitive)
            } else {
                out = out.replacingOccurrences(of: p.src, with: p.dst)
            }
            // ② 반만 옮겨진 자리
            let dst = Array(p.dst), L = dst.count
            if L < 2 { continue }
            let need = (L + 1) / 2
            var chars = Array(out)
            var i = 0
            while i + L <= chars.count {
                let w = Array(chars[i..<(i + L)])
                if w != dst {
                    var same = 0, bad = false
                    for k in 0..<L {
                        if w[k] == dst[k] { same += 1 } else if !foreign(w[k]) { bad = true; break }
                    }
                    if !bad && same >= need {
                        chars.replaceSubrange(i..<(i + L), with: dst)
                        i += L
                        continue
                    }
                }
                i += 1
            }
            out = String(chars)
        }
        return out
    }

    // MARK: 자동 제안 — 기록에서 "이 한국어 낱말이 나오면 이 가타카나가 같이 나온다"를 찾는다

    static let josa = ["이에요", "에서", "에게", "한테", "으로", "이랑", "하고", "까지", "부터", "처럼",
                       "보다", "이나", "이야", "예요", "께서", "이", "가", "은", "는", "을", "를", "에", "께", "로",
                       "와", "과", "랑", "도", "만", "의", "나", "야", "님"]
    static let stop: Set<String> = ["진짜", "정말", "너무", "완전", "대박", "그냥", "오늘", "내일", "어제",
                                    "지금", "우리", "이거", "그거", "저거", "여기", "거기", "근데", "그래서", "그리고", "아니", "나도", "너도"]
    static let kata = "[\\u30A1-\\u30FA][\\u30A1-\\u30FA\\u30FC]+(?:くん|ちゃん|さん|さま|様|たん)?"

    static func koTerms(_ text: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.components(separatedBy: RX.charSetNonHangul) where (2...10).contains(raw.count) {
            out.insert(raw)
            for j in josa where raw.count - j.count >= 2 && raw.hasSuffix(j) {
                out.insert(String(raw.dropLast(j.count)))
            }
        }
        return out
    }

    struct Suggestion: Hashable { let x: String; let k: String; let n: Int }

    static func suggest(srcText: String, history: [HistoryItem], tgtLabel: String,
                        pairs: [GlossaryPair], skip: [String]) -> [Suggestion] {
        if srcText.isEmpty { return [] }
        var seen = Set<String>()
        var rows: [(ko: Set<String>, ja: Set<String>)] = []
        for h in history where h.srcName == "한국어" && h.tgtName == tgtLabel && !seen.contains(h.src) {
            seen.insert(h.src)
            rows.append((koTerms(h.src), Set(h.tgt.rxMatches(kata))))
        }
        if rows.count < 2 { return [] }
        func knownKo(_ x: String) -> Bool { pairs.contains { $0.from == x || ($0.from.count >= 2 && ($0.from.contains(x) || x.contains($0.from))) } }
        func knownJa(_ k: String) -> Bool { pairs.contains { $0.to == k || ($0.to.count >= 2 && ($0.to.contains(k) || k.contains($0.to))) } }
        var kataTotal: [String: Int] = [:]
        for r in rows { for k in r.ja { kataTotal[k, default: 0] += 1 } }
        var best: [String: Suggestion] = [:]
        for x in koTerms(srcText) where !stop.contains(x) && !knownKo(x) {
            let withX = rows.filter { $0.ko.contains(x) }
            if withX.count < 2 { continue }
            var co: [String: Int] = [:]
            for r in withX { for k in r.ja { co[k, default: 0] += 1 } }
            for (k, n) in co {
                if n < 2 || knownJa(k) || skip.contains(x + "=" + k) { continue }
                if Double(n) / Double(withX.count) < 0.6 { continue }
                if Double(n) / Double(kataTotal[k] ?? 1) < 0.6 { continue }
                if let cur = best[k], !(n > cur.n || (n == cur.n && x.count > cur.x.count)) { continue }
                best[k] = Suggestion(x: x, k: k, n: n)
            }
        }
        var byX: [String: Suggestion] = [:]
        for v in best.values { if let cur = byX[v.x], cur.n >= v.n { continue }; byX[v.x] = v }
        return Array(byX.values.sorted { $0.n > $1.n }.prefix(2))
    }
}

extension RX {
    static let charSetNonHangul: CharacterSet = {
        var s = CharacterSet(charactersIn: "\u{AC00}"..."\u{D7A3}")
        s.invert()
        return s
    }()
}
