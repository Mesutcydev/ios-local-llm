import Foundation

// MARK: - WebSearchService
// Provider-aware search facade. Each provider implementation is a small
// `Sendable` struct + free function — no heavy abstractions. The orchestrator
// (WebToolService) calls `search(query:settings:)` and gets back a vetted
// list of `WebSearchResult`.

public actor WebSearchService {

    private let session: URLSession
    private let validator: URLSafetyValidator

    public init(validator: URLSafetyValidator) {
        self.validator = validator
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        cfg.httpAdditionalHeaders = [
            "User-Agent": "ios-local-llm/1.0 (Web Tool; +on-device)"
        ]
        self.session = URLSession(configuration: cfg)
    }

    public func search(query: String, settings: WebToolSettings) async throws -> [WebSearchResult] {
        switch settings.provider {
        case .directURLOnly:
            return []
        case .duckduckgoHTML:
            return try await searchDuckDuckGoHTML(query: query, max: settings.maxSearchResults)
        case .brave:
            return try await searchBrave(query: query, max: settings.maxSearchResults)
        case .tavily:
            return try await searchTavily(query: query, max: settings.maxSearchResults)
        case .exa:
            return try await searchExa(query: query, max: settings.maxSearchResults)
        case .searxng:
            guard let endpoint = settings.searxngEndpoint else {
                throw WebToolError.providerEndpointMissing
            }
            return try await searchSearXNG(endpoint: endpoint, query: query, max: settings.maxSearchResults)
        case .custom:
            guard let endpoint = settings.customSearchEndpoint else {
                throw WebToolError.providerEndpointMissing
            }
            return try await searchCustom(endpoint: endpoint, query: query, max: settings.maxSearchResults)
        }
    }

    // MARK: - DuckDuckGo (HTML scrape — experimental)

    private func searchDuckDuckGoHTML(query: String, max: Int) async throws -> [WebSearchResult] {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "html.duckduckgo.com"
        comps.path = "/html/"
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else {
            throw WebToolError.providerEndpointMissing
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw WebToolError.searchParsingFailed
        }
        let out = Self.parseDuckDuckGoHTMLResults(html, max: max)
        if out.isEmpty { throw WebToolError.searchParsingFailed }
        return out
    }

    // MARK: - Brave

    private func searchBrave(query: String, max: Int) async throws -> [WebSearchResult] {
        guard let key = KeychainStore.get(account: "brave.apiKey") else {
            throw WebToolError.providerAuthFailed
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(encoded)&count=\(max)") else {
            throw WebToolError.providerEndpointMissing
        }
        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw WebToolError.searchParsingFailed }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebToolError.providerAuthFailed }
        guard http.statusCode == 200 else { throw WebToolError.searchParsingFailed }

        struct BraveResponse: Decodable {
            struct Web: Decodable {
                struct Result: Decodable {
                    let title: String
                    let url: String
                    let description: String?
                }
                let results: [Result]?
            }
            let web: Web?
        }
        guard let decoded = try? JSONDecoder().decode(BraveResponse.self, from: data),
              let results = decoded.web?.results else {
            throw WebToolError.searchParsingFailed
        }
        return results.prefix(max).compactMap { r in
            guard let u = URL(string: r.url) else { return nil }
            return WebSearchResult(title: r.title, url: u,
                                   snippet: r.description ?? "",
                                   provider: .brave)
        }
    }

    // MARK: - Tavily

    private func searchTavily(query: String, max: Int) async throws -> [WebSearchResult] {
        guard let key = KeychainStore.get(account: "tavily.apiKey") else {
            throw WebToolError.providerAuthFailed
        }
        guard let url = URL(string: "https://api.tavily.com/search") else {
            throw WebToolError.providerEndpointMissing
        }
        let body: [String: Any] = [
            "api_key": key,
            "query": query,
            "max_results": max,
            "include_raw_content": true
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw WebToolError.searchParsingFailed }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebToolError.providerAuthFailed }
        guard http.statusCode == 200 else { throw WebToolError.searchParsingFailed }

        struct TavilyResponse: Decodable {
            struct Result: Decodable {
                let title: String
                let url: String
                let content: String?
                let raw_content: String?
            }
            let results: [Result]
        }
        guard let decoded = try? JSONDecoder().decode(TavilyResponse.self, from: data) else {
            throw WebToolError.searchParsingFailed
        }
        return decoded.results.prefix(max).compactMap { r in
            guard let u = URL(string: r.url) else { return nil }
            return WebSearchResult(
                title: r.title, url: u,
                snippet: r.content ?? "",
                provider: .tavily,
                rawContent: r.raw_content
            )
        }
    }

    // MARK: - Exa

    private func searchExa(query: String, max: Int) async throws -> [WebSearchResult] {
        guard let key = KeychainStore.get(account: "exa.apiKey") else {
            throw WebToolError.providerAuthFailed
        }
        guard let url = URL(string: "https://api.exa.ai/search") else {
            throw WebToolError.providerEndpointMissing
        }
        let body: [String: Any] = [
            "query": query,
            "numResults": max,
            "contents": ["text": true]
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw WebToolError.searchParsingFailed }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebToolError.providerAuthFailed }
        guard http.statusCode == 200 else { throw WebToolError.searchParsingFailed }

        struct ExaResponse: Decodable {
            struct Result: Decodable {
                let title: String?
                let url: String
                let text: String?
            }
            let results: [Result]
        }
        guard let decoded = try? JSONDecoder().decode(ExaResponse.self, from: data) else {
            throw WebToolError.searchParsingFailed
        }
        return decoded.results.prefix(max).compactMap { r in
            guard let u = URL(string: r.url) else { return nil }
            return WebSearchResult(
                title: r.title ?? u.host ?? "",
                url: u,
                snippet: String((r.text ?? "").prefix(280)),
                provider: .exa,
                rawContent: r.text
            )
        }
    }

    // MARK: - SearXNG (user-hosted)

    private func searchSearXNG(endpoint: URL, query: String, max: Int) async throws -> [WebSearchResult] {
        let verdict = await validator.validate(endpoint)
        if !verdict.isSafe { throw WebToolError.blockedByURLValidator(reason: verdict.reason) }
        guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw WebToolError.providerEndpointMissing
        }
        let existingPath = comps.path
        comps.path = existingPath.hasSuffix("/search") ? existingPath : (existingPath + "/search")
        comps.queryItems = [URLQueryItem(name: "q", value: query),
                            URLQueryItem(name: "format", value: "json")]
        guard let url = comps.url else { throw WebToolError.providerEndpointMissing }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WebToolError.searchParsingFailed
        }
        struct SXResponse: Decodable {
            struct Result: Decodable { let title: String?; let url: String; let content: String? }
            let results: [Result]
        }
        guard let decoded = try? JSONDecoder().decode(SXResponse.self, from: data) else {
            throw WebToolError.searchParsingFailed
        }
        return decoded.results.prefix(max).compactMap { r in
            guard let u = URL(string: r.url) else { return nil }
            return WebSearchResult(title: r.title ?? u.host ?? "", url: u,
                                   snippet: r.content ?? "", provider: .searxng)
        }
    }

    // MARK: - Custom
    /// Expected JSON: `{ "results": [{ "title", "url", "snippet" }] }`.
    private func searchCustom(endpoint: URL, query: String, max: Int) async throws -> [WebSearchResult] {
        let verdict = await validator.validate(endpoint)
        if !verdict.isSafe { throw WebToolError.blockedByURLValidator(reason: verdict.reason) }
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "q", value: query))
        comps?.queryItems = items
        guard let url = comps?.url else { throw WebToolError.providerEndpointMissing }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WebToolError.searchParsingFailed
        }
        struct CustomResponse: Decodable {
            struct Result: Decodable { let title: String?; let url: String; let snippet: String? }
            let results: [Result]
        }
        guard let decoded = try? JSONDecoder().decode(CustomResponse.self, from: data) else {
            throw WebToolError.searchParsingFailed
        }
        return decoded.results.prefix(max).compactMap { r in
            guard let u = URL(string: r.url) else { return nil }
            return WebSearchResult(title: r.title ?? u.host ?? "", url: u,
                                   snippet: r.snippet ?? "", provider: .custom)
        }
    }

    // MARK: - Regex helpers

    static func parseDuckDuckGoHTMLResults(_ html: String, max: Int) -> [WebSearchResult] {
        // DDG HTML format: <a class="result__a" href="...">title</a>
        // followed by a result snippet. Attribute quote style and class
        // ordering vary, so match the class token instead of the exact attr.
        let titleHrefPat = #"<a\b(?=[^>]*class=["'][^"']*\bresult__a\b[^"']*["'])(?=[^>]*href=["']([^"']+)["'])[^>]*>([\s\S]*?)</a>"#
        let snippetPat = #"<a[^>]*class=["'][^"']*\bresult__snippet\b[^"']*["'][^>]*>([\s\S]*?)</a>"#

        let titles = matches(html, pattern: titleHrefPat)
        let snippets = matches(html, pattern: snippetPat)
        var out: [WebSearchResult] = []
        for (i, t) in titles.enumerated() where i < max {
            guard t.count >= 3,
                  let u = normalizedDuckDuckGoResultURL(t[1]) else { continue }
            let title = decodeEntities(stripTags(t[2]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = i < snippets.count
                ? decodeEntities(stripTags(snippets[i][1]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            out.append(WebSearchResult(title: title, url: u, snippet: snippet, provider: .duckduckgoHTML))
        }
        return out
    }

    private static func normalizedDuckDuckGoResultURL(_ hrefRaw: String) -> URL? {
        let decodedHref = decodeEntities(hrefRaw)
        let absolute: String
        if decodedHref.hasPrefix("//") {
            absolute = "https:" + decodedHref
        } else if decodedHref.hasPrefix("/") {
            absolute = "https://duckduckgo.com" + decodedHref
        } else {
            absolute = decodedHref
        }
        guard let url = URL(string: absolute) else { return nil }
        let path = url.path
        guard url.host?.lowercased().contains("duckduckgo.com") == true,
              (path == "/l" || path.hasPrefix("/l/")),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value,
              let unwrapped = URL(string: uddg.removingPercentEncoding ?? uddg) else {
            return url
        }
        return unwrapped
    }

    private static func matches(_ s: String, pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let ns = s as NSString
        let ms = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        return ms.map { m in
            (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let map: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " ")
        ]
        for (k, v) in map {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }
}
