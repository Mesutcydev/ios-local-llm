import Foundation

@main
struct StudioPolicyChecks {
    static func main() {
        let shell = StudioTextBlocks.parse("```bash\necho $$\n```")
        precondition(shell == [.code("bash", "echo $$\n")])
        precondition(StudioTextBlocks.parse("```xml\n<think>literal</think>\n```") == [.code("xml", "<think>literal</think>\n")])
        precondition(StudioTextBlocks.parse("```swift\nlet answer = 42") == [.code("swift", "let answer = 42")])
        precondition(StudioTextBlocks.parse("before $$x$$ after") == [.text("before "), .math("x"), .text(" after")])
        precondition(StudioTextBlocks.parse("<think>reason</think>answer") == [.thinking("reason", false), .text("answer")])
        precondition(StudioTextBlocks.parse("<think>reason") == [.thinking("reason", true)])
        precondition(StudioTextBlocks.parse("```swift") == [.text("```swift")])
        precondition(StudioTextBlocks.parse("Türkçe 👨‍👩‍👧‍👦") == [.text("Türkçe 👨‍👩‍👧‍👦")])
        var gate = StudioImportGate()
        let ticket = gate.generation
        precondition(gate.accepts(ticket, existing: 4_600, incoming: 400, limit: 5_000))
        precondition(!gate.accepts(ticket, existing: 4_999, incoming: 400, limit: 5_000))
        gate.reset()
        precondition(!gate.accepts(ticket, existing: 0, incoming: 1, limit: 5_000))
        precondition(gate.accepts(gate.generation, existing: 0, incoming: 1, limit: 5_000))
        let transcript = String(repeating: "Türkçe 👨‍👩‍👧‍👦 speech. ", count: 100)
        let segments = StudioTranscriptSegment.make(transcript)
        precondition(segments.map(\.text).joined() == transcript)
        precondition(segments.allSatisfy { $0.text.count <= 360 })
        precondition(segments.allSatisfy { Range($0.range, in: transcript) != nil })
        precondition(StudioTranscriptSegment.activeID(in: segments, utf16Offset: segments[1].range.location) == segments[1].id)
        precondition(StudioTranscriptSegment.make("").isEmpty)
        print("17 Studio policy checks passed")
    }
}
