import SwiftUI

// MARK: - ImageGenerationView
//
// Text-to-image generation UI over `ImageGenerationService`. Lets the user
// pick one of the on-device diffusion models, type a prompt, and generate.
// Presented from Home or the Models tab's Image section.

struct ImageGenerationView: View {

    @ObservedObject private var svc = ImageGenerationService.shared
    @State private var parentalControls = ImageGenerationParentalControls.shared
    @Environment(\.koduTheme) private var T
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var prompt: String = ""
    @State private var negativePrompt: String = ""
    @State private var steps: Double = 0          // 0 = use model default
    @State private var showAdvanced = false
    @State private var showModels = false

    private var model: ImageGenerationService.Model { svc.selectedModel }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidPinkBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if parentalControls.canGenerate {
                            ImageGenerationSelectedModelCard {
                                showModels = true
                            }
                            promptCard
                            Label("Prompts and generated images are checked locally. Explicit content is withheld. Checks can make mistakes.", systemImage: "checkmark.shield")
                                .font(.footnote)
                                .foregroundStyle(T.ink2)
                                .accessibilityIdentifier("imageGenerationSafetyNotice")
                            generateStrip
                            if showAdvanced { advancedCard }
                            preview
                            ImageParentalControlsView()
                        } else {
                            ImageParentalControlsView()
                            ContentUnavailableView("Image generation is locked", systemImage: "lock.shield",
                                                   description: Text("A parent or guardian must enter the parental PIN to continue."))
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Image Generation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Hide Keyboard") { KeyboardDismiss.now() }
                        .accessibilityIdentifier("imageGenerationHideKeyboard")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if parentalControls.canGenerate, let img = svc.image {
                        ShareLink(item: Image(uiImage: img),
                                  preview: SharePreview("Generated image",
                                                        image: Image(uiImage: img))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showModels) {
            ImageGenerationModelsView()
                .dynamicTypeSize(dynamicTypeSize)
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(Color.clear)
                .aspectRatio(1, contentMode: .fit)
                .kGlass(cornerRadius: AppRadius.card, fallbackFill: T.surface)

            if let img = svc.image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
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
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
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
        case .checking:          return Overlay(label: "Checking image locally…", fraction: nil)
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
                .accessibilityIdentifier("imageGenerationPrompt")
                .font(T.sans(15))
                .foregroundColor(T.ink)
                .tint(T.accent)
                .lineLimit(2...5)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(T.rule, lineWidth: 0.5))

            Button { withAnimation { showAdvanced.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 9, weight: .semibold))
                    Text(showAdvanced ? "Hide options" : "More options")
                        .font(T.mono(10, .semibold))
                }
                .foregroundColor(T.ink3)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
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

    private var generateStrip: some View {
        VStack(spacing: 8) {
            if svc.isBusy, let overlay = progressOverlay {
                Text(overlay.label)
                    .font(.footnote)
                    .foregroundStyle(T.ink2)
                if let fraction = overlay.fraction {
                    ProgressView(value: fraction).tint(T.accent)
                }
            }
            if case .failed(let msg) = svc.state {
                Text(msg)
                    .font(T.mono(10))
                    .foregroundColor(T.bad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A model disabled after repeated killed runs stays disabled
                // until its learned limits are cleared.
                if svc.isCrashBlocked(model.id) {
                    Button("Try Again") { svc.resetImageModelLimits() }
                        .font(.footnote)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            HStack(spacing: 10) {
                if svc.isBusy {
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
                                .fill(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || svc.isDownloading(model)
                                      ? T.ink4 : T.roseHi)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || svc.isDownloading(model))
                    .accessibilityIdentifier("imageGenerationStart")
                }
            }
        }
    }
}

/// The generator keeps model setup close to the prompt without showing the
/// entire catalog above the editor. Downloads never require prompt input.
private struct ImageGenerationSelectedModelCard: View {
    let onChangeModel: () -> Void
    @ObservedObject private var service = ImageGenerationService.shared
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onChangeModel) {
                HStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                        .foregroundStyle(T.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Image model")
                            .font(.caption)
                            .foregroundStyle(T.ink3)
                        Text(service.selectedModel.displayName)
                            .font(.headline)
                            .foregroundStyle(T.ink)
                    }
                    Spacer(minLength: 0)
                    Text("Change")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(T.accent)
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(T.accent)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(service.isBusy)
            .accessibilityLabel("Change image model, \(service.selectedModel.displayName)")
            .accessibilityIdentifier("imageGenerationChooseModel")

            if !service.isInstalled(service.selectedModel) && !service.isBusy {
                Text("Download once to generate offline. No prompt needed.")
                    .font(.footnote)
                    .foregroundStyle(T.ink2)
            }
            ImageModelDownloadControl(model: service.selectedModel)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(T.rule, lineWidth: 0.5))
    }
}

struct ImageGenerationModelsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidPinkBackdrop()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        Text("Choose a model and download it before writing a prompt. These models are also available in Models → Image.")
                            .font(.subheadline)
                            .foregroundStyle(T.ink2)
                        ForEach(ImageGenerationService.catalog) { model in
                            ImageGenerationModelRow(model: model)
                        }
                        Text("SDXL needs the highest-memory iPhones. Live headroom is checked before loading a model.")
                            .font(.footnote)
                            .foregroundStyle(T.ink3)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Image Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}

/// Shared by Models → Image, the download queue, and the generator's picker.
/// Selection, download, and deletion each have their own tap target.
struct ImageGenerationModelRow: View {
    let model: ImageGenerationService.Model
    @ObservedObject private var service = ImageGenerationService.shared
    @Environment(\.koduTheme) private var T
    @State private var confirmDeletion = false

    var body: some View {
        let selected = model.id == service.selectedModelID
        let installed = service.isInstalled(model)
        VStack(alignment: .leading, spacing: 12) {
            Button {
                service.select(model.id)
                HapticManager.impact(.light)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? T.accent : T.ink3)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.displayName)
                            .font(.headline)
                            .foregroundStyle(T.ink)
                        Text(LocalizedStringKey(model.subtitle))
                            .font(.caption)
                            .foregroundStyle(T.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(model.sizeLabel) · \(model.pixelEdge) × \(model.pixelEdge)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(T.ink2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(service.isBusy)
            .accessibilityLabel("Use \(model.displayName)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("imageModelSelect-\(model.id)")

            ImageModelMemoryNote(footprint: model.approxRAMBytes)
            HStack {
                ImageModelDownloadControl(model: model)
                if installed {
                    Spacer(minLength: 0)
                    Button(role: .destructive) { confirmDeletion = true } label: {
                        Image(systemName: "trash")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(T.bad)
                    .disabled(service.isBusy || service.isDownloading(model))
                    .accessibilityLabel("Delete \(model.displayName)")
                    .accessibilityIdentifier("imageModelDelete-\(model.id)")
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(selected ? T.accentSoft : T.surface))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(selected ? T.accent.opacity(0.4) : T.rule, lineWidth: selected ? 1 : 0.5))
        .confirmationDialog("Delete \(model.displayName)?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { service.deleteModel(model) }
        } message: {
            Text("Its downloaded weights are removed from this device. You can download it again later.")
        }
    }
}

private struct ImageModelMemoryNote: View {
    let footprint: Int64
    @Environment(\.koduTheme) private var T

    var body: some View {
        switch MemoryAdvisor.fit(forFootprint: footprint) {
        case .fits:
            EmptyView()
        case .tight, .over:
            Label("May not fit this device. Available memory is checked before generation.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(T.warn)
        }
    }
}

struct ImageModelDownloadControl: View {
    let model: ImageGenerationService.Model
    @ObservedObject private var service = ImageGenerationService.shared
    @State private var parentalControls = ImageGenerationParentalControls.shared
    @Environment(\.koduTheme) private var T

    var body: some View {
        if service.isDownloading(model) {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: service.downloadProgress(for: model))
                    .tint(T.accent)
                    .accessibilityLabel("Downloading \(model.displayName)")
                HStack {
                    Text("Downloading · \(service.downloadProgress(for: model), format: .percent.precision(.fractionLength(0)))")
                        .font(.caption)
                        .foregroundStyle(T.ink2)
                    Spacer(minLength: 0)
                    Button("Cancel") { service.cancelDownload(model) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(T.accent)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Cancel download of \(model.displayName)")
                        .accessibilityIdentifier("imageModelCancel-\(model.id)")
                }
            }
            .accessibilityIdentifier("imageModelProgress-\(model.id)")
        } else if service.isInstalled(model) {
            Label("Downloaded · Ready to generate", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(T.good)
                .accessibilityIdentifier("imageModelInstalled-\(model.id)")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let error = service.directDownloadErrors[model.id] {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(T.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    service.startDownload(model)
                    HapticManager.impact(.light)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                        if service.directDownloadErrors[model.id] != nil {
                            Text("Retry download · \(model.sizeLabel)")
                        } else {
                            Text("Download model · \(model.sizeLabel)")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(T.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.kSecondary)
                .tint(T.accent)
                .disabled(!parentalControls.canGenerate || service.isBusy)
                .accessibilityLabel("Download \(model.displayName), \(model.sizeLabel)")
                .accessibilityHint("Downloads the model without generating an image or requiring a prompt.")
                .accessibilityIdentifier("imageModelDownload-\(model.id)")
                if !parentalControls.canGenerate {
                    Text("Unlock image generation with the parental PIN to download models.")
                        .font(.footnote)
                        .foregroundStyle(T.ink3)
                }
            }
        }
    }
}
