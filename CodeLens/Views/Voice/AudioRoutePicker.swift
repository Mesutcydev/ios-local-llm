import AVKit
import SwiftUI

// MARK: - AudioRoutePicker
// System-native AVRoutePickerView wrapper. Does not invent fake devices.

struct AudioRoutePicker: UIViewRepresentable {
    var tintColor: UIColor = .label

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = tintColor
        picker.activeTintColor = tintColor
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = tintColor
    }
}

/// Compact Voice Mode control: route icon + name + system picker affordance.
struct VoiceRouteControl: View {
    @ObservedObject var sessionManager: VoiceAudioSessionManager
    @Environment(\.koduTheme) private var T

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: sessionManager.route.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(T.ink2)
            Text(sessionManager.route.displayName)
                .font(T.mono(10.5, .semibold))
                .foregroundStyle(T.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            AudioRoutePicker(tintColor: UIColor(T.ink2))
                .frame(width: 28, height: 28)
                .accessibilityLabel("Audio output route")
                .accessibilityHint("Opens system route picker")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(T.surface)
                .overlay(Capsule().stroke(T.rule, lineWidth: 0.5))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audio output: \(sessionManager.route.displayName)")
        .onAppear { sessionManager.startObserving() }
        .onDisappear { sessionManager.stopObserving() }
    }
}
