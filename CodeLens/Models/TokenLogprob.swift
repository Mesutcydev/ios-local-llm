import Foundation

// MARK: - TokenLogprob
// Per-token log probability information returned by the model during generation.
// Used for debugging model behavior — lets users see which tokens the model
// considered and why it picked what it did.

public struct TokenLogprob: Identifiable, Codable, Hashable, Sendable {
    public var id: Int { tokenIndex }

    /// Position in the output sequence (0-based).
    public let tokenIndex: Int
    /// The decoded text of the chosen token.
    public let token: String
    /// Log probability of the chosen token (log-softmax output).
    public let logprob: Double
    /// Top alternative tokens and their log probabilities.
    public let topAlternatives: [AlternativeToken]

    public init(
        tokenIndex: Int,
        token: String,
        logprob: Double,
        topAlternatives: [AlternativeToken]
    ) {
        self.tokenIndex = tokenIndex
        self.token = token
        self.logprob = logprob
        self.topAlternatives = topAlternatives
    }

    public struct AlternativeToken: Codable, Hashable, Sendable {
        public let token: String
        public let logprob: Double

        public init(token: String, logprob: Double) {
            self.token = token
            self.logprob = logprob
        }
    }

    /// Confidence level for color-coding in the UI.
    public enum Confidence: Sendable {
        case high       // logprob >= -1 (p > 0.37)
        case medium     // logprob >= -3 (p > 0.05)
        case low        // logprob < -3 (p < 0.05)

        public var colorName: String {
            switch self {
            case .high:   return "good"
            case .medium: return "warn"
            case .low:    return "bad"
            }
        }
    }

    public var confidence: Confidence {
        if logprob >= -1.0 { return .high }
        if logprob >= -3.0 { return .medium }
        return .low
    }

    /// Linear probability for display.
    public var probability: Double { exp(logprob) }
}

// MARK: - LogprobSummary
// Attached to a ChatMessage.assistant reply after generation completes
// (when logprobs are enabled). Contains the full token-by-token logprob
// array plus aggregate statistics.

public struct LogprobSummary: Codable, Hashable, Sendable {
    public let tokens: [TokenLogprob]

    public init(tokens: [TokenLogprob]) {
        self.tokens = tokens
    }

    /// Average log probability across all output tokens.
    public var avgLogprob: Double {
        guard !tokens.isEmpty else { return 0 }
        return tokens.map(\.logprob).reduce(0, +) / Double(tokens.count)
    }

    /// Perplexity-like score: exp(-avg logprob).
    public var perplexityScore: Double {
        exp(-avgLogprob)
    }

    /// Number of low-confidence tokens (logprob < -3).
    public var lowConfidenceCount: Int {
        tokens.filter { $0.confidence == .low }.count
    }

    /// Fraction of low-confidence tokens.
    public var lowConfidenceFraction: Double {
        tokens.isEmpty ? 0 : Double(lowConfidenceCount) / Double(tokens.count)
    }
}
