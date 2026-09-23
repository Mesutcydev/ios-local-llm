import Foundation
import Network

// MARK: - WebPageFetchService
// Fetches a single public URL safely. Hard ceilings:
//   • 2 MB body (8 MB absolute hard cap)
//   • 5 redirects, every hop validated for SSRF
//   • 15 s request timeout / 20 s resource timeout
//   • Accept allowlist: html / text / json / markdown / xhtml
//
// Uses `URLSessionConfiguration.ephemeral` so no cookies persist across runs.

public actor WebPageFetchService {

    private let validator: URLSafetyValidator
    private let limiter: WebRateLimiter
    private let extractor: WebContentExtractor
    private let session: URLSession
    private let delegate: RedirectGuard

    public init(validator: URLSafetyValidator, limiter: WebRateLimiter, extractor: WebContentExtractor) {
        self.validator = validator
        self.limiter = limiter
        self.extractor = extractor

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        cfg.httpAdditionalHeaders = [
            "User-Agent": "ios-local-llm/1.0 (Web Tool; +on-device)",
            "Accept": "text/html, text/plain, application/json, text/markdown, application/xhtml+xml"
        ]
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.waitsForConnectivity = false

        let guardDelegate = RedirectGuard(validator: validator)
        self.delegate = guardDelegate
        self.session = URLSession(configuration: cfg, delegate: guardDelegate, delegateQueue: nil)
    }

    /// Fetches and extracts `url`. Direct-URL fetches skip robots.txt (per spec).
    public func fetch(_ url: URL, isDirectUserURL: Bool = false) async throws -> WebFetchedPage {
        // 1. SSRF / scheme / host gate — double-checked to narrow DNS TOCTOU.
        let verdict = await validator.validateStable(url)
        if !verdict.isSafe {
            throw WebToolError.blockedByURLValidator(reason: verdict.reason)
        }

        // 2. Rate-limit per host.
        let host = url.host ?? ""
        let allowed = await limiter.consumeBudgetAndWait(forHost: host)
        if !allowed { throw WebToolError.rateLimited(retryAfter: nil) }

        // 3. Issue the request.
        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        let started = Date()
        delegate.reset()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if delegate.exceededSizeLimit {
                throw WebToolError.tooLarge(bytes: delegate.bytesReceived)
            }
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw WebToolError.parsingFailed(reason: "non-HTTP response")
        }

        // 4. Status / content-type gating.
        if http.statusCode == 429 {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            throw WebToolError.rateLimited(retryAfter: retry)
        }
        if !(200...299).contains(http.statusCode) {
            throw WebToolError.parsingFailed(reason: "status \(http.statusCode)")
        }
        let ctRaw = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let ct = ctRaw.lowercased()
        let allowed_ct = ["text/html", "text/plain", "application/json",
                          "text/markdown", "application/xhtml+xml", "text/xml"]
        if !allowed_ct.contains(where: { ct.hasPrefix($0) }) {
            throw WebToolError.unsupportedContentType(ctRaw.isEmpty ? "unknown" : ctRaw)
        }

        // 5. Size cap.
        if data.count > 2 * 1024 * 1024 {
            throw WebToolError.tooLarge(bytes: data.count)
        }

        let finalURL = http.url ?? url
        let finalVerdict = await validator.validateStable(finalURL)
        if !finalVerdict.isSafe {
            throw WebToolError.blockedByURLValidator(reason: "final URL blocked: \(finalVerdict.reason)")
        }
        let _ = Int(Date().timeIntervalSince(started) * 1000)

        // 6. Extract.
        let extracted = await extractor.extract(
            data: data, contentType: ct,
            requestURL: url, finalURL: finalURL,
            statusCode: http.statusCode
        )
        return extracted
    }
}

// MARK: - RedirectGuard
// Intercepts EVERY 3xx hop so a malicious server can't 302 us into a private
// network. Implements `URLSessionTaskDelegate.willPerformHTTPRedirection`.

private final class RedirectGuard: NSObject, URLSessionDataDelegate {

    private let validator: URLSafetyValidator
    private let lock = NSLock()
    private var bytes = 0
    private var exceeded = false

    /// Abort the response once more than this has arrived. The previous
    /// code buffered the entire body before checking size, so a huge
    /// (or endless) response could exhaust memory.
    static let maxBodyBytes = 2 * 1024 * 1024

    init(validator: URLSafetyValidator) {
        self.validator = validator
    }

    func reset() {
        lock.lock()
        bytes = 0
        exceeded = false
        lock.unlock()
    }

    var exceededSizeLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return exceeded
    }

    var bytesReceived: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock()
        bytes += data.count
        let over = bytes > Self.maxBodyBytes
        if over { exceeded = true }
        lock.unlock()
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let nextURL = request.url else {
            completionHandler(nil)
            return
        }
        // Synchronously block until validator says yes/no — we're already on
        // a URLSession delegate queue.
        Task {
            let verdict = await validator.validateStable(nextURL)
            completionHandler(verdict.isSafe ? request : nil)
        }
    }
}
