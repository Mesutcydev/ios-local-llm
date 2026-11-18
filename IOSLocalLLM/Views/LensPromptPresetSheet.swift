import SwiftUI

// MARK: - LensPromptPresetSheet
// Compact picker for the camera tab's prompt preset. Opened from the small
// "ask · <preset>" pill in liveCaptionControls. Persists via AppSettings.
// Sheet UI deliberately stays in the app's light theme — only the camera
// surface itself uses dark glass.

struct LensPromptPresetSheet: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    private var current: LensPromptPreset {
        LensPromptPreset.from(rawValue: settings.lensPromptPresetID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    KSection(title: "prompt_preset") {
                        ForEach(Array(LensPromptPreset.allCases.enumerated()),
                                id: \.element.id) { i, preset in
                            if i > 0 {
                                Rectangle().fill(T.rule).frame(height: 1)
                            }
                            row(for: preset)
                        }
                    }
                    hintBox
                }
                .padding(.bottom, Space.l)
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .foregroundColor(T.ink)
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            KCaption(text: "LENS")
            KPageTitle(title: "ask", size: 28)
            KMono(text: "pick the question the camera asks the model",
                  size: 11, color: T.ink3)
                .padding(.top, Space.hair)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.m)
        .padding(.top, Space.xxs)
    }

    @ViewBuilder
    private func row(for preset: LensPromptPreset) -> some View {
        let isSelected = current == preset
        Button {
            settings.lensPromptPresetID = preset.rawValue
            HapticManager.impact(.light)
            // Auto-dismiss on selection — fewer taps to get back to camera.
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: Space.s) {
                radio(selected: isSelected).padding(.top, Space.hair)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: Space.xs) {
                        Text(preset.label)
                            .font(T.mono(13, .semibold))
                            .foregroundColor(T.ink)
                        if isSelected {
                            KActivePill(text: "active")
                        }
                    }
                    KMono(text: preset.hint, size: 10, color: T.ink3)
                }
                Spacer()
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func radio(selected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(selected ? T.accent : T.rule2, lineWidth: 1.5)
                .frame(width: Size.glyph, height: Size.glyph)
            if selected {
                Circle().fill(T.accent).frame(width: 9, height: 9)
            }
        }
    }

    private var hintBox: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("tip")
                .font(T.mono(9, .semibold))
                .foregroundColor(T.ink3)
            Text("Preset is applied on the next analysis. Switch back to “describe” for the classic short live-caption feel.")
                .font(T.sans(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kGlass(cornerRadius: Radius.inner, fallbackFill: T.surface)
        .padding(.horizontal, Space.m)
        .padding(.top, Space.s)
    }
}
