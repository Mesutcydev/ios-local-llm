import Foundation

// MARK: - CodeTask
// The four jobs Code Mode can do on a captured frame. Extraction is always
// run first (faithful OCR, no model). The other three hand the *extracted
// text* to the on-device code LLM (CodingAssistantService) — a far stronger
// reasoner about code than any small on-device VLM. Prompts are kept terse
// and directive so quantised 1.5–7B coders stay on task.

enum CodeTask: String, CaseIterable, Identifiable {
    case extract   // faithful transcription — no LLM, just the OCR output
    case explain   // summarise + walk through what the code does
    case review    // bugs, security issues, smells + fixes
    case debug     // read an error / stack trace, give the likely cause + fix

    var id: String { rawValue }

    /// True when this task runs the LLM. `.extract` is pure OCR, so it skips
    /// model loading entirely (and works even with no LLM downloaded).
    var usesLLM: Bool { self != .extract }

    /// Short chip label (lowercase to match the lens' mono-pill aesthetic).
    var label: String {
        switch self {
        case .extract: return "extract"
        case .explain: return "explain"
        case .review:  return "review"
        case .debug:   return "debug"
        }
    }

    var systemImage: String {
        switch self {
        case .extract: return "doc.plaintext"
        case .explain: return "text.book.closed"
        case .review:  return "checklist"
        case .debug:   return "ladybug"
        }
    }

    /// One-line hint shown under the chip row.
    var hint: String {
        switch self {
        case .extract: return "faithful transcription of the code on screen"
        case .explain: return "summary + a walk through what it does"
        case .review:  return "bugs, security issues & smells, with fixes"
        case .debug:   return "read the error / trace and suggest a fix"
        }
    }

    // MARK: - Prompts

    /// System prompt steering the code LLM for this task. Only the LLM tasks
    /// use this (`.extract` returns nil).
    func systemPrompt(language: String?) -> String? {
        let lang = (language.map { $0 == "Unknown" ? nil : $0 } ?? nil)
        let langClause = lang.map { " The code looks like \($0)." } ?? ""
        switch self {
        case .extract:
            return nil
        case .explain:
            return "You are a senior software engineer explaining code to another "
                + "developer. Be clear and concise. Do not rewrite the code — explain it."
                + langClause
        case .review:
            return "You are a meticulous code reviewer. Surface only real bugs, "
                + "security issues, and genuine code smells — no nitpicking. For each "
                + "finding give the severity, the offending snippet, and a concrete fix."
                + langClause
        case .debug:
            return "You are an expert at reading compiler errors, runtime exceptions, "
                + "and stack traces. Diagnose the single most likely root cause and give "
                + "a concrete, actionable fix." + langClause
        }
    }

    /// User-turn prompt wrapping the extracted code. `.extract` returns nil.
    func userPrompt(code: String) -> String? {
        let fenced = "```\n\(code)\n```"
        switch self {
        case .extract:
            return nil
        case .explain:
            return "Explain what this code does. Start with a one-line summary, then "
                + "walk through the key parts.\n\n\(fenced)"
        case .review:
            return "Review this code. List each issue with severity, the snippet, and a "
                + "fix. If it's clean, say so briefly.\n\n\(fenced)"
        case .debug:
            return "This was captured off a screen — it may be an error message, a stack "
                + "trace, or the failing code itself. Give the most likely cause and a "
                + "concrete fix.\n\n\(fenced)"
        }
    }

    // MARK: - Auto-detect

    /// Heuristic: does the extracted text look like an error / stack trace?
    /// Drives the "we pre-selected Debug for you" affordance after a capture.
    static func looksLikeError(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Strong signals — phrases that almost only appear in diagnostics.
        let strong = [
            "traceback (most recent call last)",
            "exception in thread",
            "unhandled exception",
            "fatal error",
            "panic:",
            "segmentation fault",
            "stack trace",
            "uncaught ",
            "nullpointerexception",
            "indexoutofbounds",
            "modulenotfounderror",
            "command failed with exit code"
        ]
        if strong.contains(where: { lower.contains($0) }) { return true }

        // Weaker signals need a couple of corroborating hits to avoid firing
        // on ordinary source that merely mentions "error" in a comment.
        var score = 0
        if lower.range(of: #"\berror\b"#, options: .regularExpression) != nil { score += 1 }
        if lower.range(of: #"\bexception\b"#, options: .regularExpression) != nil { score += 1 }
        if lower.range(of: #"\bwarning\b"#, options: .regularExpression) != nil { score += 1 }
        if lower.range(of: #"\bfailed\b"#, options: .regularExpression) != nil { score += 1 }
        // "file.ext:42" or "file.ext:42:9" — the classic compiler location.
        if text.range(of: #"\.\w+:\d+(:\d+)?"#, options: .regularExpression) != nil { score += 1 }
        // "at com.foo.Bar(File.java:123)" — JVM-style frame.
        if text.range(of: #"\bat .+\(.+:\d+\)"#, options: .regularExpression) != nil { score += 2 }
        return score >= 2
    }

    /// The task to pre-select right after a capture, given the extracted text.
    static func suggested(for extracted: String, default fallback: CodeTask) -> CodeTask {
        looksLikeError(extracted) ? .debug : fallback
    }
}
