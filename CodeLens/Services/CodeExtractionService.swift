import Vision
import CoreImage
import CoreGraphics
import UIKit

// MARK: - CodeExtractionService
// Code Mode's extraction stage. Unlike a VLM (which paraphrases and drops
// symbols), Apple Vision's text recogniser transcribes exactly what's on the
// glass — the right tool for *faithful* code capture. Two things make this
// code-aware rather than prose-aware:
//
//   1. Language correction is OFF. Vision's autocorrect "fixes" `->` to `→`,
//      `==` to `=`, `i` to `I`, etc. Disabling it keeps operators intact.
//   2. Indentation is reconstructed. Vision returns trimmed line strings, so
//      leading whitespace is lost. We recover it from each line's left edge
//      relative to the leftmost line, quantised by an estimated character
//      width — good enough to make Python/YAML readable again.
//
// The result is handed to the code LLM (CodingAssistantService) for the
// explain / review / debug tasks. Extraction itself runs no model, so it
// works fully offline with nothing downloaded.

struct ExtractedCode {
    var code: String
    var language: String?      // best-effort, for syntax hints / prompt steering
    var lineCount: Int { code.isEmpty ? 0 : code.components(separatedBy: "\n").count }
}

final class CodeExtractionService {

    enum ExtractionError: Error { case noImage, recognitionFailed }

    // MARK: - Public entry points

    func extract(from pixelBuffer: CVPixelBuffer) async throws -> ExtractedCode {
        try await run { VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]) }
    }

    func extract(from image: UIImage) async throws -> ExtractedCode {
        guard let cg = image.cgImage else { throw ExtractionError.noImage }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await run { VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:]) }
    }

    // MARK: - Core

    private func run(_ makeHandler: @escaping () -> VNImageRequestHandler) async throws -> ExtractedCode {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let code = Self.reconstruct(from: observations)
                let language = Self.detectLanguage(in: code)
                continuation.resume(returning: ExtractedCode(code: code, language: language))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false   // keep operators/symbols exact
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.0           // capture small code too

            let handler = makeHandler()
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Layout reconstruction
    //
    // Vision gives one observation per recognised text run, each with a
    // normalised bounding box (bottom-left origin) and a string. We:
    //   1. Group observations into visual lines by vertical overlap.
    //   2. Within a line, order left-to-right and join with a single space
    //      (Vision already preserves intra-run spacing inside one string;
    //      multiple runs on a line are rare and a space is the safe join).
    //   3. Prepend reconstructed leading indentation from the line's left
    //      edge, quantised by an estimated character width.

    private struct Line {
        var minX: CGFloat
        var midY: CGFloat
        var height: CGFloat
        var runs: [(minX: CGFloat, text: String)]
        var text: String {
            runs.sorted { $0.minX < $1.minX }
                .map { $0.text }
                .joined(separator: " ")
        }
    }

    static func reconstruct(from observations: [VNRecognizedTextObservation]) -> String {
        let runs: [(box: CGRect, text: String)] = observations.compactMap { obs in
            guard let s = obs.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return (obs.boundingBox, s)
        }
        guard !runs.isEmpty else { return "" }

        // Cluster into lines by vertical overlap. Sort top-to-bottom first
        // (Vision Y increases upward, so descending minY == top-to-bottom).
        let sorted = runs.sorted { $0.box.midY > $1.box.midY }
        var lines: [Line] = []
        for run in sorted {
            let midY = run.box.midY
            let h = run.box.height
            // Same line if vertical centres are within ~60% of line height.
            if let idx = lines.firstIndex(where: { abs($0.midY - midY) < max($0.height, h) * 0.6 }) {
                lines[idx].runs.append((minX: run.box.minX, text: run.text))
                lines[idx].minX = min(lines[idx].minX, run.box.minX)
            } else {
                lines.append(Line(minX: run.box.minX, midY: midY, height: h,
                                  runs: [(minX: run.box.minX, text: run.text)]))
            }
        }

        // Estimate a per-image character width (normalised) so we can turn a
        // left-edge offset into a leading-space count. Use the median width-
        // per-character across all runs — robust to one giant/garbled run.
        let widthsPerChar: [CGFloat] = runs.compactMap { run in
            let n = run.text.count
            return n > 0 ? run.box.width / CGFloat(n) : nil
        }.sorted()
        let charW: CGFloat = widthsPerChar.isEmpty
            ? 0.01
            : widthsPerChar[widthsPerChar.count / 2]

        let leftMargin = lines.map(\.minX).min() ?? 0
        // Don't over-indent on noise: cap reconstructed indent at 40 spaces.
        let maxIndent = 40

        return lines.map { line -> String in
            let offset = line.minX - leftMargin
            var spaces = charW > 0 ? Int((offset / charW).rounded()) : 0
            if spaces < 0 { spaces = 0 }
            if spaces > maxIndent { spaces = maxIndent }
            return String(repeating: " ", count: spaces) + line.text
        }
        .joined(separator: "\n")
        // Trim trailing whitespace on each line. Intra-line double spaces are
        // intentionally left alone — collapsing them would corrupt string
        // literals. Only trailing cleanup is safe.
        .components(separatedBy: "\n")
        .map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
        .joined(separator: "\n")
    }

    // MARK: - Language detection
    //
    // Cheap, signal-counting heuristic — only used for syntax hints and to
    // gently steer the LLM prompt ("The code looks like Swift."). Never on the
    // critical path, so false positives are harmless.

    static func detectLanguage(in code: String) -> String? {
        guard !code.isEmpty else { return nil }
        let lower = code.lowercased()
        var scores: [String: Int] = [:]
        func bump(_ lang: String, _ present: Bool, _ weight: Int = 1) {
            if present { scores[lang, default: 0] += weight }
        }

        bump("Swift", lower.contains("func ") && (lower.contains("let ") || lower.contains("var ")))
        bump("Swift", lower.contains("import swiftui") || lower.contains("import foundation"), 2)
        bump("Swift", lower.contains("@state") || lower.contains("guard let "), 2)

        bump("Python", lower.contains("def ") && code.contains(":"))
        bump("Python", lower.contains("import ") && lower.contains("self."))
        bump("Python", lower.contains("print(") && !lower.contains(";"))
        bump("Python", lower.contains("elif ") || lower.contains("__init__"), 2)

        bump("JavaScript/TypeScript", lower.contains("const ") || lower.contains("=>"))
        bump("JavaScript/TypeScript", lower.contains("function ") || lower.contains("console.log("))
        bump("JavaScript/TypeScript", lower.contains("interface ") || lower.contains(": string"), 2)

        bump("Java/Kotlin", lower.contains("public class ") || lower.contains("private void "))
        bump("Java/Kotlin", lower.contains("fun ") && lower.contains("val "), 2)
        bump("Java/Kotlin", lower.contains("system.out.println"))

        bump("Go", lower.contains("func ") && lower.contains("package "))
        bump("Go", lower.contains(":=") || lower.contains("fmt."))

        bump("Rust", lower.contains("fn ") && (lower.contains("let mut") || lower.contains("->")))
        bump("Rust", lower.contains("println!") || lower.contains("impl "), 2)

        bump("C/C++", lower.contains("#include") || lower.contains("std::"))
        bump("C/C++", lower.contains("int main("))

        bump("Ruby", lower.contains("def ") && lower.contains("end"))
        bump("Shell", lower.contains("#!/bin/") || lower.contains("echo $"))

        guard let best = scores.max(by: { $0.value < $1.value }), best.value > 0 else {
            return nil
        }
        return best.key
    }
}

// MARK: - Orientation bridge

private extension CGImagePropertyOrientation {
    init(_ ui: UIImage.Orientation) {
        switch ui {
        case .up:            self = .up
        case .upMirrored:    self = .upMirrored
        case .down:          self = .down
        case .downMirrored:  self = .downMirrored
        case .left:          self = .left
        case .leftMirrored:  self = .leftMirrored
        case .right:         self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default:    self = .up
        }
    }
}
