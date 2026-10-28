import SwiftUI
import UIKit
import UniformTypeIdentifiers

// 공유 시트의 액션 줄에 뜨는 "translate-kemo". 전체 화면으로 받되 배경을 비워 두고,
// 어둡게 깐 막 위에 우리 카드를 아래에서 올린다. 막을 누르면 닫힌다.

final class ActionViewController: UIViewController {
    private let model = TLActionModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let root = TLActionView(m: model,
                                onClose: { [weak self] in self?.finish(nil) },
                                onReplace: { [weak self] text in self?.finish(text) })
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        loadText()
    }

    /// 고른 글을 꺼낸다. 메모·사파리처럼 글을 넘겨주는 앱은 attributedContentText 나 plainText 첨부로 준다.
    private func loadText() {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        for item in items {
            if let a = item.attributedContentText?.string, !a.trimmed.isEmpty {
                model.setText(a)
                return
            }
        }
        let type = UTType.plainText.identifier
        for item in items {
            for p in item.attachments ?? [] where p.hasItemConformingToTypeIdentifier(type) {
                p.loadItem(forTypeIdentifier: type, options: nil) { [weak self] obj, _ in
                    var s: String?
                    if let t = obj as? String { s = t }
                    else if let t = obj as? NSAttributedString { s = t.string }
                    else if let d = obj as? Data { s = String(data: d, encoding: .utf8) }
                    else if let u = obj as? URL { s = try? String(contentsOf: u, encoding: .utf8) }
                    DispatchQueue.main.async {
                        if let s, !s.trimmed.isEmpty { self?.model.setText(s) } else { self?.model.setEmpty() }
                    }
                }
                return
            }
        }
        model.setEmpty()
    }

    /// 닫기는 아무것도 돌려주지 않고, 바꿔 넣기는 번역문을 돌려준다. 받아 주는 앱이면 고른 글이 바뀐다.
    private func finish(_ text: String?) {
        guard let text else {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: text)
        item.attachments = [NSItemProvider(item: text as NSString, typeIdentifier: UTType.plainText.identifier)]
        extensionContext?.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
