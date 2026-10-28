import PhotosUI
import SwiftUI
import UIKit

// 캐릭터 얼굴. HTML 판과 같은 순서로 정한다:
// 직접 고른 이미지(tl.custom_icon, data URL) → X 계정 프로필(unavatar.io/twitter/<계정>) → 기본 사람 아이콘.
// 서랍 머리와 캐릭터 말투 칩에 쓴다.

@MainActor
final class TLAvatar: ObservableObject {
    static let shared = TLAvatar()
    @Published private(set) var image: UIImage?
    private var loadedFor = ""
    private var task: Task<Void, Never>?

    private var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("tl-avatar.img")
    }

    /// 설정이 바뀌면 부른다. 같은 설정이면 다시 받지 않는다.
    func refresh() {
        let s = TLStore.shared
        let key = s.customIcon.isEmpty ? "x:" + s.charX : "icon:" + String(s.customIcon.count) + s.customIcon.suffix(32)
        guard key != loadedFor else { return }
        loadedFor = key
        task?.cancel()
        if let data = Self.dataFromURL(s.customIcon), let im = UIImage(data: data) { image = im; return }
        let x = s.charX.trimmed
        guard !x.isEmpty, let url = URL(string: "https://unavatar.io/twitter/" + (x.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? x)) else {
            image = nil; return
        }
        // 지난번 받은 것을 먼저 보여 주고 새로 받는다
        let cacheKey = "tl.avatar_for"
        if UserDefaults.standard.string(forKey: cacheKey) == x, let u = cacheURL, let d = try? Data(contentsOf: u), let im = UIImage(data: d) {
            image = im
        } else {
            image = nil
        }
        let cache = cacheURL
        task = Task { [weak self] in
            guard let r = try? await URLSession.shared.data(from: url),
                  (r.1 as? HTTPURLResponse)?.statusCode == 200, let im = UIImage(data: r.0) else { return }
            let d = r.0
            guard !Task.isCancelled else { return }
            if let cache { try? d.write(to: cache) }
            UserDefaults.standard.set(x, forKey: cacheKey)
            self?.image = im
        }
    }

    static func dataFromURL(_ s: String) -> Data? {
        guard s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(s[s.index(after: comma)...]))
    }

    /// 고른 사진을 256px 로 줄여 data URL 로 (HTML 백업과 같은 형식)
    static func dataURL(from image: UIImage) -> String? {
        let side: CGFloat = 256
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let scale = side / min(w, h)
        let size = CGSize(width: w * scale, height: h * scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        guard let d = out.jpegData(compressionQuality: 0.85) else { return nil }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }
}

/// 둥근 캐릭터 얼굴. 없으면 사람 아이콘.
struct TLAvatarView: View {
    var size: CGFloat = 46
    var placeholderTint: Color = .tlText2
    @ObservedObject private var avatar = TLAvatar.shared

    var body: some View {
        Group {
            if let im = avatar.image {
                Image(uiImage: im).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(placeholderTint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear { avatar.refresh() }
    }
}

/// 설정 → 캐릭터: 이미지 고르기 · 지우기
struct TLAvatarPicker: View {
    @ObservedObject var store = TLStore.shared
    @State private var item: PhotosPickerItem?

    var body: some View {
        HStack(spacing: 12) {
            TLAvatarView(size: 52)
            PhotosPicker(selection: $item, matching: .images) {
                Text("이미지 선택")
            }
            if !store.customIcon.isEmpty {
                Button("지우기", role: .destructive) {
                    store.customIcon = ""
                    TLAvatar.shared.refresh()
                }
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .onChange(of: item) { _, it in
            guard let it else { return }
            Task {
                if let d = try? await it.loadTransferable(type: Data.self), let im = UIImage(data: d),
                   let url = TLAvatar.dataURL(from: im) {
                    store.customIcon = url
                    TLAvatar.shared.refresh()
                    TLHaptic.select()
                }
                item = nil
            }
        }
    }
}
