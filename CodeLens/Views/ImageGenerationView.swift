import SwiftUI

// MARK: - ImageGenerationView
//
// Text-to-image generation UI over `ImageGenerationService`. Lets the user
// pick one of the on-device diffusion models, type a prompt, and generate.
// Presented as a sheet from the Models tab's Images section.

struct ImageGenerationView: View {

    @ObservedObject private var svc = ImageGenerationService.shared
    @Environment(\.koduTheme) private var T
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: String = ""
    @State private var negativePrompt: String = ""
    @State private var steps: Double = 0          // 0 = use model default
    @State private var showAdvanced = false

    private var model: ImageGenerationService.Model { svc.selectedModel }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidPinkBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        modelPicker
                        preview
                        promptCard
                        generateStrip
                        if showAdvanced { advancedCard }
                    }
                    .padding(16)
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Image Generation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let img = svc.image {
                        ShareLink(item: Image(uiImage: img),
                                  preview: SharePreview("Generated image",
                                                        image: Image(uiImage: img))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Model picker

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MODEL")
                .font(T.mono(10, .semibold))
                .tracking(0.6)
                .foregroundColor(T.ink3)
            ForEach(ImageGenerationService.catalog) { m in
                modelRow(m)
            }
            Text("SDXL needs the highest-memory iPhones. Live headroom is checked before loading it.")
                .font(T.mono(9))
                .foregroundColor(T.ink3)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func modelRow(_ m: ImageGenerationService.Model) -> some View {
        let installed = svc.isInstalled(m)
        let selected = m.id == svc.selectedModelID
        Button {
            svc.select(m.id)
            HapticManager.impact(.light)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(selected ? T.accent : T.ink4)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(m.displayName)
                            .font(T.display(16, .semibold))
                            .foregroundColor(T.ink)
                        if installed {
                            Text("installed")
                                .font(T.mono(8, .semibold))
                                .foregroundColor(T.good)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(T.good.opacity(0.14)))
                        }
                    }
                    Text(m.subtitle)
                        .font(T.mono(9.5))
                        .foregroundColor(T.ink3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(m.sizeLabel)
                        .font(T.mono(10, .semibold))
                        .foregroundColor(T.ink2)
                    if installed {
                        Button {
                            svc.deleteModel(m)
                            HapticManager.impact(.medium)
                        } label: {
                            Text("delete")
                                .font(T.mono(9, .semibold))
                                .foregroundColor(T.bad)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? T.accentSoft : T.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? T.accent.opacity(0.4) : T.rule, lineWidth: selected ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.clear)
                .aspectRatio(1, contentMode: .fit)
                .kGlass(cornerRadius: 20, fallbackFill: T.surface)

            if let img = svc.image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 34, weight: .light))
                        .foregroundColor(T.ink4)
                    Text("Your generated image appears here")
                        .font(T.mono(10))
                        .foregroundColor(T.ink3)
                }
            }

            // Progress overlay for download / load / generate.
            if let overlay = progressOverlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(T.bg.opacity(0.72))
                VStack(spacing: 12) {
                    if let frac = overlay.fraction {
                        ProgressView(value: frac).tint(T.accent)
                            .frame(width: 160)
                        Text("\(Int(frac * 100))%")
                            .font(T.mono(11, .semibold))
                            .foregroundColor(T.accent)
                    } else {
                        ProgressView().tint(T.accent)
                    }
                    Text(overlay.label)
                        .font(T.mono(10))
                        .foregroundColor(T.ink2)
                }
                .padding(20)
            }
        }
    }

    private struct Overlay { let label: String; let fraction: Double? }

    private var progressOverlay: Overlay? {
        switch svc.state {
        case .downloading(let f): return Overlay(label: "Downloading \(model.displayName)…", fraction: f)
        case .loading:            return Overlay(label: "Loading \(model.displayName)…", fraction: nil)
        case .generating(let f):  return Overlay(label: "Generating…", fraction: f)
        default:                  return nil
        }
    }

    // MARK: - Prompt

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PROMPT")
                .font(T.mono(10, .semibold))
                .tracking(0.6)
                .foregroundColor(T.ink3)
            TextField("a watercolor fox in a misty forest…",
                      text: $prompt, axis: .vertical)
                .font(T.sans(15))
                .foregroundColor(T.ink)
                .tint(T.accent)
                .lineLimit(2...5)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(T.rule, lineWidth: 0.5))

            Button { withAnimation { showAdvanced.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(showAdvanced ? "Hide options" : "More options")
                        .font(T.mono(10, .semibold))
                }
                .foregroundColor(T.ink3)
            }
            .buttonStyle(.plain)
        }
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("NEGATIVE PROMPT")
                    .font(T.mono(9, .semibold)).foregroundColor(T.ink3)
                TextField("things to avoid…", text: $negativePrompt, axis: .vertical)
                    .font(T.sans(14))
                    .foregroundColor(T.ink)
                    .tint(T.accent)
                    .lineLimit(1...3)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(T.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.rule, lineWidth: 0.5))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("STEPS")
                        .font(T.mono(9, .semibold)).foregroundColor(T.ink3)
                    Spacer()
                    Text(steps < 1 ? "default (\(model.defaultSteps))" : "\(Int(steps))")
                        .font(T.mono(10, .semibold)).foregroundColor(T.ink2)
                }
                Slider(value: $steps, in: 0...50, step: 1).tint(T.accent)
                Text("More steps = more detail but slower. Turbo models need only 1–4.")
                    .font(T.mono(8.5)).foregroundColor(T.ink3)
            }
        }
        .padding(14)
        .kGlass(cornerRadius: 16, fallbackFill: T.surface.opacity(0.6))
    }

    // MARK: - Generate

    private var isBusy: Bool {
        switch svc.state {
        case .downloading, .loading, .generating: return true
        default: return false
        }
    }

    private var generateStrip: some View {
        VStack(spacing: 8) {
            if case .failed(let msg) = svc.state {
                Text(msg)
                    .font(T.mono(10))
                    .foregroundColor(T.bad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                if isBusy {
                    Button {
                        svc.cancel()
                        HapticManager.impact(.medium)
                    } label: {
                        Text("Stop")
                            .font(T.display(16, .semibold))
                            .foregroundColor(T.bad)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 16).fill(T.bad.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        KeyboardDismiss.now()
                        let s = steps < 1 ? nil : Int(steps)
                        svc.generate(prompt: prompt,
                                     negativePrompt: negativePrompt,
                                     steps: s)
                        HapticManager.impact(.medium)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text(svc.isInstalled(model) ? "Generate" : "Download & Generate")
                        }
                        .font(T.display(16, .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(prompt.trimmingCharacters(in: .whitespaces).isEmpty
                                      ? T.ink4 : T.roseHi)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
