import SwiftUI
import UIKit

// MARK: - Keyboard dismiss helpers
// SwiftUI's @FocusState binding alone doesn't always dismiss the keyboard
// (especially in nested NavigationStack inside TabView with .page style, or
// when a TextEditor is hosted inside .safeAreaInset). This helper routes
// resignFirstResponder through UIKit so we always get a guaranteed close.

enum KeyboardDismiss {
    /// Forces the on-screen keyboard to dismiss by walking up the responder
    /// chain. Safe to call from any thread; bounces to main internally.
    static func now() {
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
    }
}

extension View {
    /// Dismiss the keyboard whenever `trigger` changes to `true`.
    func dismissKeyboardOn<V: Equatable>(_ value: V, when shouldDismiss: @escaping (V) -> Bool) -> some View {
        self.onChange(of: value) { _, newValue in
            if shouldDismiss(newValue) { KeyboardDismiss.now() }
        }
    }
}
