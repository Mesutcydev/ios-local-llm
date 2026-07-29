import Foundation

// MARK: - Web Tool — model layer
// All `Sendable`. No reference types. Combined into one file so the model
// surface is reviewable at a glance; the rest of the Web Tool feature is split
// across services + views per the spec.
//
// NAMING RULE: every comment and identifier reflects that the *Web Tool*
// fetches pages and the *local LLM* never touches the network. Search the
// codebase for forbidden phrases ("model browses", "ai searched") before ship.

// MARK: - Settings

public enum WebAccessMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case askEveryTime
    case alwaysAllow
    public var id: String { rawValue }
}

public enum WebSearchProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case directURLOnly
    case duckduckgoHTML       // best-effort HTML scrape — may break
    case brave                // requires API key (Keychain)
    case tavily               // requires API key (Keychain); LLM-optimized
    case exa                  // requires API key (Keychain); LLM-optimized
    case searxng              // user-supplied endpoint
    case custom               // user-supplied endpoint, documented JSON
    public var id: String { rawValue }

    /// Display name for UI.
    public var displayName: String {
        switch self {
        case .directURLOnly:   return "Direct URL only"
        case .duckduckgoHTML:  return "DuckDuckGo (HTML, experimental)"
        case .brave:           return "Brave Search"
        case .tavily:          return "Tavily (RAG-tuned)"
        case .exa:             return "Exa (RAG-tuned)"
        case .searxng:         return "SearXNG (self-hosted)"
        case .custom:          return "Custom endpoint"
        }
    }

    /// Whether this provider requires an API key the user enters in Settings.
    public var requiresApiKey: Bool {
        switch self {
        case .brave, .tavily, .exa: return true
        default: return false
        }
    }

    /// Whether the provider already returns extracted text (skip per-result fetch).
    public var returnsRawContent: Bool {
        self == .tavily || self == .exa
    }
}

public struct WebToolSettings: Codable, Sendable, Equatable {
    public var mode: WebAccessMode = .askEveryTime
    public var provider: WebSearchProvider = .duckduckgoHTML
    public var maxSearchResults: Int = 5
    public var maxPagesToFetch: Int = 3
    public var totalWebContextTokens: Int = 2500
    public var maxTokensPerSource: Int = 900
    public var cacheEnabled: Bool = false
    public var cacheTTLHours: Int = 24
    public var allowOnCellular: Bool = false
    public var customSearchEndpoint: URL? = nil
    public var searxngEndpoint: URL? = nil
    // API keys live in Keychain, NEVER in here.

    public init() {}
}

// MARK: - Decision

public enum QueryOrURL: Sendable, Equatable {
    case query(String)
    case url(URL)
}

public enum WebToolDecision: Sendable {
    case noWebNeeded(reason: String)
    case webRecommended(reason: String, query: String)
    case directURL(URL)
    case requiresPermission(reason: String, payload: QueryOrURL)
    case blocked(reason: String)
}

// MARK: - Search + page

public struct WebSearchResult: Sendable, Hashable {
    public let title: String
    public let url: URL
    public let snippet: String
    public let provider: WebSearchProvider
    /// Some providers (Tavily, Exa) return extracted page text inline.
    public let rawContent: String?

    public init(title: String, url: URL, snippet: String, provider: WebSearchProvider, rawContent: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.provider = provider
        self.rawContent = rawContent
    }
}

public struct WebFetchedPage: Sendable, Hashable {
    public let url: URL              // requested URL
    public let finalURL: URL         // after redirects
    public let title: String
    public let siteName: String      // og:site_name or host
    public let fetchedAt: Date
    public let statusCode: Int
    public let extractedText: String
    public let excerpt: String       // first 280 chars of extractedText
    public let wordCount: Int
    public let contentType: String
    public let language: String?     // <html lang> or detected
    public let error: String?        // nil when fetch + extract succeeded

    public init(
        url: URL, finalURL: URL, title: String, siteName: String,
        fetchedAt: Date, statusCode: Int, extractedText: String,
        excerpt: String, wordCount: Int, contentType: String,
        language: String?, error: String?
    ) {
        self.url = url
        self.finalURL = finalURL
        self.title = title
        self.siteName = siteName
        self.fetchedAt = fetchedAt
        self.statusCode = statusCode
        self.extractedText = extractedText
        self.excerpt = excerpt
        self.wordCount = wordCount
        self.contentType = contentType
        self.language = language
        self.error = error
    }
}

// MARK: - Citation

public struct WebSourceCitation: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int                // 1-based — matches [n] markers
    public let title: String
    public let url: URL
    public let siteName: String
    public let fetchedAt: Date

    public init(index: Int, title: String, url: URL, siteName: String, fetchedAt: Date) {
        self.index = index
        self.title = title
        self.url = url
        self.siteName = siteName
        self.fetchedAt = fetchedAt
    }
}

// MARK: - Context bundle handed to the local LLM

public struct WebContextPackage: Sendable {
    public let renderedBlock: String          // WEB CONTEXT START … WEB CONTEXT END
    public let citations: [WebSourceCitation]
    public let approxTokenCount: Int

    public init(renderedBlock: String, citations: [WebSourceCitation], approxTokenCount: Int) {
        self.renderedBlock = renderedBlock
        self.citations = citations
        self.approxTokenCount = approxTokenCount
    }
}

// MARK: - Activity log

public struct WebActivityLogEntry: Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case search, fetch, injectionFlagged, rateLimited, error
    }
    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    public let provider: WebSearchProvider?
    public let queryOrURL: String         // search query or fetched URL
    public let statusCode: Int?
    public let bytesIn: Int?
    public let durationMs: Int?
    public let fromCache: Bool
    public let note: String?              // human-readable detail

    public init(
        id: UUID = UUID(), timestamp: Date = Date(), kind: Kind,
        provider: WebSearchProvider?, queryOrURL: String,
        statusCode: Int?, bytesIn: Int?, durationMs: Int?,
        fromCache: Bool, note: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.provider = provider
        self.queryOrURL = queryOrURL
        self.statusCode = statusCode
        self.bytesIn = bytesIn
        self.durationMs = durationMs
        self.fromCache = fromCache
        self.note = note
    }
}

// MARK: - Errors

public enum WebToolError: Error, Sendable, LocalizedError {
    case webAccessDisabled
    case permissionDenied
    case blockedByURLValidator(reason: String)
    case robotsDenied(url: URL)
    case rateLimited(retryAfter: TimeInterval?)
    case timeout
    case tooLarge(bytes: Int)
    case unsupportedContentType(String)
    case parsingFailed(reason: String)
    case searchParsingFailed
    case providerAuthFailed
    case providerEndpointMissing
    case noResults
    case offline
    case cellularBlocked
    /// Logged to activity log, not necessarily thrown to caller.
    case promptInjectionSuspected(url: URL)

    public var errorDescription: String? {
        switch self {
        case .webAccessDisabled:           return "Web Access is off in Settings."
        case .permissionDenied:            return "You declined web access for this question."
        case .blockedByURLValidator(let r):return "URL blocked: \(r)"
        case .robotsDenied(let u):         return "robots.txt disallows fetching \(u.host ?? "this URL")."
        case .rateLimited(let secs):       return "Rate-limited. Retry after \(secs.map { "\(Int($0))s" } ?? "a moment")."
        case .timeout:                     return "Web request timed out."
        case .tooLarge(let n):             return "Page too large (\(Int64(n).formattedBytes))."
        case .unsupportedContentType(let t): return "Unsupported content type: \(t)."
        case .parsingFailed(let r):        return "Couldn't parse the page: \(r)."
        case .searchParsingFailed:         return "Search provider returned unparseable results. Try another provider."
        case .providerAuthFailed:          return "Search provider rejected the API key."
        case .providerEndpointMissing:     return "Search provider endpoint isn't set up."
        case .noResults:                   return "No web results found."
        case .offline:                     return "Device is offline."
        case .cellularBlocked:             return "Web access on cellular is disabled in Settings."
        case .promptInjectionSuspected:    return "A page contained suspicious instructions; they were redacted."
        }
    }
}
