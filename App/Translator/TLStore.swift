import Foundation
import SwiftUI
import UIKit

// 번역기 설정·기록. 'tl.' 접두어를 붙여 둔다 (kemometro 와 한 앱이던 때부터 쓰던 키라 그대로 둔다).
// 키 이름은 translator.html 의 localStorage 키와 같게 맞춰서, 나중에 HTML 판 백업 파일을
// 그대로 가져올 수 있게 한다 (gemini_api_key → tl.gemini_api_key).

@MainActor
final class TLStore: ObservableObject {
    static let shared = TLStore()
    static let defaultModel = "gemini-3.6-flash"
    private let d = UserDefaults.standard
    private func k(_ key: String) -> String { "tl." + key }

    @Published var apiKey: String { didSet { d.set(apiKey.trimmed, forKey: k("gemini_api_key")); TLShare.publish() } }
    @Published var model: String { didSet { d.set(model.trimmed, forKey: k("gemini_model")); TLShare.publish() } }
    @Published var thinking: Bool { didSet { d.set(thinking, forKey: k("thinking")); TLShare.publish() } }
    @Published var priority: Bool { didSet { d.set(priority ? "1" : "0", forKey: k("gemini_priority")) } }
    @Published var autoDetect: Bool { didSet { d.set(autoDetect ? "1" : "0", forKey: k("auto_detect")) } }
    @Published var charName: String { didSet { d.set(charName, forKey: k("char_name")); _tones = nil } }
    /// 캐릭터 X 계정 — 프로필 사진을 얼굴로 쓴다 (@ 없이)
    @Published var charX: String {
        didSet { d.set(charX.trimmed.replacingOccurrences(of: "@", with: ""), forKey: k("char_x")); TLAvatar.shared.refresh() }
    }
    /// 직접 고른 얼굴 이미지 (data URL, HTML 판 custom_icon 과 같은 형식)
    @Published var customIcon: String {
        didSet { if customIcon.isEmpty { d.removeObject(forKey: k("custom_icon")) } else { d.set(customIcon, forKey: k("custom_icon")) } }
    }
    @Published var charPrompt: String { didSet { d.set(charPrompt, forKey: k("char_prompt_default")); TLShare.publish() } }
    @Published var sonioxKey: String { didSet { d.set(sonioxKey.trimmed, forKey: k("soniox_key")) } }
    /// 하단 탭 바 밑에 까는 색 (#RRGGBB). 기본은 번역기 아이콘 캐릭터의 붉은 색.
    @Published var barTint: String { didSet { d.set(barTint, forKey: k("bar_tint")) } }
    /// 번역 버튼 색. 비어 있으면 강조색(초록)을 따른다.
    @Published var buttonTint: String { didSet { d.set(buttonTint, forKey: k("button_tint")) } }
    /// 스크롤하면 뜨는 쓰기(연필) 버튼 색. 기본은 번역기 아이콘 캐릭터의 노란색.
    @Published var writeTint: String { didSet { d.set(writeTint, forKey: k("write_tint")) } }
    /// 색 진하기 — 글래스 버튼과 하단 바 깔개에 같이 쓴다 (연하게 0.45 · 보통 0.7 · 진하게 1)
    /// 색 진하기 — 색마다 따로 (0.1 단위, 0.1~1)
    @Published var barStrength: Double { didSet { d.set(barStrength, forKey: k("bar_strength")) } }
    @Published var buttonStrength: Double { didSet { d.set(buttonStrength, forKey: k("button_strength")) } }
    @Published var writeStrength: Double { didSet { d.set(writeStrength, forKey: k("write_strength")) } }
    /// 새로 그린 글래스(하단 바·쓰기/번역 버튼)의 종류 — 맑은(true) · 일반(false)
    @Published var glassClear: Bool { didSet { d.set(glassClear, forKey: k("glass_clear")) } }
    /// 하단 바 아이콘 색 (바 색에 맞춰 바꾼다)
    @Published var tabIconTint: String { didSet { d.set(tabIconTint, forKey: k("tab_icon_tint")) } }
    /// 하단 바 아이콘 아래 이름 보이기
    @Published var tabLabels: Bool { didSet { d.set(tabLabels, forKey: k("tab_labels")) } }
    /// 말로 입력 엔진: device(기기 안) · soniox
    @Published var dictationEngine: String { didSet { d.set(dictationEngine, forKey: k("dictation_engine")) } }
    @Published var ttsModel: String { didSet { d.set(ttsModel.trimmed, forKey: k("gemini_tts_model")) } }
    @Published var ttsVoice: String { didSet { d.set(ttsVoice, forKey: k("gemini_tts_voice")) } }
    @Published var ttsStyle: String { didSet { d.set(ttsStyle, forKey: k("gemini_tts_style")) } }
    @Published var imageModel: String { didSet { d.set(imageModel.trimmed, forKey: k("gemini_image_model")) } }
    @Published var imageSize: String { didSet { d.set(imageSize, forKey: k("image_out_size")) } }
    @Published private(set) var history: [HistoryItem] = []
    /// 화면을 다시 그리게 하는 신호 (용어집·금지어·칩·말투가 바뀌었을 때)
    @Published private(set) var revision = 0

    private init() {
        apiKey = d.string(forKey: "tl.gemini_api_key") ?? ""
        model = d.string(forKey: "tl.gemini_model") ?? ""
        thinking = d.bool(forKey: "tl.thinking")
        priority = d.string(forKey: "tl.gemini_priority") == "1"
        autoDetect = d.string(forKey: "tl.auto_detect") != "0"
        // 캐릭터 이름·프롬프트는 처음엔 비워 두고 사용자가 적는다
        charName = d.string(forKey: "tl.char_name") ?? ""
        charX = d.string(forKey: "tl.char_x") ?? ""
        customIcon = d.string(forKey: "tl.custom_icon") ?? ""
        charPrompt = d.string(forKey: "tl.char_prompt_default") ?? ""
        sonioxKey = d.string(forKey: "tl.soniox_key") ?? ""
        dictationEngine = d.string(forKey: "tl.dictation_engine") ?? "device"
        barTint = d.string(forKey: "tl.bar_tint") ?? TLStore.defaultBarTint
        buttonTint = d.string(forKey: "tl.button_tint") ?? ""
        writeTint = d.string(forKey: "tl.write_tint") ?? TLStore.defaultWriteTint
        // 예전엔 진하기가 하나였다 — 있으면 그 값에서 시작한다
        let old = d.object(forKey: "tl.tint_strength") as? Double
        barStrength = d.object(forKey: "tl.bar_strength") as? Double ?? ((old ?? 1) * 0.8 * 10).rounded() / 10
        buttonStrength = d.object(forKey: "tl.button_strength") as? Double ?? ((old ?? 1) * 10).rounded() / 10
        writeStrength = d.object(forKey: "tl.write_strength") as? Double ?? ((old ?? 1) * 10).rounded() / 10
        glassClear = d.object(forKey: "tl.glass_clear") as? Bool ?? true
        tabIconTint = d.string(forKey: "tl.tab_icon_tint") ?? "#FFFFFF"
        tabLabels = d.object(forKey: "tl.tab_labels") as? Bool ?? true
        ttsModel = d.string(forKey: "tl.gemini_tts_model") ?? ""
        ttsVoice = d.string(forKey: "tl.gemini_tts_voice") ?? "Kore"
        ttsStyle = d.string(forKey: "tl.gemini_tts_style") ?? "natural"
        imageModel = d.string(forKey: "tl.gemini_image_model") ?? ""
        let legacy = ["512x512": "512", "1024x1024": "1K", "2048x2048": "2K"]
        let size = d.string(forKey: "tl.image_out_size")?.trimmed ?? ""
        imageSize = TLStore.imageSizesAccepted.contains(legacy[size] ?? size) ? (legacy[size] ?? size) : "1K"
        history = Self.decode([HistoryItem].self, d.data(forKey: "tl.trans_history")) ?? []
    }

    var effectiveModel: String { model.trimmed.isEmpty ? Self.defaultModel : model.trimmed }
    static let defaultBarTint = "#BC2448"
    static let defaultWriteTint = "#F2B84B"
    static let defaultTTSModel = "gemini-3.1-flash-tts-preview"
    static let defaultImageModel = "gemini-3.1-flash-image"
    /// 이 API는 '가로x세로'가 아니라 크기 등급을 받는다
    static let imageSizes = ["512", "1K", "2K", "4K"]
    static let imageSizesAccepted = ["512", "512P", "512PX", "1K", "2K", "4K"]
    var effectiveTTSModel: String { ttsModel.trimmed.isEmpty ? Self.defaultTTSModel : ttsModel.trimmed }
    var effectiveImageModel: String { imageModel.trimmed.isEmpty ? Self.defaultImageModel : imageModel.trimmed }
    var hasKey: Bool { !apiKey.trimmed.isEmpty }

    private static func decode<T: Decodable>(_ t: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(t, from: data)
    }
    private func bump() { revision &+= 1 }

    // MARK: 기록

    /// 공부 출제 참고·용어집 제안도 여기서 뽑는다. 200개까지.
    func saveHistory(src: String, tgt: String, srcLang: String, tgtLang: String) {
        let cfg = TLLang.cfg(tgtLang)
        let item = HistoryItem(src: String(src.prefix(200)), tgt: String(tgt.prefix(200)),
                               srcName: srcLang == "ko" ? "한국어" : cfg.label,
                               tgtName: srcLang == "ko" ? cfg.label : "한국어",
                               ts: Date().timeIntervalSince1970 * 1000)
        history.insert(item, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        d.set(try? JSONEncoder().encode(history), forKey: k("trans_history"))
    }

    /// 백업을 불러온 뒤 저장소의 기록을 다시 읽는다. 안 그러면 다음 번역이 옛 기록으로 덮어쓴다.
    func reloadHistory() {
        history = Self.decode([HistoryItem].self, d.data(forKey: "tl.trans_history")) ?? []
    }

    func clearHistory() {
        history = []
        d.removeObject(forKey: k("trans_history"))
    }

    // MARK: 용어집·금지어 (대상 언어별)

    func glossary(_ lang: String) -> [GlossaryPair] { Glossary.parse(d.string(forKey: k("glossary_" + lang)) ?? "") }
    func setGlossary(_ list: [GlossaryPair], lang: String) {
        let s = Glossary.serialize(list)
        if s.isEmpty { d.removeObject(forKey: k("glossary_" + lang)) } else { d.set(s, forKey: k("glossary_" + lang)) }
        bump()
        TLShare.publish()
    }
    func banned(_ lang: String) -> String { d.string(forKey: k("banned_" + lang)) ?? "" }
    func setBanned(_ s: String, lang: String) {
        if s.trimmed.isEmpty { d.removeObject(forKey: k("banned_" + lang)) } else { d.set(s, forKey: k("banned_" + lang)) }
        bump()
        TLShare.publish()
    }
    func glossarySkip(_ lang: String) -> [String] {
        Self.decode([String].self, d.string(forKey: k("glossary_skip_" + lang))?.data(using: .utf8)) ?? []
    }
    func addGlossarySkip(_ key: String, lang: String) {
        var s = glossarySkip(lang); s.append(key)
        if let data = try? JSONEncoder().encode(Array(s.suffix(200))) { d.set(String(data: data, encoding: .utf8), forKey: k("glossary_skip_" + lang)) }
        bump()
    }

    // MARK: 말투

    private var _tones: [Tone]?
    var tones: [Tone] {
        if let t = _tones { return t }
        var list = Self.decode([Tone].self, d.string(forKey: k("custom_tones"))?.data(using: .utf8)) ?? TLPrompt.defaultTones
        if let i = list.firstIndex(where: { $0.id == "character" }) { list[i].name = TLPrompt.characterToneName(charName) }
        _tones = list
        return list
    }
    func setTones(_ list: [Tone]) {
        if let data = try? JSONEncoder().encode(list) { d.set(String(data: data, encoding: .utf8), forKey: k("custom_tones")) }
        _tones = nil
        bump()
    }
    func resetTones() { d.removeObject(forKey: k("custom_tones")); _tones = nil; bump() }

    // MARK: 피드백 칩 (결과 언어별)

    func chips(_ outLang: String) -> [FbChip] {
        if let list = Self.decode([FbChip].self, d.string(forKey: k("fb_chips_" + outLang))?.data(using: .utf8)) {
            return list.filter { !$0.label.isEmpty && !$0.prompt.isEmpty }
        }
        return (TLPrompt.fbPresets[outLang] ?? TLPrompt.fbPresets["ko"]!).map { FbChip(label: $0.0, prompt: $0.1) }
    }
    func setChips(_ list: [FbChip], outLang: String) {
        if let data = try? JSONEncoder().encode(list) { d.set(String(data: data, encoding: .utf8), forKey: k("fb_chips_" + outLang)) }
        bump()
    }
    func resetChips(_ outLang: String) { d.removeObject(forKey: k("fb_chips_" + outLang)); bump() }
}

// MARK: 색

extension Color {
    /// 번역기 액센트 — HTML 판의 #0E8A6F / 다크 #3ECBA8
    static let tlAccent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x3E / 255, green: 0xCB / 255, blue: 0xA8 / 255, alpha: 1)
        : UIColor(red: 0x0E / 255, green: 0x8A / 255, blue: 0x6F / 255, alpha: 1) })
    static let tlAccentDark = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x6F / 255, green: 0xE0 / 255, blue: 0xC4 / 255, alpha: 1)
        : UIColor(red: 0x0B / 255, green: 0x6E / 255, blue: 0x58 / 255, alpha: 1) })
    static let tlOnAccent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x04 / 255, green: 0x23 / 255, blue: 0x1B / 255, alpha: 1) : .white })
    static let tlBg = Color(UIColor.systemGroupedBackground)
    static let tlCard = Color(UIColor.secondarySystemGroupedBackground)
    static let tlFill = Color(UIColor.tertiarySystemFill)
    static let tlRed = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1, green: 0x7A / 255, blue: 0x5C / 255, alpha: 1)
        : UIColor(red: 0xC1 / 255, green: 0x45 / 255, blue: 0x2A / 255, alpha: 1) })
}
