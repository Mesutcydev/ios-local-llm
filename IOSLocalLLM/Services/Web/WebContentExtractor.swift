import Foundation

// MARK: - WebContentExtractor
// Converts a fetched response body into a `WebFetchedPage`. HTML path uses
// regex-driven extraction with a small Readability-style heuristic — no
// SwiftSoup dependency, so the app stays lean. The trade-off: slightly less
// accurate main-content detection on layout-heavy news sites. For docs and
// blogs (the most common targets) it's fine.
//
// JSON and plain text/markdown paths are straightforward.

public actor WebContentExtractor {

    public init() {}

    public func extract(
        data: Data,
        contentType: String,
        requestURL: URL,
        finalURL: URL,
        statusCode: Int
    ) async -> WebFetchedPage {
        let encoding = Self.detectEncoding(contentType: contentType, body: data)
        let text = String(data: data, encoding: encoding) ?? ""

        let ct = contentType.lowercased()
        if ct.hasPrefix("application/json") {
            return jsonPage(text: text, requestURL: requestURL, finalURL: finalURL,
                            contentType: contentType, statusCode: statusCode)
        }
        if ct.hasPrefix("text/markdown") || ct.hasPrefix("text/plain") {
            return textPage(text: text, requestURL: requestURL, finalURL: finalURL,
                            contentType: contentType, statusCode: statusCode)
        }
        return htmlPage(html: text, requestURL: requestURL, finalURL: finalURL,
                        contentType: contentType, statusCode: statusCode)
    }

    // MARK: - HTML path

    private func htmlPage(
        html: String, requestURL: URL, finalURL: URL,
        contentType: String, statusCode: Int
    ) -> WebFetchedPage {
        let title = Self.firstCaptured(in: html, pattern: "<title[^>]*>([\\s\\S]*?)</title>") ?? finalURL.host ?? ""
        let siteName = Self.firstCaptured(in: html, pattern: "<meta[^>]+property=[\"']og:site_name[\"'][^>]+content=[\"']([^\"']+)[\"']") ?? (finalURL.host ?? "")
        let lang = Self.firstCaptured(in: html, pattern: "<html[^>]+lang=[\"']([^\"']+)[\"']")

        var body = html
        // 1. Drop non-content tags.
        let strip: [String] = [
            "script", "style", "noscript", "iframe", "svg", "canvas",
            "nav", "footer", "header", "aside", "form"
        ]
        for tag in strip {
            body = body.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                with: " ", options: .regularExpression
            )
        }
        // Self-closing or unclosed leftovers.
        body = body.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)

        // 2. Pull preformatted blocks separately so code is preserved verbatim.
        var codeBlocks: [String] = []
        body = body.replacingOccurrences(of: "<pre[^>]*>([\\s\\S]*?)</pre>",
                                         with: "<<<<PRE_BLOCK>>>>",
                                         options: .regularExpression)
        if let pat = try? NSRegularExpression(pattern: "<pre[^>]*>([\\s\\S]*?)</pre>") {
            let ns = html as NSString
            let matches = pat.matches(in: html, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges >= 2 {
                let raw = ns.substring(with: m.range(at: 1))
                codeBlocks.append(Self.stripTags(raw))
            }
        }

        // 3. Strip remaining tags.
        var text = Self.stripTags(body)
        text = Self.decodeEntities(text)
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 4. Re-interleave code blocks as fenced markdown.
        var i = 0
        while text.contains("<<<<PRE_BLOCK>>>>"), i < codeBlocks.count {
            text = text.replacingOccurrences(
                of: "<<<<PRE_BLOCK>>>>",
                with: "\n\n```\n\(codeBlocks[i])\n```\n\n",
                options: .literal,
                range: text.range(of: "<<<<PRE_BLOCK>>>>")
            )
            i += 1
        }

        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        let excerpt = String(text.prefix(280))

        return WebFetchedPage(
            url: requestURL, finalURL: finalURL,
            title: Self.decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines),
            siteName: Self.decodeEntities(siteName),
            fetchedAt: Date(), statusCode: statusCode,
            extractedText: text, excerpt: excerpt,
            wordCount: wordCount, contentType: contentType,
            language: lang, error: nil
        )
    }

    // MARK: - JSON path

    private func jsonPage(
        text: String, requestURL: URL, finalURL: URL,
        contentType: String, statusCode: Int
    ) -> WebFetchedPage {
        let compact: String
        if text.count <= 4096 {
            compact = text
        } else {
            // Top-level summary: if it parses to a dict, keep top-level keys
            // and the first ~2 KB of any string-typed value.
            if let data = text.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var lines: [String] = []
                for (k, v) in dict {
                    let vStr = String(describing: v)
                    let trimmed = vStr.count > 2048 ? String(vStr.prefix(2048)) + "…" : vStr
                    lines.append("\(k): \(trimmed)")
                }
                compact = lines.joined(separator: "\n")
            } else {
                compact = String(text.prefix(4096))
            }
        }
        return WebFetchedPage(
            url: requestURL, finalURL: finalURL,
            title: finalURL.lastPathComponent, siteName: finalURL.host ?? "",
            fetchedAt: Date(), statusCode: statusCode,
            extractedText: compact, excerpt: String(compact.prefix(280)),
            wordCount: compact.split(whereSeparator: { $0.isWhitespace }).count,
            contentType: contentType, language: nil, error: nil
        )
    }

    // MARK: - Text / markdown path

    private func textPage(
        text: String, requestURL: URL, finalURL: URL,
        contentType: String, statusCode: Int
    ) -> WebFetchedPage {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return WebFetchedPage(
            url: requestURL, finalURL: finalURL,
            title: finalURL.lastPathComponent, siteName: finalURL.host ?? "",
            fetchedAt: Date(), statusCode: statusCode,
            extractedText: normalized, excerpt: String(normalized.prefix(280)),
            wordCount: normalized.split(whereSeparator: { $0.isWhitespace }).count,
            contentType: contentType, language: nil, error: nil
        )
    }

    // MARK: - Helpers

    private static func detectEncoding(contentType: String, body: Data) -> String.Encoding {
        if let range = contentType.range(of: "charset=", options: .caseInsensitive) {
            let raw = contentType[range.upperBound...]
                .split(separator: ";").first.map { String($0).lowercased() } ?? ""
            switch raw {
            case "utf-8", "utf8": return .utf8
            case "iso-8859-1", "latin1": return .isoLatin1
            case "us-ascii", "ascii": return .ascii
            case "utf-16": return .utf16
            default: break
            }
        }
        return .utf8
    }

    private static func firstCaptured(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    /// Decodes a small set of common HTML entities. Not exhaustive — handles
    /// the ones we actually see in text content.
    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let map: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "…"), ("&ldquo;", "“"), ("&rdquo;", "”"),
            ("&lsquo;", "‘"), ("&rsquo;", "’")
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric entities &#NNN; — match common ones.
        let pat = "&#(\\d{1,5});"
        if let re = try? NSRegularExpression(pattern: pat) {
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                guard m.numberOfRanges >= 2,
                      let code = Int(ns.substring(with: m.range(at: 1))),
                      let scalar = Unicode.Scalar(code) else { continue }
                let replacement = String(Character(scalar))
                out = (out as NSString).replacingCharacters(in: m.range, with: replacement)
            }
        }
        return out
    }
}
