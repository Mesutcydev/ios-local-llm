import Foundation

// MARK: - WebToolService
// The public entry point for the Web Tool. Orchestrates:
//   decide → permission → search → fetch (parallel, capped) →
//   extract → sanitize → rerank → compress → return WebContextPackage
//
// Never calls the local LLM. Never sends chat history off-device.
// Naming rule: this file says "Web Tool", never "the model browses".

@MainActor
public final class WebToolService: ObservableObject {

    public static let shared = WebToolService()

    @Published public private(set) var phase: Phase = .idle

    public enum Phase: Equatable {
        case idle
        case awaitingPermission
        case searching
        case fetching(done: Int, total: Int)
        case ready(WebContextPackage)
        case failed(String)

        public static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.awaitingPermission, .awaitingPermission),
                 (.searching, .searching): return true
            case (.fetching(let a, let b), .fetching(let c, let d)):
                return a == c && b == d
            case (.ready(let a), .ready(let b)):
                return a.approxTokenCount == b.approxTokenCount
                    && a.citations.count == b.citations.count
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    // Settings persisted as JSON in UserDefaults (key keeps it scoped).
    private let settingsKey = "ioslocalllm.webtool.settings.v1"
    @Published public var settings: WebToolSettings = WebToolSettings() {
        didSet { saveSettings() }
    }

    private let decision = WebToolDecisionEngine()
    private let validator = URLSafetyValidator()
    private let extractor = WebContentExtractor()
    private let sanitizer = WebContentSanitizer()
    private let limiter = WebRateLimiter()
    private lazy var search = WebSearchService(validator: validator)
    private lazy var fetcher = WebPageFetchService(validator: validator,
                                                    limiter: limiter,
                                                    extractor: extractor)
    private let reranker = WebPassageReranker()

    private init() { loadSettings() }

    // MARK: - Public API

    /// Returns the routing decision for `message`. The caller (chat view)
    /// handles the permission sheet UI; we only return what's needed.
    public func decide(for message: String) -> WebToolDecision {
        decision.decide(message: message, settings: settings)
    }

    /// Executes the Web Tool against `payload` and returns a `WebContextPackage`
    /// the prompt builder can stitch into the system prompt. Caller is
    /// responsible for permission gating BEFORE calling this.
    public func runWebTool(for payload: QueryOrURL, originalMessage: String) async -> Result<WebContextPackage, WebToolError> {
        await limiter.resetRequestBudget()
        phase = .searching

        do {
            let pages = try await collectPages(payload: payload)
            guard !pages.isEmpty else {
                phase = .failed("No usable web sources.")
                return .failure(.noResults)
            }
            // 4. Sanitize each page's extracted text.
            var sanitized: [WebFetchedPage] = []
            sanitized.reserveCapacity(pages.count)
            for page in pages {
                let result = sanitizer.sanitize(page.extractedText)
                if result.didRedact {
                    let entry = WebActivityLogEntry(
                        kind: .injectionFlagged, provider: nil,
                        queryOrURL: page.finalURL.absoluteString,
                        statusCode: page.statusCode, bytesIn: nil,
                        durationMs: nil, fromCache: false,
                        note: "prompt-injection patterns redacted"
                    )
                    WebActivityLogger.shared.record(entry)
                }
                sanitized.append(WebFetchedPage(
                    url: page.url, finalURL: page.finalURL,
                    title: page.title, siteName: page.siteName,
                    fetchedAt: page.fetchedAt, statusCode: page.statusCode,
                    extractedText: result.sanitized,
                    excerpt: String(result.sanitized.prefix(280)),
                    wordCount: result.sanitized.split(whereSeparator: { $0.isWhitespace }).count,
                    contentType: page.contentType, language: page.language,
                    error: page.error
                ))
            }

            // 5. Rerank passages by the original user message.
            let passages = reranker.rerank(query: originalMessage, pages: sanitized)

            // 6. Compress to token budget.
            let budget = WebContextBudget(
                totalWebContextTokens: settings.totalWebContextTokens,
                maxTokensPerSource: settings.maxTokensPerSource
            )
            let compressor = WebContextCompressor(budget: budget)
            let pkg = compressor.compress(pages: sanitized, passages: passages)
            phase = .ready(pkg)
            return .success(pkg)
        } catch let err as WebToolError {
            phase = .failed(err.localizedDescription)
            WebActivityLogger.shared.record(.init(
                kind: .error, provider: settings.provider,
                queryOrURL: Self.describe(payload), statusCode: nil,
                bytesIn: nil, durationMs: nil, fromCache: false,
                note: err.localizedDescription
            ))
            return .failure(err)
        } catch {
            phase = .failed(error.localizedDescription)
            return .failure(.parsingFailed(reason: error.localizedDescription))
        }
    }

    public func cancel() {
        phase = .idle
    }

    // MARK: - Pipeline (search + fetch)

    private func collectPages(payload: QueryOrURL) async throws -> [WebFetchedPage] {
        switch payload {
        case .url(let url):
            phase = .fetching(done: 0, total: 1)
            let started = Date()
            let page = try await fetcher.fetch(url, isDirectUserURL: true)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            WebActivityLogger.shared.record(.init(
                kind: .fetch, provider: nil, queryOrURL: url.absoluteString,
                statusCode: page.statusCode, bytesIn: page.extractedText.count,
                durationMs: elapsed, fromCache: false, note: nil
            ))
            phase = .fetching(done: 1, total: 1)
            return [page]

        case .query(let q):
            phase = .searching
            let started = Date()
            let results = try await search.search(query: q, settings: settings)
            WebActivityLogger.shared.record(.init(
                kind: .search, provider: settings.provider, queryOrURL: q,
                statusCode: 200, bytesIn: nil,
                durationMs: Int(Date().timeIntervalSince(started) * 1000),
                fromCache: false, note: "\(results.count) results"
            ))
            if results.isEmpty { throw WebToolError.noResults }

            let topResults = Array(results.prefix(settings.maxPagesToFetch))
            phase = .fetching(done: 0, total: topResults.count)

            var pages: [WebFetchedPage] = []
            for (i, r) in topResults.enumerated() {
                // Tavily / Exa give us raw content — skip the fetch.
                if let raw = r.rawContent, !raw.isEmpty {
                    let p = WebFetchedPage(
                        url: r.url, finalURL: r.url,
                        title: r.title, siteName: r.url.host ?? "",
                        fetchedAt: Date(), statusCode: 200,
                        extractedText: raw, excerpt: String(raw.prefix(280)),
                        wordCount: raw.split(whereSeparator: { $0.isWhitespace }).count,
                        contentType: "text/plain", language: nil, error: nil
                    )
                    pages.append(p)
                } else {
                    do {
                        let fetchStart = Date()
                        let p = try await fetcher.fetch(r.url, isDirectUserURL: false)
                        WebActivityLogger.shared.record(.init(
                            kind: .fetch, provider: nil,
                            queryOrURL: r.url.absoluteString,
                            statusCode: p.statusCode,
                            bytesIn: p.extractedText.count,
                            durationMs: Int(Date().timeIntervalSince(fetchStart) * 1000),
                            fromCache: false, note: nil
                        ))
                        pages.append(p)
                    } catch let err as WebToolError {
                        WebActivityLogger.shared.record(.init(
                            kind: .error, provider: nil,
                            queryOrURL: r.url.absoluteString, statusCode: nil,
                            bytesIn: nil, durationMs: nil,
                            fromCache: false, note: err.localizedDescription
                        ))
                    }
                }
                phase = .fetching(done: i + 1, total: topResults.count)
            }
            return pages
        }
    }

    // MARK: - Settings persistence

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(WebToolSettings.self, from: data) else {
            return
        }
        settings = decoded
    }
    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    // MARK: - Helpers

    private static func describe(_ payload: QueryOrURL) -> String {
        switch payload {
        case .query(let q): return q
        case .url(let u): return u.absoluteString
        }
    }
}
