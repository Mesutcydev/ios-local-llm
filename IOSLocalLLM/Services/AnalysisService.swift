import Foundation
import CoreImage
import CoreML
import UIKit
import Combine

// MARK: - AnalysisService
// Two honest analysis paths:
//   A) Full FastVLM pipeline (encoder → projector → decoder → KV-cache generation)
//      Active when: componentStatus.canGenerate == true AND fastVLMEnabled setting is on.
//      Requires: multimodal_projector.mlpackage + language_model_kvcache.mlpackage in bundle.
//      Run scripts/export_fastvlm_coreml.sh to obtain the missing models.
//
//   B) OCR fallback (VNRecognizeTextRequest)
//      Active when: full VLM pipeline is unavailable or disabled.
//      Always labeled as "OCR fallback" with an explicit reason — never presented as VLM output.
//
// The vision encoder (fastvithd.mlpackage) is NOT run without the decoder.
// Running the encoder and discarding its output would be wasteful and misleading.

@MainActor
final class AnalysisService: ObservableObject {
    // MARK: - Published state

    @Published var analysisResults: [AnalysisResult] = []
    @Published var activeResult: AnalysisResult?
    @Published var isAnalyzing = false
    @Published var fps: Double = 0
    @Published var statusMessage: String = "Starting…"
    /// True only when the FULL pipeline (encoder + projector + decoder + tokenizer) is ready.
    /// Never true when only the encoder is loaded — that is not enough to generate text.
    @Published var fastVLMLoaded = false
    @Published var fastVLMStatus = FastVLMComponentStatus()

    // MARK: - Services
    //
    // Code Mode is now tap-to-capture (CodeModeController: OCR + code LLM, no
    // VLM), so the per-frame text-region detector and the auto-capture loop
    // that fed the old code overlays are gone. AnalysisService now serves two
    // callers only: the live VISUAL caption loop and IMPORTED images (share
    // extension / document scanner).
    private let fastVLM = FastVLMService.shared   // shared instance so SettingsView reflects real state
    private let ocr = OCRService()
    private let camera: CameraService
    private var fastVLMStatusCancellable: AnyCancellable?
    private var analysisTask: Task<Void, Never>?
    private var cancelledResultIDs: Set<UUID> = []

    // FPS tracking
    private var fpsFrameTimes: [Date] = []
    private let fpsWindowSize = 30
    /// Internal rolling fps value — updated every frame. The @Published `fps`
    /// is only refreshed from this at ~3Hz to keep SwiftUI from re-rendering
    /// every camera HUD subscriber 30 times a second (the glass/material
    /// buttons on the right column were the visible cost).
    private var fpsInternal: Double = 0
    private var lastFPSPublish: Date = .distantPast

    // Latest frame for manual capture
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestFrameIndex: Int = 0

    // MARK: - Init

    init(camera: CameraService) {
        self.camera = camera
        fastVLMStatusCancellable = fastVLM.$componentStatus
            .sink { [weak self] status in
                self?.fastVLMStatus = status
                self?.fastVLMLoaded = status.canGenerate
            }
    }

    // MARK: - Setup

    func start() async {
        camera.delegate = self
        camera.configure()

        await loadModels()
        camera.start()
    }

    private func loadModels() async {
        // FastVLM is NO LONGER auto-loaded here. The previous shape kicked
        // off fastVLM.load() the instant the lens tab opened, which on
        // some devices SIGABRTed inside the MLX Metal queue (the
        // `mlx::core::gpu::check_error` path) before the user had a chance
        // to interact with anything. The load now happens lazily on the
        // first capture (streamAnalysis → fastVLM.analyze), gated by the
        // user-initiated capture button — so opening the lens tab is a
        // pure camera-preview operation with no GPU upload.
        //
        // We still update the surface status so the UI knows whether the
        // user is on FastVLM or a custom VLM.
        let visionSelection = LocalModelRegistry.storedVisionSelectionID(
            AppSettings.shared.cameraVisualModelID
        )
        if !LocalModelRegistry.isDefaultVisionSelection(visionSelection) {
            fastVLMStatus = FastVLMComponentStatus()
            fastVLMLoaded = false
            statusMessage = "Custom VLM active"
            return
        }
        fastVLMStatus = fastVLM.componentStatus
        fastVLMLoaded = fastVLM.componentStatus.canGenerate
        statusMessage = fastVLMLoaded
            ? "FastVLM ready"
            : "FastVLM standby — first capture will load it"
    }

    // MARK: - Capture source
    //
    // Tells the orientation step whether the input is a sensor-native
    // landscape buffer (needs `.right` rotation to become world-up
    // portrait) or an already-oriented image (skip rotation).
    //
    // The camera path delivers AVCaptureSession buffers — sensor-
    // native landscape, always. The imported path delivers
    // pre-staged UIImages from share extension / photo picker /
    // file picker — those carry their own orientation metadata and
    // are already upright. Applying `.right` to an already-portrait
    // imported image flips it to landscape, which is the bug that
    // produced "raw=182×412 → portrait=412×182" in validation logs.
    //
    // `.unknown` exists as a defensive fallback for any call path
    // I missed in this refactor — it picks based on aspect: input
    // wider-than-tall is treated as camera, taller-than-wide is
    // treated as imported. Wrong for landscape-imported images
    // (much rarer than the current bug), but right for everything
    // else.
    enum CaptureSource {
        case camera        // live AVCaptureSession buffer, needs .right
        case imported      // pre-oriented UIImage, skip rotation
        case unknown       // fall back to aspect heuristic
    }

    // MARK: - Manual analysis trigger

    /// Analyzes a UIImage that came in from the share extension.
    /// Converts it to a pixel buffer and routes through the normal pipeline.
    func analyzeImportedImage(_ image: UIImage) {
        guard !isAnalyzing else { return }
        guard let pb = AnalysisService.pixelBuffer(from: image) else {
            ToastCenter.shared.error("Couldn't decode image")
            return
        }
        let detection = Detection(
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            confidence: 1.0,
            label: "Imported",
            classIndex: -1
        )
        triggerAnalysis(detection: detection, pixelBuffer: pb, source: .imported)
    }

    /// Converts a UIImage to a CVPixelBuffer for FastVLM/OCR consumption.
    static func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // Draw into sRGB (not DeviceRGB) so wide-gamut imports (Display P3
        // gallery photos, etc.) are color-converted by CoreGraphics instead of
        // silently reinterpreted — matching LensFramePreparer's sRGB forcing so
        // imported and live frames are normalized identically for the VLM.
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                        CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// Deep-copies a CVPixelBuffer into a standalone, pool-free buffer.
    ///
    /// The camera vends frames from a small CVPixelBufferPool. A captured frame
    /// is pinned for the *entire* analysis lifetime — held in the up-to-10
    /// `analysisResults` history (each result's CIImage lazily samples the
    /// underlying buffer) and read by the multi-second VLM/OCR call. Pinning
    /// several pool buffers at once starves the pool and stalls live capture.
    /// Copying once at capture time releases the pool buffer back immediately
    /// while everything downstream runs against memory we own.
    static func deepCopyPixelBuffer(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        let format = CVPixelBufferGetPixelFormatType(src)
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var dst: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         format, attrs as CFDictionary, &dst)
        guard status == kCVReturnSuccess, let dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        if CVPixelBufferIsPlanar(src) {
            let planeCount = CVPixelBufferGetPlaneCount(src)
            guard CVPixelBufferGetPlaneCount(dst) == planeCount else { return nil }
            for plane in 0..<planeCount {
                guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                      let dstBase = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { return nil }
                let srcBPR = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
                let dstBPR = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
                let planeH = CVPixelBufferGetHeightOfPlane(src, plane)
                let rowBytes = min(srcBPR, dstBPR)
                for row in 0..<planeH {
                    memcpy(dstBase + row * dstBPR, srcBase + row * srcBPR, rowBytes)
                }
            }
        } else {
            guard let srcBase = CVPixelBufferGetBaseAddress(src),
                  let dstBase = CVPixelBufferGetBaseAddress(dst) else { return nil }
            let srcBPR = CVPixelBufferGetBytesPerRow(src)
            let dstBPR = CVPixelBufferGetBytesPerRow(dst)
            let rowBytes = min(srcBPR, dstBPR)
            for row in 0..<height {
                memcpy(dstBase + row * dstBPR, srcBase + row * srcBPR, rowBytes)
            }
        }
        return dst
    }

    /// Live VISUAL caption capture — always feeds the whole frame to the VLM
    /// (SmolVLM describes the scene, not a text region). The only camera-side
    /// caller now that Code Mode owns its own tap-to-capture pipeline.
    func captureAndAnalyzeBest() {
        guard !isAnalyzing else { return }
        guard let liveBuffer = latestPixelBuffer else {
            statusMessage = "No frame available"
            return
        }
        // Snapshot out of the capture pool before the multi-second analysis
        // pins it (see deepCopyPixelBuffer). Fall back to the live buffer if
        // the copy fails so capture still works, just without the pool relief.
        let pixelBuffer = AnalysisService.deepCopyPixelBuffer(liveBuffer) ?? liveBuffer
        let captureID = UUID().uuidString.prefix(8)
        let pw = CVPixelBufferGetWidth(pixelBuffer)
        let ph = CVPixelBufferGetHeight(pixelBuffer)
        Diagnostics.shared.breadcrumb(
            "capture \(captureID) raw=\(pw)×\(ph) frameIdx=\(latestFrameIndex)",
            category: "analysis"
        )
        let detection = Detection(
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            confidence: 1.0,
            label: "Full Frame",
            classIndex: -1
        )
        triggerAnalysis(detection: detection, pixelBuffer: pixelBuffer, source: .camera)
    }

    // MARK: - Analysis pipeline

    private func triggerAnalysis(detection: Detection, pixelBuffer: CVPixelBuffer, source: CaptureSource = .unknown) {
        isAnalyzing = true
        statusMessage = "Analyzing…"

        // Build placeholder result so the panel can open immediately and
        // watch text stream in via the live binding.
        //
        // Both remaining callers (visual caption + imported images) analyse
        // the WHOLE frame — there's no detection crop anymore — so the VLM
        // and OCR fallback share one buffer.
        let workingBuffer: CVPixelBuffer = pixelBuffer
        let ocrBuffer: CVPixelBuffer = pixelBuffer
        let mode = AnalysisMode(rawValue: AppSettings.shared.analysisMode) ?? .code
        let ciImage = CIImage(cvPixelBuffer: workingBuffer)
        let thumb = AnalysisService.makeThumbnail(from: ciImage, maxDim: 240)

        let placeholderID = UUID()
        let placeholder = AnalysisResult(
            id: placeholderID,
            detection: detection,
            extractedCode: "",
            reviewMarkdown: "",
            mode: mode,
            ocrFallback: false,
            fallbackReason: nil,
            thumbnail: thumb,
            ciImage: ciImage,
            isStreaming: true
        )
        self.analysisResults.insert(placeholder, at: 0)
        if self.analysisResults.count > 10 { self.analysisResults.removeLast() }
        self.activeResult = placeholder

        analysisTask?.cancel()
        analysisTask = Task {
            await self.streamAnalysis(
                resultID: placeholderID,
                detection: detection,
                pixelBuffer: workingBuffer,
                ocrBuffer: ocrBuffer,
                ciImage: ciImage,
                thumb: thumb,
                source: source,
                mode: mode
            )
            if !Task.isCancelled {
                self.analysisTask = nil
            }
        }
    }

    // MARK: - Streaming analysis (FastVLM-first, OCR fallback)

    /// Drives the pre-created placeholder result to completion. Updates
    /// `extractedCode` token-by-token so the UI can stream.
    private func streamAnalysis(
        resultID: UUID,
        detection: Detection,
        pixelBuffer: CVPixelBuffer,    // VLM input — always the full frame
        ocrBuffer: CVPixelBuffer,      // OCR input — also the full frame (the code-mode crop path was removed)
        ciImage: CIImage,
        thumb: UIImage?,
        source: CaptureSource,
        mode: AnalysisMode
    ) async {
        // The Lens owns the active model slot. Even if a visual model is
        // already resident, wait for an Assistant generation/load to release
        // its native captures before dispatching this frame. This closes the
        // rapid tab-switch path where no VLM `switchTo` call was needed.
        await CodingAssistantService.shared.unloadAndWaitForCleanup()
        let genSettings = Self.fastVLMGenerationSettings(for: mode)

        // MLX-VLM path — takes precedence when the user has selected a
        // downloaded VLM (cameraVisualModelID non-empty). Falls through to
        // FastVLM when MLX VLM isn't ready or errors out so the camera tab
        // never goes dark.
        let effectiveVisionSelection = memorySafeVisionSelection(
            AppSettings.shared.cameraVisualModelID
        )
        let visionSelection = LocalModelRegistry.storedVisionSelectionID(
            effectiveVisionSelection
        )
        if !LocalModelRegistry.isDefaultVisionSelection(visionSelection) {
            let visionDescriptor = LocalModelRegistry.visualDescriptor(
                forStoredSelectionID: effectiveVisionSelection,
                catalog: ModelDownloadCenter.shared.models
            )
            let mlxVLMID = visionDescriptor.repoID
            let runtime = LocalModelRegistry.visionRuntime(
                forStoredSelectionID: effectiveVisionSelection,
                catalog: ModelDownloadCenter.shared.models
            )
            let mlxResult = await tryMLXVisionPath(
                resultID: resultID,
                ciImage: ciImage,
                mode: mode,
                desiredRepoID: mlxVLMID,
                source: source
            )
            if mlxResult { return }
            // The user explicitly chose a custom VLM. Surface its real error
            // instead of falling through and blaming FastVLM — that produced
            // the misleading "FastVLM not compatible" message.
            let vlmName = mlxVLMID.components(separatedBy: "/").last ?? mlxVLMID
            let vlmError: String
            if let reason = DeviceSafetyMonitor.shared.stopReason {
                vlmError = "\(vlmName): \(reason.detail)"
            } else if runtime == .llamaCpp,
               case .failed(let msg) = LlamaCppVLMService.shared.state {
                vlmError = "\(vlmName): \(msg)"
            } else if case .failed(let msg) = MLXVisionService.shared.state {
                vlmError = "\(vlmName): \(msg)"
            } else if case .loading(let msg) = MLXVisionService.shared.state {
                vlmError = "\(vlmName) is still loading (\(msg)). Wait a moment and tap again."
            } else if case .unloaded = MLXVisionService.shared.state {
                vlmError = "\(vlmName) isn't loaded. Tap again to retry, or pick a smaller model (Qwen3-VL-2B) if the device is warm."
            } else {
                vlmError = "\(vlmName) could not process this frame. If the phone is hot, let it cool — or select Qwen3-VL-2B in the camera toolbar."
            }
            await MainActor.run {
                self.updateResult(id: resultID) { r in
                    r.extractedCode = vlmError
                    r.isStreaming = false
                }
                self.isAnalyzing = false
                self.statusMessage = "Vision model error"
            }
            return
        }

        // FastVLM path
        //
        // Lazy load: AnalysisService.start() no longer warms FastVLM on
        // tab open (it used to SIGABRT inside Metal before the user could
        // do anything). The first capture is now the trigger — if weights
        // are on disk but not in memory yet, kick the load before trying
        // to analyze.
        if AppSettings.shared.fastVLMEnabled, !fastVLM.componentStatus.canGenerate {
            await MainActor.run { self.statusMessage = "Loading FastVLM…" }
            await fastVLM.load()
            await MainActor.run {
                self.fastVLMStatus = self.fastVLM.componentStatus
                self.fastVLMLoaded = self.fastVLM.componentStatus.canGenerate
            }
        }
        if fastVLM.componentStatus.canGenerate, AppSettings.shared.fastVLMEnabled {
            do {
                var generatedText = ""
                let task: FastVLMTask = (mode == .visual) ? .describeImage : .extractCode
                let stream = fastVLM.analyze(pixelBuffer: pixelBuffer, task: task, settings: genSettings)
                for try await chunk in stream {
                    generatedText += chunk
                    let snapshot = generatedText
                    await MainActor.run {
                        self.updateResult(id: resultID) { r in
                            r.extractedCode = snapshot
                        }
                    }
                }
                // Done: finalize result
                if mode == .code {
                    let review = generatedText.isEmpty
                        ? "" : ocr.generateBasicReview(for: generatedText)
                    await MainActor.run {
                        self.updateResult(id: resultID) { r in
                            r.isStreaming = false
                            r.reviewMarkdown = review
                        }
                        self.isAnalyzing = false
                        self.statusMessage = "Analysis complete"
                    }
                } else {
                    await MainActor.run {
                        self.updateResult(id: resultID) { r in
                            r.isStreaming = false
                        }
                        self.isAnalyzing = false
                        self.statusMessage = "Visual analysis complete"
                    }
                }
                return

            } catch {
                // Visual mode has no OCR equivalent
                if mode == .visual || !AppSettings.shared.useOCRFallback {
                    let msg = mode == .visual
                        ? "FastVLM required for Visual mode. Error: \(error.localizedDescription)"
                        : "FastVLM generation failed:\n\(error.localizedDescription)"
                    await MainActor.run {
                        self.updateResult(id: resultID) { r in
                            r.extractedCode = msg
                            r.isStreaming = false
                        }
                        self.isAnalyzing = false
                        self.statusMessage = "Analysis failed"
                    }
                    return
                }
                // Fall through to OCR replacement on the full frame (the
                // detection-crop path was removed). Suggest the visual-model
                // picker as the recovery path — a clearer next step than
                // "FastVLM error: ..." alone.
                let reason = "OCR fallback — FastVLM error: \(error.localizedDescription)"
                await replaceWithOCR(resultID: resultID,
                                     pixelBuffer: ocrBuffer,
                                     reason: reason,
                                     suggestedAction: .pickVisualModel)
                return
            }
        }

        // No FastVLM path
        if mode == .visual {
            let missing = fastVLM.componentStatus.missingComponentsDescription
            // Action prioritisation:
            //   • disabled in Settings → toggle it back on (.enableFastVLM)
            //   • enabled but encoder missing → guide them to pick a VLM
            //     from the onboarding picker (faster path — SmolVLM2 ships
            //     bundled, no extra download) rather than offering only
            //     the FastVLM download.
            let isEnabled = AppSettings.shared.fastVLMEnabled
            let reason = isEnabled
                ? "FastVLM \(missing) not available. Pick a visual model to enable Visual mode."
                : "FastVLM is disabled. Enable it in Settings, or pick a visual model below."
            let action: AnalysisResult.SuggestedAction = isEnabled
                ? .pickVisualModel
                : .enableFastVLM
            await MainActor.run {
                self.updateResult(id: resultID) { r in
                    r.isStreaming = false
                    r.fallbackReason = reason
                    r.suggestedAction = action
                }
                self.isAnalyzing = false
                self.statusMessage = "Visual mode unavailable"
            }
            return
        }

        // Code mode → OCR fallback on the full frame (no crop). The OCR
        // result is still useful, and we surface the FastVLM-missing reason +
        // suggested action so the user can upgrade the experience.
        let missing = fastVLM.componentStatus.missingComponentsDescription
        let isEnabled = AppSettings.shared.fastVLMEnabled
        let reason = isEnabled
            ? "OCR fallback — FastVLM \(missing) not available.\nPick a visual model for better-quality extraction."
            : "OCR fallback — FastVLM disabled in settings."
        let action: AnalysisResult.SuggestedAction = isEnabled
            ? .pickVisualModel
            : .enableFastVLM
        await replaceWithOCR(resultID: resultID, pixelBuffer: ocrBuffer, reason: reason, suggestedAction: action)
    }

    /// Resolve an unsafe MLX visual selection to a small installed Lens model.
    /// The Assistant selection is intentionally untouched: a unified package
    /// such as Bonsai 27B can fit with a bounded text cache while its image
    /// activations exceed the iPhone process limit. Persisting the Lens
    /// fallback gives each tab an honest independent choice and prevents every
    /// capture from retrying the impossible VLM load.
    private func memorySafeVisionSelection(_ storedSelection: String) -> String {
        let selection = LocalModelRegistry.storedVisionSelectionID(storedSelection)
        guard !LocalModelRegistry.isDefaultVisionSelection(selection) else {
            return storedSelection
        }

        let catalog = ModelDownloadCenter.shared.models
        let descriptor = LocalModelRegistry.visualDescriptor(
            forStoredSelectionID: storedSelection,
            catalog: catalog
        )
        guard LocalModelRegistry.visionRuntime(
            forStoredSelectionID: storedSelection,
            catalog: catalog
        ) == .mlx else {
            return storedSelection
        }

        let required = LensInferenceLoop.requiredVisionLoadBytes(
            repoID: descriptor.repoID
        )
        let available = UInt64(max(0, MemoryAdvisor.availableMemoryForModel))
        guard available < required else { return storedSelection }

        let bundled = BundledVLMInstaller.bundledRepoID
        let fallbackSelection: String
        if LlamaCppVLMService.stagedDirectory(for: bundled) != nil {
            fallbackSelection = bundled
        } else {
            // FastVLM is the zero-download last resort and still falls through
            // to OCR if one of its optional components is unavailable.
            fallbackSelection = LocalModelRegistry.defaultVisionSelectionID
        }

        LocalModelRegistry.setVisionSelection(fallbackSelection)
        Diagnostics.shared.notice(
            "Lens role fallback · requested=\(descriptor.repoID) · selected=\(fallbackSelection) · required=\(Int64(required).formattedBytes) · available=\(Int64(available).formattedBytes)",
            category: "lens"
        )
        ToastCenter.shared.info(
            "Lens switched to a safe model",
            detail: "\(descriptor.displayName) remains available in Assistant. Lens is using \(fallbackSelection == bundled ? "SmolVLM2" : "FastVLM") to avoid an out-of-memory restart."
        )
        return fallbackSelection
    }

    private func replaceWithOCR(
        resultID: UUID,
        pixelBuffer: CVPixelBuffer,
        reason: String,
        suggestedAction: AnalysisResult.SuggestedAction? = nil
    ) async {
        let text = (try? await ocr.extractText(from: pixelBuffer)) ?? "Could not extract text."
        let review = ocr.generateBasicReview(for: text)
        await MainActor.run {
            self.updateResult(id: resultID) { r in
                r.extractedCode = text
                r.reviewMarkdown = review
                r.isStreaming = false
                r.fallbackReason = reason
                r.suggestedAction = suggestedAction
            }
            // OCR mode forces code mode rendering
            if let idx = self.analysisResults.firstIndex(where: { $0.id == resultID }) {
                let r = self.analysisResults[idx]
                var rebuilt = AnalysisResult(
                    id: r.id, detection: r.detection,
                    extractedCode: r.extractedCode, reviewMarkdown: r.reviewMarkdown,
                    mode: .code, ocrFallback: true,
                    fallbackReason: r.fallbackReason,
                    timestamp: r.timestamp, thumbnail: r.thumbnail, ciImage: r.ciImage,
                    isStreaming: false, questionAnswers: r.questionAnswers
                )
                rebuilt.suggestedAction = r.suggestedAction
                self.analysisResults[idx] = rebuilt
                if self.activeResult?.id == resultID {
                    self.activeResult = self.analysisResults[idx]
                }
            }
            self.isAnalyzing = false
            self.statusMessage = "OCR fallback complete"
        }
    }

    /// Mutates the matching stored result and `activeResult` together.
    private func updateResult(id: UUID, _ apply: (inout AnalysisResult) -> Void) {
        guard !cancelledResultIDs.contains(id) else { return }
        if let i = analysisResults.firstIndex(where: { $0.id == id }) {
            apply(&analysisResults[i])
        }
        if activeResult?.id == id, var live = activeResult {
            apply(&live)
            activeResult = live
        }
    }

    // MARK: - Ask a follow-up question about a result

    /// Re-runs FastVLM in `answerQuestion` mode using the same image that
    /// produced `result`. Appends a streaming `QAExchange` to `result` and
    /// also updates `activeResult` if it matches.
    func askQuestion(_ question: String, about result: AnalysisResult) {
        guard let ciImage = result.ciImage else { return }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard fastVLM.componentStatus.canGenerate, AppSettings.shared.fastVLMEnabled else { return }

        // Insert a placeholder exchange
        let exchange = AnalysisResult.QAExchange(question: question, answer: "", isStreaming: true)
        appendExchange(exchange, to: result.id)

        Task { [weak self] in
            guard let self else { return }

            // Convert CIImage back to a CVPixelBuffer FastVLM can consume
            let pixelBuffer = self.makePixelBuffer(from: ciImage) ?? CVPixelBuffer?.none
            guard let pb = pixelBuffer else {
                self.completeExchange(id: exchange.id, in: result.id,
                                       finalText: "Unable to re-encode the captured image.",
                                       isStreaming: false)
                return
            }

            let genSettings = FastVLMGenerationSettings(
                maxTokens: AppSettings.shared.fastvlmMaxTokens,
                temperature: Float(AppSettings.shared.fastvlmTemperature),
                topP: 0.9,
                repetitionPenalty: 1.05,
                stopOnEOS: true
            )

            do {
                var streamed = ""
                let stream = self.fastVLM.analyze(
                    pixelBuffer: pb,
                    task: .answerQuestion(question),
                    settings: genSettings
                )
                for try await chunk in stream {
                    streamed += chunk
                    let snapshot = streamed
                    await MainActor.run {
                        self.updateExchange(id: exchange.id, in: result.id,
                                            answer: snapshot, isStreaming: true)
                    }
                }
                await MainActor.run {
                    self.updateExchange(id: exchange.id, in: result.id,
                                        answer: streamed, isStreaming: false)
                }
            } catch {
                await MainActor.run {
                    self.completeExchange(id: exchange.id, in: result.id,
                                          finalText: "Error: \(error.localizedDescription)",
                                          isStreaming: false)
                }
            }
        }
    }

    // MARK: - History management

    /// Re-opens a past result as the active result.
    func reopen(_ result: AnalysisResult) {
        activeResult = result
    }

    /// Cancels the current Lens request and prevents late native callbacks from
    /// mutating the captured result after the panel has been dismissed.
    func cancelCurrentAnalysis() {
        guard isAnalyzing || analysisTask != nil else { return }
        if let id = activeResult?.id {
            cancelledResultIDs.insert(id)
            updateCancelledResult(id: id)
        }
        analysisTask?.cancel()
        analysisTask = nil
        fastVLM.stopGeneration()
        MLXVisionService.shared.cancelCurrentInference()
        LlamaCppVLMService.shared.cancelCurrentInference()
        isAnalyzing = false
        statusMessage = "Analysis cancelled"
    }

    /// Hides the current frame from the Lens panel without deleting history.
    func dismissActiveResult() {
        activeResult = nil
    }

    private func updateCancelledResult(id: UUID) {
        if let index = analysisResults.firstIndex(where: { $0.id == id }) {
            analysisResults[index].isStreaming = false
        }
        if activeResult?.id == id {
            activeResult?.isStreaming = false
        }
    }

    /// Clears the history (memory only — no disk).
    func clearHistory() {
        analysisResults.removeAll()
        activeResult = nil
    }

    /// Removes a single result by id.
    func deleteResult(_ id: UUID) {
        analysisResults.removeAll { $0.id == id }
        if activeResult?.id == id { activeResult = nil }
    }

    // MARK: - Mutate stored exchange

    private func appendExchange(_ exchange: AnalysisResult.QAExchange, to resultID: UUID) {
        if let idx = analysisResults.firstIndex(where: { $0.id == resultID }) {
            analysisResults[idx].questionAnswers.append(exchange)
        }
        if activeResult?.id == resultID {
            activeResult?.questionAnswers.append(exchange)
        }
    }

    private func updateExchange(id: UUID, in resultID: UUID, answer: String, isStreaming: Bool) {
        if let i = analysisResults.firstIndex(where: { $0.id == resultID }),
           let j = analysisResults[i].questionAnswers.firstIndex(where: { $0.id == id }) {
            analysisResults[i].questionAnswers[j].answer = answer
            analysisResults[i].questionAnswers[j].isStreaming = isStreaming
        }
        if activeResult?.id == resultID,
           let j = activeResult?.questionAnswers.firstIndex(where: { $0.id == id }) {
            activeResult?.questionAnswers[j].answer = answer
            activeResult?.questionAnswers[j].isStreaming = isStreaming
        }
    }

    private func completeExchange(id: UUID, in resultID: UUID, finalText: String, isStreaming: Bool) {
        updateExchange(id: id, in: resultID, answer: finalText, isStreaming: isStreaming)
    }

    // MARK: - Image helpers

    /// Converts a CIImage back to a CVPixelBuffer for FastVLM consumption.
    private func makePixelBuffer(from ciImage: CIImage) -> CVPixelBuffer? {
        let width = Int(ciImage.extent.width)
        let height = Int(ciImage.extent.height)
        guard width > 0, height > 0 else { return nil }

        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
        guard let pb = out else { return nil }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        ctx.render(ciImage, to: pb)
        return pb
    }

    /// Creates a UIImage thumbnail of the analysed crop for the history gallery.
    static func makeThumbnail(from ciImage: CIImage, maxDim: CGFloat) -> UIImage? {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(maxDim / extent.width, maxDim / extent.height, 1.0)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - FPS tracking

    private func updateFPS() {
        let now = Date()
        fpsFrameTimes.append(now)
        if fpsFrameTimes.count > fpsWindowSize {
            fpsFrameTimes.removeFirst()
        }
        if fpsFrameTimes.count > 1 {
            let elapsed = now.timeIntervalSince(fpsFrameTimes.first!)
            fpsInternal = Double(fpsFrameTimes.count - 1) / elapsed
        }
        // Throttle the @Published assignment to ~3Hz. Any @ObservedObject
        // upstream (the whole camera root view) was previously re-evaluating
        // its body on every assignment — i.e. once per camera frame.
        if now.timeIntervalSince(lastFPSPublish) >= 0.33 {
            lastFPSPublish = now
            fps = fpsInternal
        }
    }
}

private extension AnalysisService {
    /// Visual Lens refreshes happen repeatedly from the camera tab, so keep
    /// captions short even if the user allows longer code/assistant outputs.
    /// Code mode remains a one-shot and can use the full FastVLM setting.
    static func maxTokens(for mode: AnalysisMode) -> Int {
        let requested = AppSettings.shared.fastvlmMaxTokens
        return mode == .visual ? min(128, requested) : requested
    }

    static func fastVLMGenerationSettings(for mode: AnalysisMode) -> FastVLMGenerationSettings {
        FastVLMGenerationSettings(
            maxTokens: maxTokens(for: mode),
            temperature: Float(AppSettings.shared.fastvlmTemperature),
            topP: 0.9,
            repetitionPenalty: 1.05,
            stopOnEOS: true
        )
    }
}

// MARK: - Orientation helper
//
// Mirrors `LensFramePreparer.correctedOrientation`. The two should
// stay in sync — both translate the device's physical orientation
// into the `CGImagePropertyOrientation` that un-rotates the world
// content inside the portrait-locked camera buffer.
//
// Buffer-up matches world-up when device is in portrait (because
// the camera connection's videoRotationAngle = 90 has already
// rotated the sensor-native landscape frame to portrait). The
// landscape device orientations are where the rotation comes back:
// the buffer stays portrait-shaped, but the world content inside
// it is rotated 90° one way or the other, and we apply the inverse
// to recover.
//
// `.unknown` / `.faceUp` / `.faceDown` all return `.up` (best-
// effort default). At launch UIDevice.orientation often reports
// `.unknown` until the first motion sample; the .up default is
// correct for the most common case of a user opening the app
// while holding the phone in portrait.

extension AnalysisService {
    fileprivate static func cgOrientation(for device: UIDeviceOrientation) -> CGImagePropertyOrientation {
        switch device {
        case .portrait:            return .up
        case .portraitUpsideDown:  return .down
        case .landscapeLeft:       return .left
        case .landscapeRight:      return .right
        case .faceUp, .faceDown, .unknown:
            return .up
        @unknown default:          return .up
        }
    }
}

// MARK: - CameraServiceDelegate

extension AnalysisService: CameraServiceDelegate {
    nonisolated func cameraService(_ service: CameraService, didOutput pixelBuffer: CVPixelBuffer, frameIndex: Int) {
        // No per-frame text-region detection anymore: Code Mode is tap-to-
        // capture and Visual mode reads the whole frame, so nothing consumes
        // detections. We just keep the latest frame + FPS up to date.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.latestPixelBuffer = pixelBuffer
            self.latestFrameIndex = frameIndex
            self.updateFPS()
            // Live OCR is an opt-in overlay (toolbar toggle, off by default).
            // process() no-ops immediately when disabled and self-throttles when
            // on, so this is effectively free unless the user turned it on.
            LiveOCRService.shared.process(pixelBuffer: pixelBuffer)
        }
    }

    // MARK: - MLX VLM routing

    /// Runs the user-selected MLX-format VLM against this frame. Returns
    /// true on success (UI was updated through to completion); false when
    /// the MLX VLM wasn't usable and the caller should fall back to FastVLM.
    @MainActor
    private func tryMLXVisionPath(
        resultID: UUID,
        ciImage: CIImage,
        mode: AnalysisMode,
        desiredRepoID: String,
        source: CaptureSource = .unknown
    ) async -> Bool {
        // Tiny-image guard. VLMs need at least a roughly text-sized
        // input to produce useful captions; anything smaller wastes
        // the memory budget and produces hallucinated descriptions
        // of the tile's color (a single text-line crop is the
        // canonical example — 11×41 px coming out of the new
        // VNDetectTextRectanglesRequest path). Refuse early with a
        // clear status message instead.
        let inputW = ciImage.extent.width
        let inputH = ciImage.extent.height
        let minSide: CGFloat = 96
        if inputW < minSide || inputH < minSide {
            updateResult(id: resultID) { r in
                r.extractedCode = "Input too small (\(Int(inputW))×\(Int(inputH))) — point the camera at a wider area of the screen."
                r.isStreaming = false
            }
            isAnalyzing = false
            statusMessage = "Frame too small"
            return true   // we owned the result; don't fall through to FastVLM
        }

        // Backend routing: GGUF VLMs run through llama.cpp + mtmd
        // (LlamaCppVLMService), everything else runs through MLX
        // (MLXVisionService / LensInferenceLoop). The MLX path
        // handles Qwen2-VL / Qwen3-VL / Gemma 3 / LLaVA etc.; the
        // GGUF path handles SmolVLM2 family (broken upstream in
        // MLX) plus any other GGUF VLM the user downloads.
        //
        // Detection by repoID substring is sufficient — every
        // GGUF VLM on HuggingFace has "GGUF" in its repo name by
        // convention, and we don't currently support GGUF LLMs
        // (the chat tab is MLX-only).
        let runtime = LocalModelRegistry.visionRuntime(
            forStoredSelectionID: desiredRepoID,
            catalog: ModelDownloadCenter.shared.models
        )
        if runtime == .llamaCpp {
            return await tryLlamaCppVisionPath(
                resultID: resultID,
                ciImage: ciImage,
                mode: mode,
                desiredRepoID: desiredRepoID,
                source: source
            )
        }

        let vision = MLXVisionService.shared

        // Ensure the right model is loaded. switchTo() is idempotent for a
        // healthy same-repo load, but a prior describe() error leaves the
        // container resident in `.failed` — without re-entering switchTo the
        // guard below always fails and the UI shows the generic
        // "could not process this frame" forever. Match the llama.cpp path:
        // retry when state isn't `.ready` even if the repo id matches.
        let shouldSwitch: Bool = {
            if vision.activeRepoID != desiredRepoID { return true }
            if case .ready = vision.state { return false }
            return true
        }()
        if shouldSwitch {
            await vision.switchTo(repoID: desiredRepoID)
        }
        // Surface the real stop reason (heat / memory) instead of a blank
        // "could not process" when the device is actively refusing work.
        if let reason = DeviceSafetyMonitor.shared.stopReason {
            let short = desiredRepoID.components(separatedBy: "/").last ?? desiredRepoID
            updateResult(id: resultID) { r in
                r.extractedCode = "\(short): \(reason.detail)"
                r.isStreaming = false
            }
            isAnalyzing = false
            statusMessage = reason.title
            return true
        }
        guard case .ready = vision.state else { return false }

        // Convert CIImage → UIImage for the service's API.
        //
        // Orientation: the CameraService connection has
        // `videoRotationAngle = 90`, which means the buffer arrives
        // PORTRAIT — bytes are already in portrait layout regardless
        // of physical device orientation. So camera buffers do NOT
        // need an unconditional `.right` rotation (which is what an
        // earlier version did and what produced "raw=70×90 portrait
        // → 90×70 landscape" double-rotation bug).
        //
        // What CAN still be wrong: when the device is held physically
        // landscape, the world content INSIDE the portrait-locked
        // buffer is rotated, and we need to un-rotate via
        // CGImagePropertyOrientation. Same logic
        // LensFramePreparer.correctedOrientation uses for the
        // streaming path. Duplicated here for the describe path
        // because that path doesn't currently route through
        // LensFramePreparer — a future cleanup should unify them.
        //
        // Three sub-cases by source:
        //   .camera   : read UIDevice.orientation, apply matching CG.
        //               portrait → .up (no rotation), landscape →
        //               .left / .right.
        //   .imported : skip rotation entirely. Imported UIImages
        //               carry their own orientation metadata and
        //               are already world-up.
        //   .unknown  : aspect heuristic (wider-than-tall → rotate,
        //               taller-than-wide → skip).
        let cgOrient: CGImagePropertyOrientation = {
            switch source {
            case .camera:
                return Self.cgOrientation(for: UIDevice.current.orientation)
            case .imported:
                return .up
            case .unknown:
                return ciImage.extent.width >= ciImage.extent.height
                    ? Self.cgOrientation(for: UIDevice.current.orientation)
                    : .up
            }
        }()
        let renderCtx = CIContext()
        let oriented = (cgOrient == .up) ? ciImage : ciImage.oriented(cgOrient)
        guard let cg = renderCtx.createCGImage(oriented, from: oriented.extent) else {
            return false
        }
        let uiImage = UIImage(cgImage: cg)
        // Debug trace: log dimensions + source + the resolved CG
        // orientation so the validation pass can tell at a glance
        // both what was decided and why.
        Diagnostics.shared.breadcrumb(
            "orient: raw=\(Int(ciImage.extent.width))×\(Int(ciImage.extent.height)) source=\(source) device=\(UIDevice.current.orientation.rawValue) cgOrient=\(cgOrient.rawValue) → out=\(cg.width)×\(cg.height)",
            category: "analysis"
        )

        // Mode-specific prompt. Code mode is intentionally directive so the
        // model emits raw code rather than narrative. Visual mode reads the
        // user's LensPromptPreset so "Detailed", "Find errors", etc. actually
        // steer the model instead of always emitting a one-line description.
        let prompt: String = {
            if mode == .code {
                return "Transcribe ALL visible code/text exactly as shown. Use fenced code blocks. No explanation."
            }
            let settings = AppSettings.shared
            let custom = settings.lensCustomPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty { return custom }
            return LensPromptPreset.from(rawValue: settings.lensPromptPresetID).prompt
        }()

        // Stream tokens into the existing placeholder result.
        let snapID = resultID
        // Cap per-capture maxTokens for the live caption burst. Each token
        // grows the KV cache, and on a real iPhone running SmolVLM2 the
        // cumulative residency across rapid-fire captures tips
        // the GPU into iokit_user_client_trap returning an error mid-decode
        // — fatal via mlx::core::gpu::check_error. 128 tokens is plenty for
        // a 1–3 sentence caption (the live UI hides anything past 5 lines
        // anyway) and bounds the worst-case KV cache. Code mode still gets
        // the user's full setting since it's a one-shot, not a loop.
        let safeMaxTokens = Self.maxTokens(for: mode)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            final class Acc: @unchecked Sendable { var value = "" }
            let acc = Acc()
            vision.describe(
                image: uiImage,
                prompt: prompt,
                maxTokens: safeMaxTokens,
                onToken: { token in
                    acc.value += token
                    let snapshot = acc.value
                    Task { @MainActor [weak self] in
                        self?.updateResult(id: snapID) { r in
                            r.extractedCode = snapshot
                        }
                    }
                },
                onComplete: { _ in
                    Task { @MainActor [weak self] in
                        guard let self else { cont.resume(); return }
                        let final = acc.value
                        let review = (mode == .code && !final.isEmpty)
                            ? self.ocr.generateBasicReview(for: final)
                            : ""
                        self.updateResult(id: snapID) { r in
                            r.isStreaming = false
                            r.reviewMarkdown = review
                        }
                        self.isAnalyzing = false
                        self.statusMessage = "Analysis complete"
                        cont.resume()
                    }
                }
            )
        }
        return true
    }

    // MARK: - llama.cpp VLM routing (GGUF models via mtmd)
    //
    // Mirrors `tryMLXVisionPath` structurally but uses
    // LlamaCppVLMService. SmolVLM2 family in particular needs this
    // path because MLX's integration is broken upstream — see
    // LENS_PIPELINE.md.
    //
    // The orientation / source handling is identical to the MLX
    // path; the only differences are which service we drive and
    // which state we observe for the .ready guard.
    @MainActor
    private func tryLlamaCppVisionPath(
        resultID: UUID,
        ciImage: CIImage,
        mode: AnalysisMode,
        desiredRepoID: String,
        source: CaptureSource
    ) async -> Bool {
        let llama = LlamaCppVLMService.shared

        let shouldSwitch: Bool = {
            if llama.activeRepoID != desiredRepoID { return true }
            if case .ready = llama.state { return false }
            // An inference error leaves the weights resident but marks the
            // service .failed. Re-enter switchTo(); same-repo + resident model
            // resets the state to .ready so the user can retry after a fix.
            return true
        }()
        if shouldSwitch {
            await llama.switchTo(repoID: desiredRepoID)
        }
        guard case .ready = llama.state else { return false }

        // Same orientation logic as tryMLXVisionPath. Camera buffers
        // are portrait-locked by the connection; we apply the
        // device-orientation-derived CG orientation to recover
        // world-up. Imported images are already oriented.
        let cgOrient: CGImagePropertyOrientation = {
            switch source {
            case .camera:
                return Self.cgOrientation(for: UIDevice.current.orientation)
            case .imported:
                return .up
            case .unknown:
                return ciImage.extent.width >= ciImage.extent.height
                    ? Self.cgOrientation(for: UIDevice.current.orientation)
                    : .up
            }
        }()
        let renderCtx = CIContext()
        let oriented = (cgOrient == .up) ? ciImage : ciImage.oriented(cgOrient)
        guard let cg = renderCtx.createCGImage(oriented, from: oriented.extent) else {
            return false
        }
        let uiImage = UIImage(cgImage: cg)
        Diagnostics.shared.breadcrumb(
            "llama orient: raw=\(Int(ciImage.extent.width))×\(Int(ciImage.extent.height)) source=\(source) device=\(UIDevice.current.orientation.rawValue) cgOrient=\(cgOrient.rawValue) → out=\(cg.width)×\(cg.height)",
            category: "analysis"
        )

        let prompt: String = {
            if mode == .code {
                return "Transcribe ALL visible code/text exactly as shown. Use fenced code blocks. No explanation."
            }
            let settings = AppSettings.shared
            let custom = settings.lensCustomPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty { return custom }
            return LensPromptPreset.from(rawValue: settings.lensPromptPresetID).prompt
        }()

        let snapID = resultID
        let safeMaxTokens = Self.maxTokens(for: mode)
        let modelName = desiredRepoID.components(separatedBy: "/").last ?? desiredRepoID

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            final class Acc: @unchecked Sendable { var value = "" }
            let acc = Acc()
            llama.describe(
                image: uiImage,
                prompt: prompt,
                maxTokens: safeMaxTokens,
                onToken: { token in
                    acc.value += token
                    let snapshot = acc.value
                    Task { @MainActor [weak self] in
                        self?.updateResult(id: snapID) { r in
                            r.extractedCode = snapshot
                        }
                    }
                },
                onComplete: { _ in
                    Task { @MainActor [weak self] in
                        guard let self else { cont.resume(); return }
                        let final = acc.value
                        if final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           case .failed(let msg) = llama.state {
                            self.updateResult(id: snapID) { r in
                                r.extractedCode = "\(modelName): \(msg)"
                                r.isStreaming = false
                            }
                            self.isAnalyzing = false
                            self.statusMessage = "Vision model error"
                            cont.resume()
                            return
                        }
                        let review = (mode == .code && !final.isEmpty)
                            ? self.ocr.generateBasicReview(for: final)
                            : ""
                        self.updateResult(id: snapID) { r in
                            r.isStreaming = false
                            r.reviewMarkdown = review
                        }
                        self.isAnalyzing = false
                        self.statusMessage = "Analysis complete"
                        cont.resume()
                    }
                }
            )
        }
        return true
    }
}
