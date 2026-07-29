import Foundation

// MARK: - WebContentSanitizer
// Defends the local LLM from prompt-injection text living inside fetched
// pages. This is NOT a perfect defense — nothing is — but it neutralizes the
// common attack shapes documented in the prompt-injection literature.
//
// Runs AFTER extraction, BEFORE reranking. Output is what we'll show the LLM,
// minus anything that looked like an instruction trying to hijack roles.

public struct WebContentSanitizer: Sendable {

    public init() {}

    public struct Outcome: Sendable {
        public let sanitized: String
        /// True when at least one redaction fired. Caller logs this to the
        /// activity log so the user knows a page was suspicious.
        public let didRedact: Bool
    }

    public func sanitize(_ input: String) -> Outcome {
        var s = input
        var didRedact = false

        // 1. Role-marker imitations at line starts. Wrap in backticks so
        //    citation context is preserved but the LLM doesn't read them as
        //    role tokens.
        let rolePatterns: [String] = [
            "system:", "assistant:", "user:",
            "<\\|im_start\\|>", "<\\|im_end\\|>",
            "\\[INST\\]", "\\[/INST\\]",
            "</s>", "<<SYS>>", "<</SYS>>"
        ]
        for pat in rolePatterns {
            let regex = "(?im)^[\\s>]*\(pat)"
            if s.range(of: regex, options: .regularExpression) != nil {
                didRedact = true
                s = s.replacingOccurrences(
                    of: regex,
                    with: "`[role-marker neutralized]`",
                    options: .regularExpression
                )
            }
        }

        // 2. "Ignore previous" style override attempts.
        let overridePatterns: [String] = [
            "(?i)ignore\\s+(?:all\\s+|previous\\s+|above\\s+|prior\\s+)?(?:instructions|rules|prompts|directives|context)",
            "(?i)disregard\\s+(?:the\\s+)?(?:system|previous|prior|above)",
            "(?i)forget\\s+(?:everything|all\\s+previous|the\\s+above)",
            "(?i)you\\s+are\\s+now\\s+(?:dan|jailbroken|in\\s+developer\\s+mode)",
            "(?i)pretend\\s+(?:you\\s+are|to\\s+be)\\s+(?:dan|an?\\s+ai\\s+without)",
            "(?i)reveal\\s+(?:your\\s+)?(?:system\\s+prompt|hidden\\s+prompt|initial\\s+instructions)"
        ]
        for pat in overridePatterns {
            if s.range(of: pat, options: .regularExpression) != nil {
                didRedact = true
                s = s.replacingOccurrences(
                    of: pat,
                    with: "[redacted: possible injection attempt]",
                    options: .regularExpression
                )
            }
        }

        // 3. Relabel instruction-fence blocks (```instructions / ```system).
        let fences = ["instructions", "system", "prompt", "ai", "assistant"]
        for fence in fences {
            let pat = "```\\s*\(fence)\\b"
            if s.range(of: pat, options: .regularExpression) != nil {
                didRedact = true
                s = s.replacingOccurrences(
                    of: pat, with: "```text",
                    options: .regularExpression
                )
            }
        }

        // 4. Long uppercase runs — typical of "URGENT INSTRUCTION TO AI"
        //    attacks. Anything > 40 consecutive uppercase chars (with spaces)
        //    gets downcased.
        let upperPat = "(?:[A-Z][A-Z\\s]{40,})"
        if let regex = try? NSRegularExpression(pattern: upperPat) {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                didRedact = didRedact || true
                // Walk matches in reverse so earlier ranges stay valid.
                for m in matches.reversed() {
                    let range = m.range
                    let original = ns.substring(with: range)
                    let lowered = original.lowercased()
                    s = (s as NSString).replacingCharacters(in: range, with: lowered)
                }
            }
        }

        // 5. Cap URL spam — keep first 30 absolute URLs.
        let urlPat = "https?://[^\\s)\\]\"']+"
        if let regex = try? NSRegularExpression(pattern: urlPat) {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            if matches.count > 30 {
                // Replace the 31st+ matches with their host only, in reverse.
                for m in matches.dropFirst(30).reversed() {
                    let urlText = ns.substring(with: m.range)
                    let host = URL(string: urlText)?.host ?? "[url]"
                    s = (s as NSString).replacingCharacters(in: m.range, with: "[\(host)]")
                }
                didRedact = true
            }
        }

        return Outcome(sanitized: s, didRedact: didRedact)
    }
}
