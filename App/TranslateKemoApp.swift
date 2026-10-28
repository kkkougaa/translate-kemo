import SwiftUI

// translate-kemo — 한국어 ↔ 일본어·영어·중국어 번역기.
// 원래 kemometro 안에 같이 있다가 따로 떨어져 나왔다. 화면은 TranslatorView 하나가 전부다.

@main
struct TranslateKemoApp: App {
    var body: some Scene {
        WindowGroup {
            TranslatorView()
        }
    }
}
