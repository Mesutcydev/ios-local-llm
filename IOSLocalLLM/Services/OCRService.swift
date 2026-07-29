import Vision
import CoreImage
import UIKit

// MARK: - OCRService
// Uses VNRecognizeTextRequest as a fallback when FastVLM is unavailable.
// Produces clean extracted text from a cropped terminal image.

final class OCRService {
    // MARK: - Extract text

    func extractText(from pixelBuffer: CVPixelBuffer) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                // Sort top-to-bottom, left-to-right (Vision origin is bottom-left)
                let sorted = observations.sorted {
                    if abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.01 {
                        return $0.boundingBox.minY > $1.boundingBox.minY  // higher Y = upper line
                    }
                    return $0.boundingBox.minX < $1.boundingBox.minX
                }

                let text = sorted
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                continuation.resume(returning: text)
            }

            // Accurate mode for best code extraction quality
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false   // disable — we want exact code, not auto-corrected words
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.01

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Generate placeholder review

    func generateBasicReview(for code: String) -> String {
        let lines = code.components(separatedBy: "\n")
        let lineCount = lines.count
        let detectedLanguage = detectLanguage(in: code)

        return """
        ## Review (OCR Fallback — FastVLM unavailable)

        > **Note:** FastVLM model not loaded. Using on-device OCR for code extraction.
        > Add `FastVLMEncoder.mlpackage` and `FastVLMDecoder.mlpackage` to the app bundle for full AI analysis.

        **Detected Language:** \(detectedLanguage)
        **Lines of Code:** \(lineCount)

        \(detectBasicIssues(in: code, language: detectedLanguage))
        """
    }

    // MARK: - Simple language detection

    private func detectLanguage(in code: String) -> String {
        let lower = code.lowercased()
        if lower.contains("import swift") || lower.contains("var ") && lower.contains("let ") && lower.contains("func ") {
            return "Swift"
        } else if lower.contains("def ") && (lower.contains("import ") || lower.contains("self.")) {
            return "Python"
        } else if lower.contains("func ") && lower.contains("package ") {
            return "Go"
        } else if lower.contains("const ") || lower.contains("let ") || lower.contains("=>") {
            return "JavaScript/TypeScript"
        } else if lower.contains("public class ") || lower.contains("private void ") {
            return "Java/Kotlin"
        } else if lower.contains("#include") || lower.contains("std::") {
            return "C/C++"
        } else if lower.contains("fn ") && lower.contains("let mut") {
            return "Rust"
        }
        return "Unknown"
    }

    private func detectBasicIssues(in code: String, language: String) -> String {
        var findings: [String] = []

        // Generic code smell detection
        if code.contains("TODO") || code.contains("FIXME") || code.contains("HACK") {
            findings.append("- Unresolved TODO/FIXME comments found.")
        }
        if code.contains("password") || code.contains("secret") || code.contains("api_key") || code.contains("apikey") {
            findings.append("- **Security:** Possible hardcoded credentials or API keys detected.")
        }
        if code.contains("print(") || code.contains("console.log(") || code.contains("NSLog(") {
            findings.append("- Debug logging statements present — remove before production.")
        }
        let lines = code.components(separatedBy: "\n")
        let longLines = lines.filter { $0.count > 120 }
        if !longLines.isEmpty {
            findings.append("- \(longLines.count) line(s) exceed 120 characters — consider wrapping.")
        }

        if findings.isEmpty {
            return "**Quick Scan:** No obvious issues detected. Enable FastVLM for deep analysis."
        }
        return "**Quick Scan:**\n" + findings.joined(separator: "\n")
    }
}
