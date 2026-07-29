import SwiftUI
import PhotosUI

// MARK: - VisualModelComparisonView
//
// A/B comparison sheet: pick an image, pick two models, run them
// sequentially (Metal contention rules out true parallel inference on
// iPhone), and show both streamed outputs side-by-side with tokens/sec.
//
// Sequential not parallel: MLXGenerationGate already serialises VLM
// loads across services, and the GPU command queue can't fan out two
// VLM forward passes without crashes we've already eaten. Sequential
// is what the gate enforces anyway — embracing it keeps the code
// honest and the behavior predictable.
//
// Both backends share the same `describe(image:prompt:maxTokens:onToken:
// onComplete:)` surface, so the per-side runner is the same callback
// machine pointed at a different service.

@MainActor
struct VisualModelComparisonView: View {

    @ObservedObject private var center = ModelDownloadCenter.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    /// Both panels start unselected; the user picks each from a per-panel
    /// menu. Each ID is either `""` (FastVLM) or a catalog repoID.
    @State private var leftID: String = ""
    @State private var rightID: String = ""

    /// PhotosPicker selection + the resolved UIImage.
    @State private var photoSelection: PhotosPickerItem?
    @State private var image: UIImage?

    /// Per-side streamed output, generation state, and final tok/s rate.
    @State private var leftOutput: String = ""
    @State private var rightOutput: String = ""
    @State private var leftTPS: Double = 0
    @State private var rightTPS: Double = 0
    @State private var leftRunning = false
    @State private var rightRunning = false

    @State private var prompt: String = "Describe what's in this image. Be concise."

    /// Blind judging: hide model identity on the panels and randomize which
    /// pick runs in which panel, so the vote reflects output quality, not
    /// which model name the user already prefers. Names reveal on vote.
    @State private var blind = false
    @State private var revealed = true
    /// Recorded verdict for the current pair (nil until the user votes).
    @State private var votedOutcome: ModelArenaStore.Outcome?
    /// The repoIDs that actually ran in each panel (== picks, or swapped
    /// when blind). Empty string still means FastVLM. Used so the vote maps
    /// back to the right models even after a blind shuffle.
    @State private var ranLeftID: String = ""
    @State private var ranRightID: String = ""

    /// All VLMs the picker would let the user select — same list as
    /// VisualModelPickerView's downloaded section plus FastVLM.
    private var availableModels: [DownloadableModel] {
        var seen = Set<String>()
        return center.models.filter { m in
            guard m.supportsCategory(.vlm) else { return false }
            guard VisualModelInstallStatus.runStatus(for: m).isReady else { return false }
            return seen.insert(m.sourceRepoID).inserted
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    imagePickerCard
                    promptCard
                    blindToggle
                    HStack(alignment: .top, spacing: 12) {
                        panel(side: .left)
                        panel(side: .right)
                    }
                    runButton
                    if canVote { voteCard }
                    ArenaLeaderboardCard(lane: .vision)
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(T.ink)
                }
            }
            .onChange(of: photoSelection) { _, newValue in
                guard let newValue else { return }
                Task { await loadImage(from: newValue) }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: "CAMERA · A/B")
            KPageTitle(title: "compare vlms", size: 24)
            KMono(text: "run two models on the same image to see which suits you",
                  size: 11, color: T.ink3)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Image picker

    private var imagePickerCard: some View {
        VStack(spacing: 10) {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ZStack {
                    Color.clear
                        .frame(height: 140)
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 22, weight: .light))
                            .foregroundColor(T.ink3)
                        KMono(text: "pick an image to compare", size: 11, color: T.ink3)
                    }
                }
                .kGlass(cornerRadius: 8, fallbackFill: T.surface)
            }
            // Snapshot main-actor state (image, theme) into locals so
            // the PhotosPicker label closure — which Swift 6 treats as
            // Sendable / nonisolated — can read them without flagging
            // "main actor-isolated property can not be referenced from
            // a Sendable closure" warnings.
            let hasImage = (image != nil)
            let labelFont = T.mono(11, .semibold)
            let fgColor = T.bg
            let bgColor = T.ink
            PhotosPicker(selection: $photoSelection,
                         matching: .images,
                         photoLibrary: .shared()) {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 11, weight: .medium))
                    Text(hasImage ? "change image" : "pick image")
                        .font(labelFont)
                }
                .foregroundColor(fgColor)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(bgColor))
            }
        }
    }

    // MARK: - Prompt

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            KCaption(text: "PROMPT")
            TextField("", text: $prompt, axis: .vertical)
                .font(T.mono(11))
                .foregroundColor(T.ink)
                .lineLimit(2...4)
                .padding(8)
                .kGlass(cornerRadius: 6, fallbackFill: T.surface2)
        }
    }

    // MARK: - Blind toggle

    private var blindToggle: some View {
        Toggle(isOn: $blind) {
            VStack(alignment: .leading, spacing: 2) {
                Text("blind mode")
                    .font(T.mono(11, .semibold))
                    .foregroundColor(T.ink)
                KMono(text: "hide names + randomize panels — judge the output, not the brand",
                      size: 9, color: T.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(T.accent)
        .padding(10)
        .kGlass(cornerRadius: 8, fallbackFill: T.surface)
    }

    // MARK: - Voting

    /// Can vote once both panels have finished producing output.
    private var canVote: Bool {
        !leftRunning && !rightRunning && !leftOutput.isEmpty && !rightOutput.isEmpty
    }

    @ViewBuilder
    private var voteCard: some View {
        VStack(spacing: 10) {
            KCaption(text: "VERDICT")
            if let outcome = votedOutcome {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(T.accent)
                    Text(verdictLabel(outcome))
                        .font(T.mono(10, .semibold))
                        .foregroundColor(T.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            } else {
                KMono(text: blind ? "which answer is better? names reveal after you choose"
                                  : "which model read the image better?",
                      size: 10, color: T.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    voteButton(title: "← left", outcome: .aWins)
                    voteButton(title: "tie", outcome: .tie)
                    voteButton(title: "right →", outcome: .bWins)
                }
            }
        }
        .padding(12)
        .kGlass(cornerRadius: 8, fallbackFill: T.surface)
    }

    @ViewBuilder
    private func voteButton(title: String, outcome: ModelArenaStore.Outcome) -> some View {
        Button {
            castVote(outcome)
            HapticManager.impact(.medium)
        } label: {
            Text(title)
                .font(T.mono(11, .semibold))
                .foregroundColor(T.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.surface2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Arena identity for a panel's repoID — FastVLM has no repoID, so it
    /// gets a stable synthetic key/name.
    private func arenaID(_ repoID: String) -> String {
        repoID.isEmpty ? "fastvlm-builtin" : repoID
    }
    private func arenaName(_ repoID: String) -> String {
        if repoID.isEmpty { return "FastVLM" }
        return availableModels.first(where: { $0.sourceRepoID == repoID || $0.id == repoID })?.displayName
            ?? repoID.split(separator: "/").last.map(String.init)
            ?? repoID
    }

    private func verdictLabel(_ outcome: ModelArenaStore.Outcome) -> String {
        switch outcome {
        case .aWins: return "\(arenaName(ranLeftID)) wins — recorded to standings"
        case .bWins: return "\(arenaName(ranRightID)) wins — recorded to standings"
        case .tie:   return "tie — recorded to standings"
        }
    }

    private func castVote(_ outcome: ModelArenaStore.Outcome) {
        // Left panel == arena model A, right panel == model B.
        ModelArenaStore.shared.record(
            lane: .vision,
            a: (id: arenaID(ranLeftID),  name: arenaName(ranLeftID)),
            b: (id: arenaID(ranRightID), name: arenaName(ranRightID)),
            outcome: outcome
        )
        votedOutcome = outcome
        revealed = true
    }

    // MARK: - Panels

    enum Side { case left, right }

    @ViewBuilder
    private func panel(side: Side) -> some View {
        let id = side == .left ? leftID : rightID
        let output = side == .left ? leftOutput : rightOutput
        let tps = side == .left ? leftTPS : rightTPS
        let running = side == .left ? leftRunning : rightRunning
        VStack(alignment: .leading, spacing: 6) {
            modelPicker(side: side, currentID: id)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(T.surface)
                VStack(alignment: .leading, spacing: 4) {
                    if running {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.6).tint(T.accent)
                            KMono(text: "running…", size: 9, color: T.ink3)
                        }
                    } else if tps > 0 {
                        KMono(text: String(format: "%.1f tok/s", tps), size: 9, color: T.accent)
                    } else if !output.isEmpty {
                        KMono(text: "done", size: 9, color: T.ink3)
                    } else {
                        KMono(text: "idle", size: 9, color: T.ink3)
                    }
                    Text(output.isEmpty ? "(no output yet)" : output)
                        .font(T.mono(11))
                        .foregroundColor(output.isEmpty ? T.ink3 : T.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
            }
            .frame(minHeight: 160, alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.rule, lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func modelPicker(side: Side, currentID: String) -> some View {
        Menu {
            Button("FastVLM (built-in)") { setID("", for: side) }
            ForEach(availableModels, id: \.id) { m in
                Button(m.displayName) { setID(m.sourceRepoID, for: side) }
            }
        } label: {
            HStack(spacing: 6) {
                // While judging blind, mask identity with a neutral slot
                // label so panel position can't bias the vote.
                let masked = blind && !revealed
                let title = masked
                    ? (side == .left ? "Model A" : "Model B")
                    : (currentID.isEmpty
                        ? "FastVLM"
                        : (availableModels.first(where: {
                            $0.sourceRepoID == currentID || $0.id == currentID
                        })?.displayName
                           ?? currentID.split(separator: "/").last.map(String.init)
                           ?? "Pick model"))
                Text(title)
                    .font(T.mono(11, .semibold))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(T.ink3)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kGlass(cornerRadius: 6, fallbackFill: T.surface2)
        }
    }

    private func setID(_ id: String, for side: Side) {
        switch side {
        case .left:  leftID = id
        case .right: rightID = id
        }
    }

    // MARK: - Run button

    private var runButton: some View {
        let reason = blockerReason
        return VStack(spacing: 6) {
            Button {
                Task { await runComparison() }
            } label: {
                HStack(spacing: 6) {
                    if leftRunning || rightRunning {
                        ProgressView().scaleEffect(0.7).tint(T.bg)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(leftRunning ? "running left…"
                         : rightRunning ? "running right…"
                         : "compare")
                        .font(T.mono(13, .semibold))
                        .tracking(0.5)
                }
                .foregroundColor(T.bg)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(canRun ? T.ink : T.ink3))
            }
            .buttonStyle(.plain)
            .disabled(!canRun)

            if !reason.isEmpty && !(leftRunning || rightRunning) {
                Text(reason)
                    .font(T.mono(10))
                    .foregroundColor(T.ink3)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var canRun: Bool {
        guard image != nil, !leftRunning, !rightRunning else { return false }
        // Both sides must point at a model that's actually runnable. Empty
        // id == FastVLM, which is only valid when its components can
        // generate (encoder + decoder + projector all loaded).
        return isSideRunnable(leftID) && isSideRunnable(rightID)
    }

    private func isSideRunnable(_ id: String) -> Bool {
        if id.isEmpty {
            // FastVLM's runtime gate is componentStatus.canGenerate. We
            // also accept .isFullyInstalled (decoder + encoder on disk
            // but not yet loaded) — `runFastVLM` calls `load()` lazily
            // when the gate is false, so an installed-but-cold FastVLM
            // is still a valid pick.
            return FastVLMService.shared.componentStatus.canGenerate
                || FastVLMService.installStatus().isFullyInstalled
        }
        return availableModels.contains(where: { $0.sourceRepoID == id || $0.id == id })
    }

    /// One-line reason the compare button is disabled — surfaced under the
    /// button so the user isn't left wondering why nothing happens. Empty
    /// string means "no blocker".
    private var blockerReason: String {
        if image == nil { return "Pick an image to compare." }
        if !isSideRunnable(leftID) {
            return leftID.isEmpty
                ? "FastVLM isn't installed. Pick a downloaded VLM on the left."
                : "Left model isn't ready. Pick another."
        }
        if !isSideRunnable(rightID) {
            return rightID.isEmpty
                ? "FastVLM isn't installed. Pick a downloaded VLM on the right."
                : "Right model isn't ready. Pick another."
        }
        if leftID == rightID && !leftID.isEmpty {
            // Same MLX/GGUF repo on both sides means two passes of the same
            // model — wastes time and confuses the comparison. (FastVLM on
            // both sides is also pointless but doesn't hurt anything.)
            return "Pick two different models to compare."
        }
        return ""
    }

    // MARK: - Compare

    private func runComparison() async {
        guard let img = image else { return }
        leftOutput = ""; rightOutput = ""; leftTPS = 0; rightTPS = 0
        votedOutcome = nil
        revealed = !blind

        // In blind mode, randomly map the two picks onto the panels so the
        // user can't infer identity from panel position. The run-time slot
        // ids drive both inference and the eventual vote mapping.
        if blind && Bool.random() {
            ranLeftID = rightID; ranRightID = leftID
        } else {
            ranLeftID = leftID; ranRightID = rightID
        }

        // Sequential by design — MLXGenerationGate serialises anyway,
        // and trying to fan out two VLM forward passes on iPhone Metal
        // has historically been a SIGABRT speedrun.
        await runSide(.left, image: img, repoID: ranLeftID)
        await runSide(.right, image: img, repoID: ranRightID)
    }

    private func runSide(_ side: Side, image: UIImage, repoID: String) async {
        setRunning(true, for: side)
        defer { setRunning(false, for: side) }

        // FastVLM doesn't expose a UIImage describe() like the other
        // backends — its pipeline takes a CVPixelBuffer + structured
        // FastVLMTask payload. Funnel the image through there so the
        // comparison covers all three backends.
        if repoID.isEmpty {
            await runFastVLM(side: side, image: image)
            return
        }

        // Route through the catalog's explicit runtime contract. Repo-name
        // guessing breaks for imported/custom models whose IDs do not happen
        // to contain "GGUF" even though their validated files are a GGUF pair.
        let runtime = LocalModelRegistry.visionRuntime(
            forStoredSelectionID: repoID,
            catalog: ModelDownloadCenter.shared.models
        )
        if runtime == .llamaCpp {
            await runGGUF(side: side, image: image, repoID: repoID)
        } else {
            await runMLX(side: side, image: image, repoID: repoID)
        }
    }

    private func runMLX(side: Side, image: UIImage, repoID: String) async {
        if MLXVisionService.shared.activeRepoID != repoID {
            await MLXVisionService.shared.switchTo(repoID: repoID)
        }
        // describe() schedules its own task and surfaces via callbacks.
        // We bridge to async with a CheckedContinuation that fires on
        // onComplete — onToken pumps the streamed text into the UI.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            LensInferenceLoop.shared.describe(
                image: image,
                prompt: prompt,
                maxTokens: 160,
                onToken: { token in
                    Task { @MainActor in self.appendOutput(token, for: side) }
                },
                onComplete: { rate in
                    Task { @MainActor in
                        self.setTPS(rate, for: side)
                        cont.resume()
                    }
                }
            )
        }
    }

    private func runGGUF(side: Side, image: UIImage, repoID: String) async {
        if LlamaCppVLMService.shared.activeRepoID != repoID {
            await LlamaCppVLMService.shared.switchTo(repoID: repoID)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            LlamaCppVLMService.shared.describe(
                image: image,
                prompt: prompt,
                maxTokens: 160,
                onToken: { token in
                    Task { @MainActor in self.appendOutput(token, for: side) }
                },
                onComplete: { rate in
                    Task { @MainActor in
                        self.setTPS(rate, for: side)
                        cont.resume()
                    }
                }
            )
        }
    }

    private func runFastVLM(side: Side, image: UIImage) async {
        // Bring FastVLM up if it isn't already.
        if !FastVLMService.shared.componentStatus.canGenerate {
            await FastVLMService.shared.load()
        }
        guard FastVLMService.shared.componentStatus.canGenerate else {
            appendOutput("(FastVLM unavailable — check Model Center)", for: side)
            return
        }
        // FastVLMService needs a CVPixelBuffer; build one from the UIImage.
        guard let pixelBuffer = pixelBuffer(from: image) else {
            appendOutput("(couldn't build pixel buffer)", for: side)
            return
        }
        let settings = FastVLMGenerationSettings(
            maxTokens: 160,
            temperature: 0.7,
            topP: 0.9,
            repetitionPenalty: 1.0,
            stopOnEOS: true
        )
        let stream = FastVLMService.shared.analyze(
            pixelBuffer: pixelBuffer,
            task: .describeImage,
            settings: settings
        )
        do {
            for try await chunk in stream {
                appendOutput(chunk, for: side)
            }
        } catch {
            appendOutput("\n[error: \(error.localizedDescription)]", for: side)
        }
        // FastVLM exposes tok/s on debugInfo after the stream finishes.
        if let tps = FastVLMService.shared.debugInfo?.lastTokensPerSecond {
            setTPS(tps, for: side)
        }
    }

    // MARK: - State helpers

    private func setRunning(_ running: Bool, for side: Side) {
        switch side {
        case .left:  leftRunning = running
        case .right: rightRunning = running
        }
    }

    private func appendOutput(_ chunk: String, for side: Side) {
        switch side {
        case .left:  leftOutput.append(chunk)
        case .right: rightOutput.append(chunk)
        }
    }

    private func setTPS(_ rate: Double, for side: Side) {
        switch side {
        case .left:  leftTPS = rate
        case .right: rightTPS = rate
        }
    }

    // MARK: - PhotosPicker glue

    private func loadImage(from item: PhotosPickerItem) async {
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                self.image = img
            }
        } catch {
            ToastCenter.shared.error("Could not load image",
                                     detail: error.localizedDescription)
        }
    }

    /// Minimal UIImage → CVPixelBuffer bridge. Kept local — every
    /// VLM service has its own preferred conversion, but FastVLMService
    /// takes a buffer directly so we mint one here. BGRA32 is what
    /// AVFoundation hands us elsewhere; FastVLMProcessor handles the
    /// resize/normalise.
    ///
    /// We cap the longest side at 1024px before allocating. A 4032×3024
    /// camera photo would otherwise allocate ~48 MB just for the BGRA
    /// buffer and another 48 MB for the CGContext copy — enough to push
    /// the iPhone over its app memory ceiling once a VLM is also resident,
    /// which is the "compare crashes / shows nothing" symptom users hit.
    /// FastVLMProcessor downsamples to 336–512 anyway, so the extra
    /// resolution is wasted work.
    private func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        let maxSide: CGFloat = 1024
        let srcSize = image.size
        let scale = min(1, maxSide / max(srcSize.width, srcSize.height))
        let width  = max(1, Int((srcSize.width  * scale).rounded()))
        let height = max(1, Int((srcSize.height * scale).rounded()))

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var buf: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buf
        )
        guard status == kCVReturnSuccess, let pb = buf else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let cg = image.cgImage, let context = ctx else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }
}
