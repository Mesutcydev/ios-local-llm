import Foundation

// MARK: - SearchQueryBuilder
// Crafts the short search query sent to the chosen provider. Strips chat
// history, attachment text, OCR, and obvious PII before anything goes out.

public struct SearchQueryBuilder: Sendable {

    public init() {}

    /// Returns a < 12-word query in the same language as `userMessage`.
    public func buildQuery(from userMessage: String, locale: Locale = .current) -> String {
        var msg = userMessage

        // 1. Strip fenced code blocks — they bloat queries and aren't useful
        //    as search terms.
        msg = msg.replacingOccurrences(of: "```[\\s\\S]*?```",
                                       with: " ",
                                       options: .regularExpression)
        // 2. Strip URLs — when the user gives a direct URL the upstream path
        //    handles it; here we strip URLs from search queries.
        msg = msg.replacingOccurrences(of: "https?://\\S+",
                                       with: " ",
                                       options: .regularExpression)

        // 3. Redact PII patterns (defang before sending to a third party).
        let piiRules: [(String, String)] = [
            ("[\\w._%+-]+@[\\w.-]+\\.[A-Za-z]{2,}", "[redacted-email]"),
            ("\\b(?:\\+?\\d{1,3}[ -]?)?\\(?\\d{3}\\)?[ -]?\\d{3}[ -]?\\d{4}\\b", "[redacted-phone]"),
            ("\\b(?:\\d[ -]*?){13,16}\\b", "[redacted-card]"),
        ]
        for (pat, repl) in piiRules {
            msg = msg.replacingOccurrences(of: pat, with: repl, options: .regularExpression)
        }

        // 4. Strip conversational openers and trigger-verb phrases so the
        //    actual subject reaches the search engine, not the meta-intent.
        //    "look up the latest Swift version" → "latest Swift version"
        //    "can you check what's new in Xcode 16?" → "what's new Xcode 16"
        let stripPats = [
            // Trigger-verb openers
            "(?i)^\\s*(?:look\\s+up|search\\s+for?|browse\\s+for?|check\\s+online|fetch\\s+from\\s+the\\s+web|open\\s+url|visit\\s+url)\\s+",
            // Polite openers
            "(?i)^\\s*(?:please\\s+)?(?:can\\s+you\\s+)?(?:tell\\s+me\\s+)?(?:find|get|show|give\\s+me)?\\s+",
            // "I want to / I need to" openers
            "(?i)^\\s*(?:i\\s+(?:want\\s+to\\s+|need\\s+to\\s+)?(?:know|find|see|check|search)\\s+(?:about\\s+|for\\s+)?)",
            // Question openers
            "(?i)^\\s*(?:what(?:'s|\\s+is)?\\s+the\\s+)",
            "(?i)^\\s*(?:is\\s+there\\s+a\\s+|are\\s+there\\s+any\\s+)",
            "(?i)^\\s*(?:how\\s+(?:much|many)\\s+(?:does|is|are)\\s+)",
        ]
        for pat in stripPats {
            msg = msg.replacingOccurrences(of: pat, with: "", options: .regularExpression)
        }

        // 5. Collapse whitespace.
        msg = msg.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 6. Word cap.
        let words = msg.split(separator: " ").map(String.init)
        let capped = words.prefix(12).joined(separator: " ")

        // 7. Last fallback: if everything got stripped, use first 60 chars.
        if capped.isEmpty {
            let trimmed = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(60))
        }
        return capped
    }
}
