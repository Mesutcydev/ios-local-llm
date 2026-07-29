import Foundation

// MARK: - FastVLMGenerationResult
// Returned by FastVLMService.analyze() after a complete generation run.

struct FastVLMGenerationResult {
    /// The full generated text (all tokens joined).
    let text: String
    /// Number of tokens generated (excluding prompt).
    let tokenCount: Int
    /// Decoded tokens per second during generation.
    let tokensPerSecond: Double
    /// Shape of the encoder output, e.g. [1, 256, 3072]. Nil if encoder was not run.
    let encoderOutputShape: [Int]?
    /// Shape of the projector output, e.g. [256, 896]. Nil if projector was not run.
    let projectorOutputShape: [Int]?
    /// True if OCR was used instead of VLM generation.
    let wasFallback: Bool
    /// Human-readable reason when wasFallback == true.
    let fallbackReason: String?
}

// MARK: - FastVLMDebugInfo
// Published by FastVLMService for display in SettingsView debug section.

struct FastVLMDebugInfo {
    var encoderOutputShape: [Int]?
    var projectorOutputShape: [Int]?
    var lastTokensPerSecond: Double?
    var lastTokenCount: Int?
    var lastGenerationError: String?
}
