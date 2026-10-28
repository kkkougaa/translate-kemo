import Foundation

// 프롬프트. translator.html 의 LANG_CONFIG · DEFAULT_TONES · buildPrompt 를 글자 그대로 옮겼다.

struct LangConfig {
    let label: String
    let placeholder: String
    let resultLabel: String
    let toneInstr: [String: String]
}

enum TLLang {
    static let order = ["ja", "en", "zh-cn", "zh-tw"]

    static let config: [String: LangConfig] = [
        "ja": LangConfig(
            label: "日本語", placeholder: "翻訳する日本語を入力してください...", resultLabel: "일본어 결과",
            toneInstr: [
                "formal": "원문보다 한 단계 더 정중하고 조심스러운 일본어로 번역하세요. 「～ます」「～です」수준의 자연스러운 정중체를 사용하되, 「～でございます」같은 과도한 경어는 피하세요.",
                "young_male": "20대 일본 남성이 친한 친구에게 말하듯 번역하세요. 격식 없는 편한 반말(～じゃん、～だよ、～ね、～けど 등)을 사용하고, 1인칭은 「俺」또는「僕」를 문맥에 맞게 사용하세요.",
                "none": "원문의 말투와 어조를 그대로 살려 일본어로 번역하세요. 1인칭이 필요한 경우 「僕(ぼく)」를 기본으로 사용하세요.",
                "adult": "성적인 내용을 번역합니다. 일본에서 실제로 사용하는 성적 은어와 속어를 자연스럽고 적극적으로 사용하세요."
            ]),
        "en": LangConfig(
            label: "English", placeholder: "Enter text to translate...", resultLabel: "영어 결과",
            toneInstr: [
                "formal": "Translate in a polite and formal tone. Use respectful, professional English suitable for formal occasions.",
                "young_male": "Translate in a casual, friendly tone like a young person talking to a close friend. Use informal expressions, contractions, and everyday slang naturally.",
                "none": "Translate preserving the original tone and nuance naturally.",
                "adult": "This is adult content. Translate using real sexual slang and explicit expressions commonly used in English-speaking countries, naturally and directly."
            ]),
        "zh-cn": LangConfig(
            label: "中文(简体)", placeholder: "请输入要翻译的文字...", resultLabel: "중국어(간체) 결과",
            toneInstr: [
                "formal": "请用正式、礼貌的语气翻译，使用尊重对方的表达方式。",
                "young_male": "请用20多岁男性和朋友说话的轻松口语语气翻译，使用自然随意的表达。",
                "none": "请保留原文的语气和语调进行自然翻译。",
                "adult": "这是成人内容。请使用中文真实的性俚语和粗俗表达，自然且直接地翻译。"
            ]),
        "zh-tw": LangConfig(
            label: "中文(繁體)", placeholder: "請輸入要翻譯的文字...", resultLabel: "중국어(번체) 결과",
            toneInstr: [
                "formal": "請用正式、有禮貌的語氣翻譯，使用尊重對方的表達方式。",
                "young_male": "請用20多歲男性和朋友說話的輕鬆口語語氣翻譯，使用自然隨意的表達。",
                "none": "請保留原文的語氣和語調進行自然翻譯。",
                "adult": "這是成人內容。請使用繁體中文真實的性俚語和粗俗表達，自然且直接地翻譯。"
            ])
    ]

    static func cfg(_ lang: String) -> LangConfig { config[lang] ?? config["ja"]! }
}

// 기록·칩은 공유 확장에서도 쓴다 (TLStore 없이)
struct HistoryItem: Codable, Hashable, Identifiable {
    var src: String
    var tgt: String
    var srcName: String
    var tgtName: String
    var ts: Double
    var id: String { "\(ts)|\(src)" }
}

struct FbChip: Codable, Hashable, Identifiable {
    var label: String
    var prompt: String
    var id: String { label + "|" + prompt }
}

struct Tone: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var prompt: String
}

enum TLPrompt {
    static let defaultTones: [Tone] = [
        Tone(id: "formal", name: "정중하게", prompt: "원문보다 한 단계 더 정중하고 조심스러운 말투로 번역하세요. 자연스러운 정중체를 사용하되, 과도한 경어는 피하세요. 원문이 이미 반말이라도 정중하게 올려서 번역하세요."),
        Tone(id: "young_male", name: "20대 남성 말투", prompt: "20대 남성이 친한 친구에게 말하듯 번역하세요. 격식 없는 편한 반말을 사용하고, 가볍고 자연스러운 구어체로 번역하세요."),
        Tone(id: "adult", name: "성인", prompt: "성적인 내용을 번역합니다. 해당 국가에서 사용하는 성적 은어를 자연스럽고 적극적으로 적용해주세요."),
        Tone(id: "character", name: "캐릭터 말투", prompt: "USE_CHAR_PROMPT")
    ]

    /// 캐릭터 이름 칸이 비어 있을 때 말투 칩에 쓰는 이름
    static func characterToneName(_ charName: String) -> String {
        let n = charName.trimmed
        return n.isEmpty ? "캐릭터 말투" : n + " 말투"
    }

    /// 피드백 칩 — 결과 언어별 기본 목록
    static let fbPresets: [String: [(String, String)]] = [
        "ko": [("반말로", "반말로 바꿔줘"), ("존댓말로", "존댓말로 바꿔줘"),
               ("더 짧게", "뜻은 그대로 두고 더 짧게 줄여줘"),
               ("더 자연스럽게", "더 자연스러운 표현으로 다듬어줘"),
               ("이모지 빼고", "이모지와 특수문자를 빼줘")],
        "ja": [("반말", "タメ口(반말)로 바꿔줘"), ("정중체", "丁寧語(ます・です체)로 바꿔줘"),
               ("겸양어", "謙譲語를 써서 한 단계 더 낮춰줘"),
               ("더 짧게", "뜻은 그대로 두고 더 짧게 줄여줘"),
               ("자연스럽게", "일본인이 실제로 쓰는 자연스러운 표현으로 다듬어줘"),
               ("이모지 빼고", "이모지와 특수문자를 빼줘")],
        "en": [("캐주얼", "Make it casual and friendly"), ("격식", "Make it formal and polite"),
               ("더 짧게", "뜻은 그대로 두고 더 짧게 줄여줘"),
               ("자연스럽게", "원어민이 실제로 쓰는 자연스러운 표현으로 다듬어줘")],
        "zh-cn": [("구어체", "구어체로 바꿔줘"), ("격식", "정중하고 격식 있는 표현으로 바꿔줘"),
                  ("더 짧게", "뜻은 그대로 두고 더 짧게 줄여줘")],
        "zh-tw": [("구어체", "구어체로 바꿔줘"), ("격식", "정중하고 격식 있는 표현으로 바꿔줘"),
                  ("더 짧게", "뜻은 그대로 두고 더 짧게 줄여줘")]
    ]

    static let rule3 = "3. 번역 결과 텍스트만 출력하세요. 설명, 주석, 그리고 읽는 법(로마자·발음·독음) 표기는 절대 붙이지 마세요. 원문에 없는 말을 지어내서 넣지 마세요. 특히 원문에 없던 영어 낱말을 끼워 넣지 마세요. (LINE, OK 처럼 그 언어에서 원래 그대로 쓰는 말은 괜찮습니다.) 용어집에 있는 말도 글자 하나까지 전부 옮기세요. 한 낱말을 반만 옮겨 두 언어가 섞인 말을 만들지 마세요."

    struct Context {
        var srcLang: String
        var tgtLang: String
        var tone: String
        var strict: Bool
        var extraOn: Bool
        var extraText: String
        var charPrompt: String
        var tones: [Tone]
        var glossary: [GlossaryPair]
        var bannedRaw: String
    }

    static func bannedInstr(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }.prefix(60)
        if lines.isEmpty { return "" }
        let items = lines.map { l -> String in
            let parts = RX.get("\\s*(?:->|→|=>)\\s*").stringByReplacingMatches(in: l, range: l.fullRange, withTemplate: "\u{1F}")
                .components(separatedBy: "\u{1F}")
            return parts.count > 1 && !parts[1].isEmpty
                ? "- \(parts[0].trimmed) (대신 \(parts[1].trimmed))" : "- \(parts[0].trimmed)"
        }
        return "\n\n[금지 표현] 아래 표현은 번역문에 쓰지 마세요. 괄호에 대신 쓸 표현이 있으면 그것을 쓰세요.\n"
            + items.joined(separator: "\n")
    }

    static func inlineInstr(_ reqs: [String]) -> String {
        if reqs.isEmpty { return "" }
        return "\n\n[이번 번역에만 적용할 요청]\n" + reqs.map { "- " + $0 }.joined(separator: "\n")
            + "\n이 요청은 위 번역 지침보다 우선합니다."
    }

    /// 일본어는 반각 부호가 섞이면 어색하다. 한국어→일본어일 때만 붙인다.
    static func punctInstr(_ c: Context) -> String {
        guard c.srcLang == "ko" && c.tgtLang == "ja" else { return "" }
        return "\n\n[문장부호] 일본어 번역에서는 모든 문장부호를 전각으로 쓰세요."
            + " （。、？！「」『』（）〜…・ 등. 반각 . , ? ! ( ) ~ 는 쓰지 마세요.）"
            + " 단 숫자와 영문자는 반각으로 쓰세요. 2026年, 7時, 100円, LINE, OK 처럼."
            + " ２０２６ 이나 ＬＩＮＥ 같은 전각 숫자·전각 알파벳은 쓰지 마세요."
    }

    static func build(_ input: String, _ c: Context) -> String {
        let parsed = TLText.parseInput(input)
        let text = parsed.body
        let inline = inlineInstr(parsed.reqs)
        let cfg = TLLang.cfg(c.tgtLang)
        let src = c.srcLang == "ko" ? "한국어" : cfg.label
        let tgt = c.srcLang == "ko" ? cfg.label : "한국어"
        let toKO = c.srcLang != "ko"
        let gl = Glossary.instr(text, pairs: c.glossary, toKO: toKO)
        let banned = bannedInstr(c.bannedRaw)

        if toKO {
            return """
            당신은 전문 번역가입니다.

            [번역 지침]
            1. 원문에 담긴 말투, 어조, 감정을 그대로 살려서 번역하세요. (반말이면 반말, 존댓말이면 존댓말, 거친 말투면 거칠게)
            2. 원문의 내용을 변경하지 말고 충실하게 번역하세요.
            \(rule3)\(gl)\(banned)\(inline)

            [원문]
            \(text)
            """
        }

        let none = cfg.toneInstr["none"] ?? ""
        var toneInstr = none
        if c.tone == "character" {
            // 캐릭터 프롬프트를 아직 안 적었으면 기본 말투로 옮긴다
            let p = c.charPrompt.trimmed
            if !p.isEmpty {
                toneInstr = none + " 단, 다음 캐릭터 설명에 맞는 말투로 번역하세요 (반드시 \(tgt)로 번역): \"\(p)\""
            }
        } else if c.tone != "none" {
            let custom = c.tones.first { $0.id == c.tone }
            let def = defaultTones.first { $0.id == c.tone }
            let userPrompt = (custom?.prompt).flatMap { $0 != "USE_CHAR_PROMPT" && !$0.isEmpty ? $0 : nil }
            // 기본 말투를 손대지 않았으면 언어별 전용 지시문을 쓴다
            let untouched = userPrompt == nil || (def != nil && userPrompt == def?.prompt)
            if untouched, let t = cfg.toneInstr[c.tone] {
                toneInstr = t
            } else if let up = userPrompt {
                toneInstr = none + " 단, 말투는 다음과 같이 해줘: " + up
            } else if c.tone == "adult" {
                toneInstr = cfg.toneInstr["adult"] ?? "성적인 내용을 번역합니다. 해당 언어에서 실제로 사용하는 성적 은어를 자연스럽고 적극적으로 사용하세요."
            }
        }

        let strict = c.strict
            ? "원문의 모든 단어, 표현, 뉘앙스를 빠짐없이 번역하세요. 내용 추가, 생략, 의역은 절대 하지 마세요. 단, 번역 대상 언어(\(tgt))에서 사용하지 않는 표현이나 단어가 있을 경우 알맞은 문맥으로 수정하세요. 변경한 내용이 있으면 번역문 맨 마지막에 \"---COMMENT---\" 구분자를 넣고 그 아래에 변경 이유를 간단히 적어주세요. 변경 없으면 구분자 없이 번역만 출력하세요."
            : "원문의 핵심 의미를 유지하되, 자연스럽고 읽기 좋은 표현으로 자유롭게 다듬어도 좋습니다."
        let extra = c.extraOn && !c.extraText.trimmed.isEmpty ? "\n4. 추가 요청: \(c.extraText.trimmed)" : ""

        return """
        당신은 전문 번역가입니다. \(src)를 \(tgt)로 번역해주세요.

        [번역 지침]
        1. \(toneInstr)
        2. \(strict)
        \(rule3)\(extra)\(gl)\(banned)\(punctInstr(c))\(inline)

        [원문]
        \(text)
        """
    }

    static func retryFix(_ base: String, strays: [String], words: [String], tgtName: String) -> String {
        var out = base + "\n\n[다시 요청]"
        if !strays.isEmpty {
            out += "\n앞선 번역에 \(tgtName)가 아닌 글자(\(strays.prefix(6).joined()))가 섞여 나왔습니다. "
                + "인명과 고유명사까지 모두 \(tgtName) 표기로 옮겨서, 번역문 전체를 \(tgtName)로만 작성하세요."
        }
        if !words.isEmpty {
            out += "\n앞선 번역에 원문에 없던 영어 단어(\(words.prefix(6).joined(separator: ", ")))가 끼어 있었습니다. "
                + "원문에 없는 말은 한 마디도 넣지 말고 다시 번역하세요."
        }
        return out
    }

    static func feedbackSystem(source: String, result: String) -> String {
        """
        당신은 번역 수정 도우미입니다. 아래는 원문과 번역 결과입니다.
        사용자의 수정 요청을 반드시 정확히 반영하세요.
        요청하지 않은 부분은 절대 바꾸지 마세요.
        수정된 번역 결과 텍스트만 출력하세요. 설명, 주석, 읽는 법(로마자·발음·독음) 표기는 절대 붙이지 마세요.

        [원문]
        \(source)

        [번역 결과]
        \(result)
        """
    }
}
