import SwiftUI

struct UnsupportedDeviceView: View {
    @Environment(\.koduTheme) private var T

    // Two columns now — the gate is RAM-based, so iPhones and iPads
    // share the same "8 GB+" rule and we can show both pathways
    // without misleading anyone into thinking only iPhones qualify.
    private let supportedPhones = [
        "iPhone 15 Pro / Pro Max",
        "iPhone 16 / Plus / Pro / Pro Max / Air",
        "iPhone 17 / Air / Pro / Pro Max",
    ]
    private let supportedTablets = [
        "iPad Pro with M1, M2, or M4",
        "iPad Air with M1, M2, or M3",
        "iPad mini (A17 Pro)",
    ]

    /// Diagnostic line for the current device — helps the user
    /// understand exactly why they're seeing this screen. Built off
    /// DeviceCompatibility helpers so the strings stay in sync if
    /// the gate ever changes.
    private var diagnosticLine: String {
        let id = DeviceCompatibility.machineIdentifier()
        let gb = DeviceCompatibility.physicalMemoryGB()
        return "Detected: \(id) · \(gb) GB RAM"
    }

    var body: some View {
        ZStack {
            LiquidPinkBackdrop()
            ScrollView {
                VStack(spacing: 28) {
                    Spacer().frame(height: 8)

                    Image(systemName: DeviceCompatibility.isiPad()
                          ? "ipad.and.iphone.slash"
                          : "iphone.slash")
                        .font(.system(size: 52, weight: .thin))
                        .foregroundColor(T.ink3)

                    VStack(spacing: 10) {
                        Text("Device Not Supported")
                            .font(T.display(22, .semibold))
                            .foregroundColor(T.ink)
                        Text("OnDevice LLM runs large AI models entirely on-device. Inference needs at least 8 GB of physical RAM to load without thermal throttling or Jetsam kills.")
                            .font(T.sans(13))
                            .foregroundColor(T.ink2)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.horizontal, 28)
                    }

                    // iPhone column.
                    supportedCard(
                        title: "Supported iPhones",
                        items: supportedPhones
                    )

                    // iPad column.
                    supportedCard(
                        title: "Supported iPads",
                        items: supportedTablets
                    )

                    // Diagnostic + "why".
                    VStack(spacing: 6) {
                        KMono(text: "WHY?", size: 10, color: T.ink4)
                        Text("Under 8 GB the OS evicts the model mid-inference and the app crashes or freezes. We'd rather block install than ship that experience.")
                            .font(T.sans(12))
                            .foregroundColor(T.ink3)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.horizontal, 32)
                        KMono(text: diagnosticLine, size: 9.5, color: T.ink4)
                            .padding(.top, 6)
                    }

                    Spacer().frame(height: 24)
                }
            }
        }
    }

    @ViewBuilder
    private func supportedCard(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            KMono(text: title.uppercased(), size: 10, color: T.ink4)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(T.good)
                        Text(item)
                            .font(T.sans(13))
                            .foregroundColor(T.ink)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .kGlass(cornerRadius: 14, fallbackFill: T.surface)
        .padding(.horizontal, 24)
    }
}
