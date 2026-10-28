import SwiftUI
import TranslationUIProvider

// 기본 번역 앱 확장 (iOS 18.4+). 설정 → 앱 → 번역 → 기본 번역 앱에서 translate-kemo 를 고르면
// 아무 앱에서나 글을 고르고 '번역'을 눌렀을 때 시스템 시트 안에 우리 카드가 뜬다.
// 카드와 번역은 공유 시트 확장(ShareExtension)의 것을 그대로 쓴다.

@main
final class KougaTranslateExtension: TranslationUIProviderExtension {
    required init() {}

    var body: some TranslationUIProviderExtensionScene {
        TranslationUIProviderSelectedTextScene { context in
            KougaTranslateView(context: context)
        }
    }
}

struct KougaTranslateView: View {
    let context: any TranslationUIProviderContext
    @StateObject private var m = TLActionModel()

    var body: some View {
        TLActionView(m: m,
                     onClose: { context.finish(translation: nil) },
                     onReplace: { t in context.finish(translation: AttributedString(t)) },
                     embedded: true,
                     canReplace: context.allowsReplacement)
            .onAppear { load() }
            .onChange(of: context.inputText) { _, _ in load() }
    }

    private func load() {
        if let s = context.inputText, !String(s.characters).trimmed.isEmpty {
            m.setText(String(s.characters))
        } else {
            m.setEmpty()
        }
    }
}
