import Foundation
import SwiftUI
import UIKit

// 기기 안 번역 — 모델 파일 관리. 엔진과 프롬프트는 Shared/TLPlamoEngine.swift (확장도 같이 쓴다).
// 모델(GGUF)은 앱에 넣지 않는다. 이용자가 Hugging Face 에서 받은 .gguf 를 설정에서 가져오면
// 앱 그룹 폴더의 PLaMo/model.gguf 로 복사해 두고 쓴다 (iCloud 백업 제외).

@MainActor
final class TLPlamo: ObservableObject {
    static let shared = TLPlamo()
    private let d = UserDefaults.standard

    /// 가져온 파일의 원래 이름 (예: plamo-3-translate-2b-Q4_K_M.gguf)
    @Published private(set) var fileName: String
    @Published private(set) var fileSize: Int64 = 0
    @Published private(set) var importing = false
    @Published var message: String?

    static let collectionURL = URL(string: "https://huggingface.co/collections/pfnet/plamo-3-translate")!

    var installed: Bool { TLPlamoFiles.installed }
    /// 엔진이 들어 있고 모델도 있나
    var ready: Bool { TLPlamoEngine.compiled && installed }
    /// 이름에서 크기를 읽는다 (0.8b · 2b · 8b · 31b)
    var sizeLabel: String {
        let n = fileName.lowercased()
        for s in ["0.8b", "31b", "8b", "2b"] where n.contains("-" + s) { return s.uppercased() }
        return ""
    }

    private init() {
        fileName = d.string(forKey: "tl.plamo_file") ?? ""
        Self.migrate()
        refreshSize()
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { _ in
            TLPlamoEngine.shared.unload()
        }
    }

    /// 첫 버전은 앱 자신의 폴더에 뒀다 — 확장도 읽게 앱 그룹 폴더로 옮긴다 (같은 디스크라 금방)
    private static func migrate() {
        let fm = FileManager.default
        let old = TLPlamoFiles.legacyFolder.appendingPathComponent("model.gguf")
        let new = TLPlamoFiles.modelURL
        guard old != new, fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.createDirectory(at: TLPlamoFiles.folder, withIntermediateDirectories: true)
        if (try? fm.moveItem(at: old, to: new)) != nil { excludeFromBackup(new) }
    }

    nonisolated private static func excludeFromBackup(_ url: URL) {
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }

    private func refreshSize() {
        let a = try? FileManager.default.attributesOfItem(atPath: TLPlamoFiles.modelURL.path)
        fileSize = (a?[.size] as? NSNumber)?.int64Value ?? 0
        if !installed { fileName = "" }
        UserDefaults(suiteName: TLPlamoFiles.group)?.set(installed, forKey: "tl.plamo_ready")
    }

    /// 파일 앱에서 고른 .gguf 를 앱 안으로 복사한다. 1~2GB 라 백그라운드에서.
    func importModel(from url: URL) {
        guard !importing else { return }
        importing = true
        message = nil
        let name = url.lastPathComponent
        Task.detached(priority: .userInitiated) {
            let result: Result<Void, Error> = Result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // GGUF 파일은 'GGUF' 네 글자로 시작한다
                let h = try FileHandle(forReadingFrom: url)
                let magic = try h.read(upToCount: 4) ?? Data()
                try? h.close()
                guard magic == Data("GGUF".utf8) else {
                    throw GeminiError(message: "GGUF 파일이 아니에요. Hugging Face 의 …-GGUF 저장소에서 .gguf 파일을 받아 주세요.")
                }
                let fm = FileManager.default
                try fm.createDirectory(at: TLPlamoFiles.folder, withIntermediateDirectories: true)
                let tmp = TLPlamoFiles.folder.appendingPathComponent("incoming.gguf")
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: url, to: tmp)
                // 쓰던 모델을 내리고 바꿔 끼운다
                TLPlamoEngine.shared.cancelCurrent()
                TLPlamoEngine.shared.unload(wait: true)
                try? fm.removeItem(at: TLPlamoFiles.modelURL)
                try fm.moveItem(at: tmp, to: TLPlamoFiles.modelURL)
                TLPlamo.excludeFromBackup(TLPlamoFiles.modelURL)
            }
            await MainActor.run {
                let s = TLPlamo.shared
                s.importing = false
                switch result {
                case .success:
                    s.fileName = name
                    s.d.set(name, forKey: "tl.plamo_file")
                    s.message = "가져왔어요"
                    TLHaptic.done()
                case .failure(let e):
                    try? FileManager.default.removeItem(at: TLPlamoFiles.folder.appendingPathComponent("incoming.gguf"))
                    s.message = (e as? GeminiError)?.message ?? "가져오지 못했어요: " + e.localizedDescription
                    TLHaptic.error()
                }
                s.refreshSize()
            }
        }
    }

    func removeModel() {
        TLPlamoEngine.shared.cancelCurrent()
        TLPlamoEngine.shared.unload(wait: true)
        try? FileManager.default.removeItem(at: TLPlamoFiles.modelURL)
        fileName = ""
        d.removeObject(forKey: "tl.plamo_file")
        message = nil
        refreshSize()
    }
}

// MARK: 엔진 배지 (메인 화면 위 드롭다운)

/// 지금 번역 엔진 — Gemini 는 로고 + 이름, PLaMo 는 로고 글자
struct TLEngineBadge: View {
    let engine: String
    var height: CGFloat = 15

    var body: some View {
        if engine == "plamo" {
            Image("plamo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: height - 2)
                .accessibilityLabel("PLaMo")
        } else {
            HStack(spacing: 4) {
                Image("gemini")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: height, height: height)
                Text("Gemini")
                    .font(.system(size: height, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.primary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
