import Foundation

// MARK: - WebToolDecisionEngine
// Pure, rule-based decision layer. Reads the user's message and the current
// `WebToolSettings`, returns `WebToolDecision`. No LLM calls, no network,
// no side effects.
//
// Keywords are localized: English, Turkish, Arabic. Falls back to English
// for unknown locales.

public struct WebToolDecisionEngine: Sendable {

    private let triggers: TriggerSet
    private let queryBuilder: SearchQueryBuilder

    public init(queryBuilder: SearchQueryBuilder = SearchQueryBuilder()) {
        self.queryBuilder = queryBuilder
        self.triggers = TriggerSet.load()
    }

    public func decide(message: String, settings: WebToolSettings, locale: Locale = .current) -> WebToolDecision {
        // 1. Mode gating — `off` wins early.
        if settings.mode == .off {
            return .noWebNeeded(reason: "Web Access is off in Settings.")
        }

        // 2. Direct URL in the message? Always treat as direct fetch intent.
        if let url = Self.firstHTTPURL(in: message) {
            switch settings.mode {
            case .askEveryTime:
                return .requiresPermission(
                    reason: "This message contains a URL to fetch.",
                    payload: .url(url)
                )
            case .alwaysAllow:
                return .directURL(url)
            default:
                return .noWebNeeded(reason: "Web Access is off in Settings.")
            }
        }

        // 3. Keyword triggers — freshness, prices, news, version checks,
        //    explicit verbs.
        let langCode = locale.language.languageCode?.identifier ?? "en"
        let matched = triggers.firstMatch(in: message, lang: langCode)
            ?? triggers.firstMatch(in: message, lang: "en")

        guard let reason = matched else {
            return .noWebNeeded(reason: "No freshness/news/version trigger detected.")
        }

        // 4. Build the search query and branch on mode.
        let query = queryBuilder.buildQuery(from: message, locale: locale)
        switch settings.mode {
        case .askEveryTime:
            return .requiresPermission(reason: reason, payload: .query(query))
        case .alwaysAllow:
            return .webRecommended(reason: reason, query: query)
        case .off:
            return .noWebNeeded(reason: "Web Access is off in Settings.")
        }
    }

    // MARK: - Helpers

    private static func firstHTTPURL(in text: String) -> URL? {
        // Match a bare http(s) URL token. Trim trailing punctuation.
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s)\]"']+"#) else {
            return nil
        }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.range.location != NSNotFound else { return nil }
        var raw = ns.substring(with: m.range)
        // Drop trailing punctuation people often leave attached
        while let last = raw.last, ".,;:!?\"')]".contains(last) {
            raw.removeLast()
        }
        return URL(string: raw)
    }
}

// MARK: - Trigger keyword set

private struct TriggerSet: Sendable {
    let keywordsByLang: [String: [String]]

    func firstMatch(in text: String, lang: String) -> String? {
        let lowered = text.lowercased()
        guard let phrases = keywordsByLang[lang] else { return nil }
        for phrase in phrases {
            let p = phrase.lowercased()
            if lowered.contains(p) {
                return "Detected \"\(phrase)\" — fresh web sources may help."
            }
        }
        return nil
    }

    /// Loads from the bundled JSON. Falls back to a hardcoded minimal set if
    /// the bundle resource is missing (defense in depth — never crash).
    static func load() -> TriggerSet {
        if let url = Bundle.main.url(forResource: "WebTriggerKeywords", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            return TriggerSet(keywordsByLang: decoded)
        }
        // Fallback — keep in sync with WebTriggerKeywords.json.
        return TriggerSet(keywordsByLang: [
            "en": [
                "latest version", "current version", "just released",
                "is deprecated", "breaking change", "migration guide",
                "today", "this week", "yesterday",
                "price", "stock", "news", "release notes", "changelog",
                "app store guidelines", "review guidelines",
                "latest xcode", "latest swift", "latest ios",
                "github.com", "npm latest",
                "look up", "search for", "check online", "open url",
                "documentation for", "api reference"
            ],
            "tr": [
                "en son sürüm", "güncel sürüm", "yeni çıktı",
                "kullanımdan kaldırıldı", "bugün", "bu hafta", "dün",
                "fiyat", "haber", "sürüm notları",
                "internette ara", "kontrol et", "url aç"
            ],
            "ar": [
                "أحدث إصدار", "الإصدار الحالي", "صدر حديثاً",
                "مهمل", "اليوم", "هذا الأسبوع", "أمس",
                "سعر", "أخبار", "ابحث", "افتح رابط"
            ]
        ])
    }
}
