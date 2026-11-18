import SwiftUI
import Combine

// MARK: - GlobalKeyboardBar
// A thin app-wide accessory bar that floats above the iOS keyboard while it
// is visible. Provides a guaranteed "Done" button to dismiss the keyboard
// regardless of which screen / focus state is active.
//
// Mount once at the app root via `.safeAreaInset(edge: .bottom)`.

struct GlobalKeyboardBar: View {
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardVisible: Bool = false
    @Environment(\.koduTheme) private var T

    var body: some View {
        Group {
            if keyboardVisible {
                HStack {
                    Spacer()
                    Button {
                        KeyboardDismiss.now()
                        HapticManager.impact(.light)
                    } label: {
                        HStack(spacing: Space.xs) {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(.caption, weight: .medium))
                            Text("done")
                                .font(T.mono(12, .semibold))
                        }
                        .foregroundColor(T.ink)
                        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                        .kGlass(cornerRadius: Radius.inner, fallbackFill: T.surface)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, Space.s)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(T.bg.opacity(0.0))   // transparent backdrop
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: keyboardVisible)
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification)
        ) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification)
        ) { _ in keyboardVisible = false }
    }
}
