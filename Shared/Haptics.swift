import AudioToolbox
import SwiftUI
import UIKit

/// 버튼에 붙이는 약한 햅틱
enum Haptics {
    /// 눌렀을 때: 약한 탭
    static func light() {
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6) }
    }

    /// 고르는 동작(스위치·스텝퍼·열차 선택)
    static func selection() {
        DispatchQueue.main.async { UISelectionFeedbackGenerator().selectionChanged() }
    }

    /// 라이브 액티비티 버튼: 인텐트는 앱 프로세스가 백그라운드에서 돌리기 때문에 시스템이 햅틱을 막을 수 있다. 시도만 한다.
    static func liveActivityTap() {
        AudioServicesPlaySystemSound(1519)
    }
}

private struct HapticTap: ViewModifier {
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content.simultaneousGesture(TapGesture().onEnded { if enabled { Haptics.light() } })
    }
}

extension View {
    /// 눌렀을 때 약한 햅틱. 버튼 모양은 그대로 둔다.
    func tapHaptic() -> some View { modifier(HapticTap()) }

    /// 값이 바뀔 때 고르는 햅틱(스위치·스텝퍼·피커·슬라이더)
    func changeHaptic<V: Equatable>(_ value: V) -> some View { sensoryFeedback(.selection, trigger: value) }
}
