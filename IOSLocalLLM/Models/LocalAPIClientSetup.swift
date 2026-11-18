import Foundation

/// Connection recipes for the HTTPS listener. Keep this catalog scoped to the
/// routes implemented by LocalAPIServer; the Mac pairing bridge is separate.
struct LocalAPIClientSetup {
    enum Format: String, CaseIterable, Identifiable {
        case openAI = "OpenAI", anthropic = "Anthropic", ollama = "Ollama"
        var id: String { rawValue }
    }

    struct Route: Identifiable, Equatable {
        let method: String
        let path: String
        let purpose: String
        var id: String { "\(method) \(path)" }
    }

    let host: String
    let port: UInt16
    let modelID: String
    let publicKeyPin: String

    var origin: String { "https://\(host):\(port)" }
    var openAIBaseURL: String { origin + "/v1" }

    var hasValidPin: Bool {
        publicKeyPin.hasPrefix("sha256//")
            && Data(base64Encoded: String(publicKeyPin.dropFirst(8)))?.count == 32
    }

    func baseURL(for format: Format) -> String {
        format == .openAI ? openAIBaseURL : origin
    }

    /// Shell-quote every exported value and JSON-encode request bodies. Never
    /// interpolate a model ID or credential into executable shell syntax.
    func example(for format: Format, apiKey: String) -> String {
        let pin = hasValidPin ? publicKeyPin : "COPY_PIN_FROM_THIS_DEVICE"
        let exports = """
        export OPENAI_BASE_URL=\(Self.shellQuote(openAIBaseURL))
        export OPENAI_API_KEY=\(Self.shellQuote(apiKey))
        export IOS_LOCAL_LLM_TLS_PIN=\(Self.shellQuote(pin))
        """
        let tls = #"curl --insecure --pinnedpubkey "$IOS_LOCAL_LLM_TLS_PIN""#
        switch format {
        case .openAI:
            return exports + "\n" + tls + " \"$OPENAI_BASE_URL/chat/completions\" \\\n  -H \"Authorization: Bearer $OPENAI_API_KEY\" \\\n  -H 'Content-Type: application/json' \\\n  -d " + Self.shellQuote(Self.json([
                "model": modelID, "messages": [["role": "user", "content": "Hello from my local client."]],
                "max_tokens": 128, "stream": false
              ]))
        case .anthropic:
            return exports + "\n" + tls + " " + Self.shellQuote(origin + "/v1/messages") + " \\\n  -H \"x-api-key: $OPENAI_API_KEY\" \\\n  -H 'anthropic-version: 2023-06-01' \\\n  -H 'Content-Type: application/json' \\\n  -d " + Self.shellQuote(Self.json([
                "model": modelID, "messages": [["role": "user", "content": "Hello from my local client."]],
                "max_tokens": 128, "stream": false
              ]))
        case .ollama:
            return exports + "\n" + tls + " " + Self.shellQuote(origin + "/api/chat") + " \\\n  -H \"Authorization: Bearer $OPENAI_API_KEY\" \\\n  -H 'Content-Type: application/json' \\\n  -d " + Self.shellQuote(Self.json([
                "model": modelID, "messages": [["role": "user", "content": "Hello from my local client."]],
                "stream": false
              ]))
        }
    }

    static let routes: [Route] = [
        .init(method: "GET", path: "/v1/models", purpose: "Available local models"),
        .init(method: "POST", path: "/v1/chat/completions", purpose: "Chat, streaming, and tool calls"),
        .init(method: "POST", path: "/v1/responses", purpose: "Text input and output"),
        .init(method: "POST", path: "/v1/messages", purpose: "Anthropic messages and tool use"),
        .init(method: "GET", path: "/api/tags", purpose: "Ollama model list"),
        .init(method: "POST", path: "/api/show", purpose: "Local model information"),
        .init(method: "POST", path: "/api/chat", purpose: "Ollama chat and tool calls"),
        .init(method: "POST", path: "/api/generate", purpose: "Ollama prompt generation")
    ]

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func json(_ object: [String: Any]) -> String {
        // Only strings, integers, booleans, and arrays are accepted above.
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

/// A loaded chat model alone never means a stopped API listener is ready.
enum LocalAPIWorkspaceActivity: Equatable {
    enum Listener { case stopped, starting, running, failed }
    enum Model { case unloaded, loading, ready, generating, failed }

    case offline, starting, stopping, listening, loading, ready, generating
    case localModelRequired, listenerFailed, modelFailed

    static func resolve(listener: Listener, model: Model, isLocal: Bool,
                        isResident: Bool, isStopping: Bool = false) -> Self {
        if isStopping { return .stopping }
        switch listener {
        case .stopped: return .offline
        case .starting: return .starting
        case .failed: return .listenerFailed
        case .running:
            guard isLocal else { return .localModelRequired }
            switch model {
            case .loading: return .loading
            case .failed: return .modelFailed
            case .ready: return isResident ? .ready : .listening
            case .generating: return isResident ? .generating : .listening
            case .unloaded: return .listening
            }
        }
    }

    var isWorking: Bool {
        switch self {
        case .starting, .stopping, .loading, .generating: true
        default: false
        }
    }
}
