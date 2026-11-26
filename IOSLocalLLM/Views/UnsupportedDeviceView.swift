import SwiftUI

struct UnsupportedDeviceView: View {
    @Environment(\.koduTheme) private var T
    @ObservedObject private var localization = LocalizationService.shared

    // The gate is RAM-based, so iPhones and iPads share the same "8 GB+"
    // rule and we can show both pathways without misleading anyone into
    // thinking only iPhones qualify. The Mac build runs the same gate, but
    // there the card names Macs.
    private struct SupportedCard: Identifiable {
        let title: String
        let items: [String]
        var id: String { title }
    }

    private var supportedCards: [SupportedCard] {
        #if targetEnvironment(macCatalyst)
        [SupportedCard(title: "Supported Macs",
                       items: ["Apple silicon Mac (M1 or later)", "8 GB RAM or more"])]
        #else
        [SupportedCard(title: "Supported iPhones", items: supportedPhones),
         SupportedCard(title: "Supported iPads", items: supportedTablets)]
        #endif
    }

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

    private var deviceIcon: String {
        #if targetEnvironment(macCatalyst)
        return "laptopcomputer"
        #else
        return DeviceCompatibility.isiPad() ? "ipad.and.iphone.slash" : "iphone.slash"
        #endif
    }

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
                VStack(spacing: Space.l) {
                    Spacer().frame(height: 8)

                    Image(systemName: deviceIcon)
                        .font(.system(size: Space.xl, weight: .thin))
                        .foregroundColor(T.ink3)

                    VStack(spacing: Space.s) {
                        Text("Device Not Supported")
                            .font(T.display(22, .semibold))
                            .foregroundColor(T.ink)
                        Text("iOS Local LLM runs large AI models entirely on-device. Inference needs at least 8 GB of physical RAM to load without thermal throttling or Jetsam kills.")
                            .font(T.sans(13))
                            .foregroundColor(T.ink2)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.horizontal, Space.l)
                    }

                    // iPhone and iPad columns on iOS; one Mac card on Catalyst.
                    ForEach(supportedCards) { card in
                        supportedCard(title: card.title, items: card.items)
                    }

                    // Diagnostic + "why".
                    VStack(spacing: Space.xs) {
                        KMono(text: "WHY?", size: 10, color: T.ink4)
                        Text("Under 8 GB the OS evicts the model mid-inference and the app crashes or freezes. We'd rather block install than ship that experience.")
                            .font(T.sans(12))
                            .foregroundColor(T.ink3)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.horizontal, Space.l)
                        KMono(text: diagnosticLine, size: 9.5, color: T.ink4)
                            .padding(.top, Space.xs)
                    }

                    Spacer().frame(height: 24)
                }
            }
        }
    }

    @ViewBuilder
    private func supportedCard(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            KMono(text: localization.t(title).uppercased(), size: 10, color: T.ink4)
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: Space.s) {
                        Image(systemName: "checkmark")
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundColor(T.good)
                        Text(item)
                            .font(T.sans(13))
                            .foregroundColor(T.ink)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .kGlass(cornerRadius: Radius.card, fallbackFill: T.surface)
        .padding(.horizontal, Space.l)
    }
}
