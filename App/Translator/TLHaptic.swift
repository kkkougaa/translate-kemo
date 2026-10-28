import UIKit

// 상황별 햅틱. Shared/Haptics 의 가벼운 탭 말고, 무엇이 일어났는지 손으로 구분되게 나눴다.
// 같은 '톡'이라도 무엇이 일어났는지 손으로 구분되게 나눴다.

enum TLHaptic {
    private static func main(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    /// 번역을 보냈다 — 아주 약하게
    static func start() { main { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5) } }

    /// 첫 글자가 들어왔다
    static func tick() { main { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.35) } }

    /// 번역·수정·이미지 결과가 다 왔다
    static func done() { main { UINotificationFeedbackGenerator().notificationOccurred(.success) } }

    /// 실패했다
    static func error() { main { UINotificationFeedbackGenerator().notificationOccurred(.error) } }

    /// 역번역이 어긋났다 (확인 권장)
    static func warn() { main { UINotificationFeedbackGenerator().notificationOccurred(.warning) } }

    /// 복사·붙여넣기·저장 — 단단하게 한 번
    static func copy() { main { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7) } }

    /// 고르기·넣기 (용어 넣기, 원문 보기 전환 등)
    static func select() { main { UISelectionFeedbackGenerator().selectionChanged() } }

    /// 취소
    static func cancel() { main { UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.45) } }
}
