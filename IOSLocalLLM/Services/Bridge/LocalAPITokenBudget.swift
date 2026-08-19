import Foundation

enum LocalAPITokenCountMode: String, Codable, Hashable, Equatable, Sendable {
    case exact
    case conservativeApproximation = "conservative_approximation"
}

enum LocalAPIMaxTokensSource: String, Codable, Hashable, Equatable, Sendable {
    case maxCompletionTokens = "max_completion_tokens"
    case maxTokens = "max_tokens"
    case maxOutputTokens = "max_output_tokens"
    case numPredict = "num_predict"
    case defaultValue = "default"
}

struct LocalAPITokenCount: Hashable, Equatable, Sendable {
    let tokens: Int
    let mode: LocalAPITokenCountMode

    init(tokens: Int, mode: LocalAPITokenCountMode) {
        self.tokens = max(0, tokens)
        self.mode = mode
    }
}

struct LocalAPIRuntimeLimits: Codable, Hashable, Equatable, Sendable {
    enum LimitSource: String, Codable, Hashable, Equatable, Sendable {
        case runtime
        case modelConfiguration = "model_configuration"
        case manifest
        case explicitConfiguration = "explicit_configuration"
        case migratedLegacy = "migrated_legacy"
        case unresolved
    }

    let contextWindow: Int
    let maximumOutputTokens: Int
    let defaultOutputTokens: Int
    let limitSource: LimitSource
    let tokenizerIdentifier: String?
    let tokenCountMode: LocalAPITokenCountMode

    init(
        contextWindow: Int,
        maximumOutputTokens: Int,
        defaultOutputTokens: Int,
        limitSource: LimitSource,
        tokenizerIdentifier: String? = nil,
        tokenCountMode: LocalAPITokenCountMode
    ) {
        self.contextWindow = max(0, contextWindow)
        self.maximumOutputTokens = max(0, maximumOutputTokens)
        self.defaultOutputTokens = max(0, defaultOutputTokens)
        self.limitSource = limitSource
        self.tokenizerIdentifier = tokenizerIdentifier
        self.tokenCountMode = tokenCountMode
    }

    var isRunnable: Bool {
        contextWindow > 0 && maximumOutputTokens > 0 && defaultOutputTokens > 0
    }
}

struct LocalAPITokenBudgetDecision: Equatable, Sendable {
    let contextWindow: Int
    let safetyReserve: Int
    let originalPrompt: LocalAPITokenCount
    let effectivePrompt: LocalAPITokenCount
    let requestedMaxTokens: Int?
    let effectiveMaxTokens: Int
    let maxTokensSource: LocalAPIMaxTokensSource
    let inputWasTruncated: Bool
    let truncatedMessageCount: Int
    let truncatedGroupCount: Int

    var totalReservedTokens: Int {
        effectivePrompt.tokens + effectiveMaxTokens + safetyReserve
    }

    var fitsContext: Bool {
        totalReservedTokens <= contextWindow
    }

    var usageHeader: String {
        "original_prompt=\(originalPrompt.tokens);effective_prompt=\(effectivePrompt.tokens);reserved_completion=\(effectiveMaxTokens);context=\(contextWindow)"
    }

    var headers: [String: String] {
        [
            "X-Token-Usage-Approx": usageHeader,
            "X-Token-Count-Mode": effectivePrompt.mode.rawValue,
            "X-Model-Context-Window": String(contextWindow),
            "X-Original-Prompt-Tokens": String(originalPrompt.tokens),
            "X-Effective-Prompt-Tokens": String(effectivePrompt.tokens),
            "X-Requested-Max-Tokens": requestedMaxTokens.map(String.init) ?? "",
            "X-Effective-Max-Tokens": String(effectiveMaxTokens),
            "X-Input-Truncated": inputWasTruncated ? "true" : "false",
            "X-Truncated-Message-Count": String(truncatedMessageCount)
        ]
    }
}

enum LocalAPITokenBudgetError: Error, Equatable, Sendable {
    case invalidRequestedOutput(parameter: String, value: Int)
    case outputLimitExceeded(parameter: String, requested: Int, maximum: Int)
    case contextLengthExceeded(
        contextWindow: Int,
        promptTokens: Int,
        requestedCompletionTokens: Int,
        parameter: String
    )
    case noOutputCapacity(contextWindow: Int, promptTokens: Int, parameter: String)
}

enum LocalAPITokenBudget {
    static let defaultSafetyReserve = 16

    static func resolveOutputTokens(
        requested: Int?,
        source: LocalAPIMaxTokensSource,
        maximum: Int,
        defaultValue: Int,
        contextWindow: Int,
        promptTokens: Int,
        safetyReserve: Int = defaultSafetyReserve
    ) throws -> Int {
        let maximum = max(1, maximum)
        let defaultValue = min(max(1, defaultValue), maximum)
        let requested = requested ?? defaultValue
        if requested <= 0 {
            throw LocalAPITokenBudgetError.invalidRequestedOutput(
                parameter: source.rawValue,
                value: requested
            )
        }
        let boundedRequested = min(requested, maximum)
        let available = contextWindow - max(0, promptTokens) - max(0, safetyReserve)
        guard available > 0 else {
            throw LocalAPITokenBudgetError.noOutputCapacity(
                contextWindow: contextWindow,
                promptTokens: max(0, promptTokens),
                parameter: source.rawValue
            )
        }
        return min(boundedRequested, available)
    }

    static func makeDecision(
        contextWindow: Int,
        maximumOutputTokens: Int,
        defaultOutputTokens: Int,
        originalPrompt: LocalAPITokenCount,
        effectivePrompt: LocalAPITokenCount,
        requestedMaxTokens: Int?,
        maxTokensSource: LocalAPIMaxTokensSource,
        inputWasTruncated: Bool,
        truncatedMessageCount: Int,
        truncatedGroupCount: Int,
        safetyReserve: Int = defaultSafetyReserve
    ) throws -> LocalAPITokenBudgetDecision {
        let effective = try resolveOutputTokens(
            requested: requestedMaxTokens,
            source: maxTokensSource,
            maximum: maximumOutputTokens,
            defaultValue: defaultOutputTokens,
            contextWindow: contextWindow,
            promptTokens: effectivePrompt.tokens,
            safetyReserve: safetyReserve
        )
        let decision = LocalAPITokenBudgetDecision(
            contextWindow: contextWindow,
            safetyReserve: max(0, safetyReserve),
            originalPrompt: originalPrompt,
            effectivePrompt: effectivePrompt,
            requestedMaxTokens: requestedMaxTokens,
            effectiveMaxTokens: effective,
            maxTokensSource: maxTokensSource,
            inputWasTruncated: inputWasTruncated,
            truncatedMessageCount: max(0, truncatedMessageCount),
            truncatedGroupCount: max(0, truncatedGroupCount)
        )
        guard decision.fitsContext else {
            throw LocalAPITokenBudgetError.contextLengthExceeded(
                contextWindow: contextWindow,
                promptTokens: effectivePrompt.tokens,
                requestedCompletionTokens: effective,
                parameter: "messages"
            )
        }
        return decision
    }
}

struct LocalAPIConservativeTokenCounter: Sendable {
    let safetyMultiplier: Double
    let perMessageOverhead: Int
    let templateOverhead: Int

    init(
        safetyMultiplier: Double = 1.15,
        perMessageOverhead: Int = 8,
        templateOverhead: Int = 32
    ) {
        self.safetyMultiplier = max(1, safetyMultiplier)
        self.perMessageOverhead = max(0, perMessageOverhead)
        self.templateOverhead = max(0, templateOverhead)
    }

    func count(messages: [ChatMessage], additionalText: String = "") -> LocalAPITokenCount {
        let characters = messages.reduce(0) { partial, message in
            partial + message.contentForModel.count + message.toolCallsCountText.count
        } + additionalText.count
        let base = messages.count * perMessageOverhead + templateOverhead
        let estimate = Int(ceil(Double(max(1, characters / 4 + base)) * safetyMultiplier))
        return LocalAPITokenCount(
            tokens: estimate,
            mode: .conservativeApproximation
        )
    }
}

private extension ChatMessage {
    var toolCallsCountText: String {
        (toolCalls ?? []).map { "\($0.id) \($0.name) \($0.argumentsJSON)" }.joined(separator: " ")
    }
}
