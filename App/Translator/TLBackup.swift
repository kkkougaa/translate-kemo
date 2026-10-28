import SwiftUI
import UniformTypeIdentifiers

// 백업 / 복원. HTML 판과 같은 파일을 주고받는다:
// { app: "kouga-translate", version: 1, exportedAt, data: { localStorage 키: 문자열 값 } }
// 네이티브는 같은 키에 'tl.' 를 붙여 UserDefaults 에 둔다. 값은 HTML 처럼 전부 문자열로 내보낸다.

enum TLBackup {
    static let keys: Set<String> = [
        "gemini_api_key", "soniox_key", "rt_refine", "gemini_priority", "gemini_model", "gemini_tts_model", "gemini_tts_voice",
        "gemini_image_model", "gemini_tts_style", "image_out_size", "custom_icon", "custom_tones",
        "char_name", "char_x", "char_prompt_default", "auto_detect", "result_size", "accent_color", "trans_history"
    ]
    /// study_ 는 공부 기능(표현 노트·오답·설정). 이게 빠지면 새 기기에서 노트가 통째로 사라진다.
    static let prefixes = ["glossary_", "banned_", "fb_chips_", "study_"]

    static func included(_ k: String) -> Bool {
        keys.contains(k) || prefixes.contains { k.hasPrefix($0) }
    }

    /// 네이티브에서 문자열이 아닌 모양으로 들고 있는 값
    private static func stringValue(_ v: Any) -> String? {
        switch v {
        case let s as String: return s
        case let d as Data: return String(data: d, encoding: .utf8)
        case let n as NSNumber:
            // Bool 은 HTML 처럼 "1"/"0"
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "1" : "0" }
            return n.stringValue
        default: return nil
        }
    }

    static func export() -> Data {
        var data: [String: String] = [:]
        for (key, v) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("tl.") {
            let k = String(key.dropFirst(3))
            if included(k), let s = stringValue(v) { data[k] = s }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: Any] = ["app": "kouga-translate", "version": 1,
                                      "exportedAt": iso.string(from: Date()), "data": data]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static var fileName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "kouga-translate-" + f.string(from: Date())
    }

    struct Parsed {
        let data: [String: String]
        let when: String
    }

    static func parse(_ raw: Data) throws -> Parsed {
        guard let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              obj["app"] as? String == "kouga-translate",
              let d = obj["data"] as? [String: Any] else {
            throw GeminiError(message: "이 앱의 백업 파일이 아니에요.")
        }
        var data: [String: String] = [:]
        for (k, v) in d { if let s = stringValue(v) { data[k] = s } }
        if data.isEmpty { throw GeminiError(message: "백업이 비어 있어요.") }
        return Parsed(data: data, when: String((obj["exportedAt"] as? String ?? "").prefix(10)))
    }

    /// 덮어쓴 뒤 열려 있는 화면들이 새 값을 읽게 한다
    @MainActor
    static func apply(_ p: Parsed) {
        let d = UserDefaults.standard
        for (k, v) in p.data {
            if k == "trans_history" {
                // 네이티브 기록은 JSON 데이터로 들고 있다. 모양이 안 맞는 줄은 건너뛴다.
                d.set(historyData(v), forKey: "tl.trans_history")
            } else {
                d.set(v, forKey: "tl." + k)
            }
        }
        let s = TLStore.shared
        s.apiKey = d.string(forKey: "tl.gemini_api_key") ?? s.apiKey
        s.model = d.string(forKey: "tl.gemini_model") ?? s.model
        s.priority = d.string(forKey: "tl.gemini_priority") == "1"
        s.autoDetect = d.string(forKey: "tl.auto_detect") != "0"
        s.charName = d.string(forKey: "tl.char_name") ?? s.charName
        s.charPrompt = d.string(forKey: "tl.char_prompt_default") ?? s.charPrompt
        s.sonioxKey = d.string(forKey: "tl.soniox_key") ?? s.sonioxKey
        // 얼굴·음성·이미지 설정도 바로 화면에 반영한다 (예전엔 앱을 다시 켜야 바뀌었다)
        s.charX = d.string(forKey: "tl.char_x") ?? s.charX
        s.customIcon = d.string(forKey: "tl.custom_icon") ?? s.customIcon
        s.ttsModel = d.string(forKey: "tl.gemini_tts_model") ?? s.ttsModel
        s.ttsVoice = d.string(forKey: "tl.gemini_tts_voice") ?? s.ttsVoice
        s.ttsStyle = d.string(forKey: "tl.gemini_tts_style") ?? s.ttsStyle
        s.imageModel = d.string(forKey: "tl.gemini_image_model") ?? s.imageModel
        if let size = d.string(forKey: "tl.image_out_size"), TLStore.imageSizesAccepted.contains(size) { s.imageSize = size }
        TLAvatar.shared.refresh()
        if let raw = p.data["custom_tones"], let data = raw.data(using: .utf8),
           let tones = try? JSONDecoder().decode([Tone].self, from: data) {
            s.setTones(tones)
        }
        // 메모리의 옛 기록이 남아 있으면 다음 번역 때 불러온 기록을 덮어쓴다
        s.reloadHistory()
        s.objectWillChange.send()
    }

    private static func historyData(_ raw: String) -> Data? {
        guard let data = raw.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let items: [HistoryItem] = arr.compactMap { h in
            guard let src = h["src"] as? String, let tgt = h["tgt"] as? String else { return nil }
            return HistoryItem(src: src, tgt: tgt,
                               srcName: h["srcName"] as? String ?? "",
                               tgtName: h["tgtName"] as? String ?? "",
                               ts: (h["ts"] as? NSNumber)?.doubleValue ?? 0)
        }
        return try? JSONEncoder().encode(Array(items.prefix(200)))
    }
}

struct TLBackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// 설정 화면 안에 들어가는 백업 칸
struct TLBackupSection: View {
    @State private var doc: TLBackupFile?
    @State private var exporting = false
    @State private var importing = false
    @State private var pending: TLBackup.Parsed?
    @State private var asking = false
    @State private var note = ""

    var body: some View {
        Section("백업") {
            Button("내보내기") {
                note = ""
                doc = TLBackupFile(data: TLBackup.export())
                exporting = true
            }
            Button("불러오기") {
                note = ""
                importing = true
            }
            if !note.isEmpty {
                Text(note).font(.system(size: 13)).foregroundStyle(Color.tlText2)
            }
        }
        .fileExporter(isPresented: $exporting, document: doc, contentType: .json,
                      defaultFilename: TLBackup.fileName) { result in
            if case .failure = result { note = "내보내기에 실패했어요." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    pending = try TLBackup.parse(try Data(contentsOf: url))
                    asking = true
                } catch {
                    note = error.localizedDescription
                }
            case .failure:
                note = "불러오기에 실패했어요."
            }
        }
        .alert("백업 불러오기", isPresented: $asking, presenting: pending) { p in
            Button("취소", role: .cancel) { pending = nil }
            Button("덮어쓰기", role: .destructive) {
                TLBackup.apply(p)
                pending = nil
                Haptics.light()
            }
        } message: { p in
            Text("\(p.when) 백업의 \(p.data.count)개 항목으로 덮어씁니다.\n지금 설정은 사라져요. 계속할까요?")
        }
    }
}
