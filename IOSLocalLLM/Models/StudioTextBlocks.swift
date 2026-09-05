import Foundation

/// One tokenizer for chat, Lens, and code review. Fenced code is opaque.
enum StudioTextBlocks {
    enum Block: Equatable, Sendable {
        case text(String)
        case code(String, String)
        case thinking(String, Bool)
        case math(String)
    }

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var remaining = source[...]
        while !remaining.isEmpty {
            let candidates = ["```", "<think>", "$$"].compactMap { marker in
                remaining.range(of: marker).map { (marker, $0) }
            }
            guard let (marker, range) = candidates.min(by: { $0.1.lowerBound < $1.1.lowerBound }) else {
                blocks.append(.text(String(remaining)))
                break
            }
            if range.lowerBound > remaining.startIndex {
                blocks.append(.text(String(remaining[..<range.lowerBound])))
            }
            remaining = remaining[range.upperBound...]
            if marker == "```" {
                guard let newline = remaining.firstIndex(of: "\n") else {
                    // Incomplete opening fence: preserve it until a language/body arrives.
                    blocks.append(.text("```" + remaining))
                    break
                }
                let language = String(remaining[..<newline]).trimmingCharacters(in: .whitespaces)
                remaining = remaining[remaining.index(after: newline)...]
                if let end = remaining.range(of: "```") {
                    blocks.append(.code(language, String(remaining[..<end.lowerBound])))
                    remaining = remaining[end.upperBound...]
                } else {
                    blocks.append(.code(language, String(remaining)))
                    break
                }
            } else {
                let closing = marker == "<think>" ? "</think>" : "$$"
                if let end = remaining.range(of: closing) {
                    let body = String(remaining[..<end.lowerBound])
                    blocks.append(marker == "<think>" ? .thinking(body, false) : .math(body))
                    remaining = remaining[end.upperBound...]
                } else {
                    blocks.append(marker == "<think>" ? .thinking(String(remaining), true) : .text(marker + remaining))
                    break
                }
            }
        }
        return blocks
    }
}

/// A reset invalidates work already running; capacity is checked again at commit.
struct StudioImportGate {
    private(set) var generation: UInt64 = 0
    mutating func reset() { generation &+= 1 }
    func accepts(_ ticket: UInt64, existing: Int, incoming: Int, limit: Int) -> Bool {
        ticket == generation && incoming > 0 && existing <= limit && incoming <= limit - existing
    }
}

struct StudioTranscriptSegment: Identifiable, Equatable {
    let id: Int // UTF-16 offset, stable as the transcript grows
    let range: NSRange
    let text: String

    static func make(_ text: String) -> [Self] {
        var result: [Self] = []
        var start = text.startIndex
        while start < text.endIndex {
            let limit = text.index(start, offsetBy: 360, limitedBy: text.endIndex) ?? text.endIndex
            let candidate = text[start..<limit]
            let boundary = candidate.lastIndex(where: { $0.isWhitespace || $0 == "." })
            let end = limit == text.endIndex ? limit : boundary.map { text.index(after: $0) } ?? limit
            let range = NSRange(start..<end, in: text)
            result.append(.init(id: range.location, range: range, text: String(text[start..<end])))
            start = end
        }
        return result
    }

    static func activeID(in segments: [Self], utf16Offset: Int) -> Int? {
        segments.first { NSLocationInRange(max(0, utf16Offset), $0.range) }?.id ?? segments.last?.id
    }
}
