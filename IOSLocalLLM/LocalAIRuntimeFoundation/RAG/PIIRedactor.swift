import Foundation

// MARK: - PIIRedactor

public enum PIIRedactor {
    private static let patterns: [(label: String, pattern: String)] = [
        ("EMAIL", #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#),
        ("PHONE", #"\b(?:\+?\d{1,3}[\s.-]?)?(?:\(?\d{3}\)?[\s.-]?)\d{3}[\s.-]?\d{4}\b"#),
        ("API_KEY", #"\b(?:sk|pk|rk|ghp|github_pat|hf|xox[baprs])_[A-Za-z0-9_\-]{16,}\b"#),
        ("BEARER_TOKEN", #"\bBearer\s+[A-Za-z0-9._\-]{20,}\b"#),
        ("PRIVATE_URL", #"\bhttps?://(?:localhost|127\.0\.0\.1|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})[^\s)]*"#),
    ]

    public static func redact(_ text: String) -> String {
        var output = text
        for item in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: item.pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: "[REDACTED_\(item.label)]"
            )
        }
        return output
    }
}
