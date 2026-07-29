import Foundation
import CoreImage
import UIKit

// MARK: - CodeModeController
// Drives the redesigned Code Mode flow, independent of the VLM-based
// AnalysisService. Pipeline:
//
//   tap shutter → high-res still → faithful OCR (CodeExtractionService)
//             → user picks a CodeTask → stream reasoning from the code LLM
//               (CodingAssistantService)
//
// Extraction needs no model; explain/review/debug reuse the same Qwen-Coder-
// class model that powers the chat tab — much stronger at code than a small
// on-device VLM, and no VLM has to be resident, which frees memory for it.

@MainActor
final class CodeModeController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case extracting          // OCR running on the captured still
        case ready               // extraction done, awaiting / running a task
        case failed(String)
    }

    // Capture + extraction
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var capturedImage: UIImage?
    @Published var extractedCode: String = ""        // editable by the user
    @Published private(set) var detectedLanguage: String?
    @Published private(set) var lineCount: Int = 0

    // Task / reasoning
    @Published var selectedTask: CodeTask = .extract
    @Published private(set) var taskOutput: String = ""
    @Published private(set) var isReasoning: Bool = false
    /// True when `.debug` was auto-suggested because the capture looked like
    /// an error/stack trace — lets the UI show a subtle "picked Debug" hint.
    @Published private(set) var autoPickedDebug: Bool = false

    private let extractor = CodeExtractionService()
    private let llm = CodingAssistantService.shared
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Capture entry point

    /// Begin a fresh Code Mode session from a freshly captured camera still.
    /// Renders the buffer world-up, runs extraction, and pre-selects a task.
    func begin(pixelBuffer: CVPixelBuffer, deviceOrientation: UIDeviceOrientation) {
        reset()
        phase = .extracting

        let image = render(pixelBuffer: pixelBuffer, deviceOrientation: deviceOrientation)
        capturedImage = image

        Task { [weak self] in
            guard let self else { return }
            do {
                let result: ExtractedCode
                if let image {
                    result = try await self.extractor.extract(from: image)
                } else {
                    result = try await self.extractor.extract(from: pixelBuffer)
                }
                self.extractedCode = result.code
                self.detectedLanguage = result.language
                self.lineCount = result.lineCount
                // Auto-pick Debug when the capture reads like an error.
                let suggested = CodeTask.suggested(for: result.code, default: .extract)
                self.selectedTask = suggested
                self.autoPickedDebug = (suggested == .debug)
                self.phase = .ready
                // Extraction task shows the code itself — populate immediately
                // so the result area isn't blank on first open.
                if suggested == .extract {
                    self.populateExtractOutput()
                } else {
                    self.runTask(suggested)
                }
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Task switching

    /// Run (or re-run) a task over the current extracted code.
    func runTask(_ task: CodeTask) {
        selectedTask = task
        guard phase == .ready else { return }

        let code = extractedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            taskOutput = "_No code was extracted. Try re-capturing with the text larger and in focus._"
            return
        }

        if task == .extract {
            populateExtractOutput()
            return
        }

        guard
            let system = task.systemPrompt(language: detectedLanguage),
            let user = task.userPrompt(code: code)
        else { return }

        // Cancel any in-flight generation by starting a fresh one; the service
        // serialises generate() calls internally.
        taskOutput = ""
        isReasoning = true

        let messages = [
            ChatMessage(role: .system, content: system),
            ChatMessage(role: .user, content: user)
        ]

        final class Acc: @unchecked Sendable { var value = "" }
        let acc = Acc()

        llm.generate(
            messages: messages,
            maxTokensOverride: 512,
            temperatureOverride: 0.3,
            onToken: { [weak self] token in
                acc.value += token
                let snapshot = acc.value
                Task { @MainActor in self?.taskOutput = snapshot }
            },
            onComplete: { [weak self] _ in
                Task { @MainActor in
                    self?.isReasoning = false
                    if (self?.taskOutput.isEmpty ?? true) {
                        self?.taskOutput = "_No response — the code model may still be loading. Try the task again._"
                    }
                }
            }
        )
    }

    /// `.extract` output is just the faithful code in a fenced block, so it's
    /// copyable / shareable like the LLM tasks.
    private func populateExtractOutput() {
        isReasoning = false
        let code = extractedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = detectedLanguage?.lowercased().components(separatedBy: "/").first ?? ""
        taskOutput = code.isEmpty
            ? "_No code detected._"
            : "```\(lang)\n\(code)\n```"
    }

    // MARK: - Outbound

    /// Markdown bundling the extracted code + the current task's output, for
    /// "Send to Chat" / share / snippet.
    var shareableMarkdown: String {
        var parts: [String] = []
        let code = extractedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !code.isEmpty {
            parts.append("## Captured code\n```\n\(code)\n```")
        }
        if selectedTask != .extract, !taskOutput.isEmpty {
            parts.append("## \(selectedTask.label.capitalized)\n\(taskOutput)")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Reset

    func reset() {
        phase = .idle
        capturedImage = nil
        extractedCode = ""
        detectedLanguage = nil
        lineCount = 0
        selectedTask = .extract
        taskOutput = ""
        isReasoning = false
        autoPickedDebug = false
    }

    // MARK: - Rendering

    /// CVPixelBuffer → world-up UIImage. Camera buffers are portrait-locked by
    /// the capture connection (videoRotationAngle = 90), so only the physical
    /// device orientation needs correcting — same logic AnalysisService uses
    /// for its VLM path.
    private func render(pixelBuffer: CVPixelBuffer, deviceOrientation: UIDeviceOrientation) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let orient = Self.cgOrientation(for: deviceOrientation)
        let oriented = (orient == .up) ? ci : ci.oriented(orient)
        guard let cg = ciContext.createCGImage(oriented, from: oriented.extent) else { return nil }
        return UIImage(cgImage: cg)   // .up orientation baked in
    }

    private static func cgOrientation(for device: UIDeviceOrientation) -> CGImagePropertyOrientation {
        switch device {
        case .portrait:           return .up
        case .portraitUpsideDown: return .down
        case .landscapeLeft:      return .left
        case .landscapeRight:     return .right
        default:                  return .up
        }
    }
}
