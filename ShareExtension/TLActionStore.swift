import Foundation
import UIKit

// 공유 시트·기본 번역 확장의 설정 읽기. 확장은 본 앱의 UserDefaults 를 못 읽는다.
//   1) 앱 그룹 UserDefaults (group.com.kouga.kemotranslate) — 본 앱이 써 둔다, 키 이름은 앱과 같은 "tl.*"
//   2) 확장 자신의 UserDefaults "ta.gemini_api_key" — 그룹에 키가 없으면 카드에서 한 번 붙여 넣는다

struct TLActionSettings {
    var apiKey = ""
    var model = ""
    var thinking = false
    var charPrompt = ""
    var lastTgt = "ja"
    /// 대상 언어별 용어집 원문 ('원문=번역' 줄)
    var glossary: [String: String] = [:]
    /// 대상 언어별 금지 표현 원문
    var banned: [String: String] = [:]

    static let defaultModel = "gemini-3.6-flash"
    var effectiveModel: String { model.trimmed.isEmpty ? Self.defaultModel : model.trimmed }
    var hasKey: Bool { !apiKey.trimmed.isEmpty }
}

enum TLActionStore {
    static let groupID = "group.com.kouga.kemotranslate"
    static let ownKey = "ta.gemini_api_key"
    static let langs = ["ja", "en", "zh-cn", "zh-tw"]

    static func load() -> TLActionSettings {
        if let s = fromGroup(), s.hasKey { return s }
        // 그룹에 키가 없으면 다른 설정이라도 살리고, 키만 확장 자신의 것을 쓴다
        var s = fromGroup() ?? TLActionSettings()
        s.apiKey = UserDefaults.standard.string(forKey: ownKey) ?? ""
        return s
    }

    static func saveOwnKey(_ key: String) {
        UserDefaults.standard.set(key.trimmed, forKey: ownKey)
    }

    private static func fromGroup() -> TLActionSettings? {
        guard let d = UserDefaults(suiteName: groupID) else { return nil }
        var s = TLActionSettings()
        s.apiKey = d.string(forKey: "tl.gemini_api_key") ?? ""
        s.model = d.string(forKey: "tl.gemini_model") ?? ""
        if let b = d.object(forKey: "tl.thinking") as? Bool { s.thinking = b }
        else { s.thinking = d.string(forKey: "tl.thinking") == "1" }
        s.charPrompt = d.string(forKey: "tl.char_prompt_default") ?? ""
        s.lastTgt = valid(d.string(forKey: "tl.last_tgt"))
        for l in langs {
            if let g = d.string(forKey: "tl.glossary_" + l), !g.isEmpty { s.glossary[l] = g }
            if let b = d.string(forKey: "tl.banned_" + l), !b.isEmpty { s.banned[l] = b }
        }
        return s
    }

    private static func valid(_ l: String?) -> String {
        guard let l, langs.contains(l) else { return "ja" }
        return l
    }
}
