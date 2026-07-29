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
                        HStack(spacing: 5) {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 12, weight: .medium))
                            Text("done")
                                .font(T.mono(12, .semibold))
                                .tracking(0.3)
                        }
                        .foregroundColor(T.ink)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .kGlass(cornerRadius: 6, fallbackFill: T.surface)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
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
