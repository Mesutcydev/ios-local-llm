import XCTest
import UIKit
@testable import IOSLocalLLM

final class ConsumerContentPolicyTests: XCTestCase {
    func testImageChecksPreserveOrdinaryCreativePrompts() {
        for prompt in ["A sunset over mountains", "A fully clothed portrait", "A drawing of a tropical pineapple",
                       "A landscape in Scunthorpe", "A graphic designer at a desk"] {
            XCTAssertFalse(ConsumerContentPolicy.blocksImagePrompt(prompt), prompt)
        }
    }

    func testExplicitPromptChecksHandleCaseUnicodeAndTurkish() {
        for prompt in ["NSFW portrait", "n\u{200B}ude portrait", "ＮＵＤＥ portrait", "çıplak portre",
                       "HENTAI drawing", "graphic torture", "sexualized minor"] {
            XCTAssertTrue(ConsumerContentPolicy.blocksImagePrompt(prompt), prompt)
        }
    }

    func testSafetyInstructionsApplyWithoutChangingUserMessages() {
        let user = ChatMessage(role: .user, content: "Help me write Swift code")
        let result = ConsumerContentPolicy.messagesWithSafetyInstructions([user])
        XCTAssertEqual(result.first?.role, .system)
        XCTAssertTrue(result.first?.content.contains(ConsumerContentPolicy.safetyInstructions) == true)
        XCTAssertEqual(result.last?.content, user.content)
        let custom = ChatMessage(role: .system, content: "Answer concisely")
        let existing = ConsumerContentPolicy.messagesWithSafetyInstructions([custom, user])
        XCTAssertEqual(existing.count, 2)
        XCTAssertTrue(existing[0].content.hasSuffix(custom.content))
        XCTAssertEqual(ConsumerContentPolicy.messagesWithSafetyInstructions(existing), existing)
    }

    func testImageScoresFailClosedForSensitiveAndInvalidResults() throws {
        XCTAssertNoThrow(try GeneratedImageSafety.validate(scores: [0.1, 0, 0.9, 0, 0]))
        for scores in [[0.05, 0.15, 0.75, 0.05, 0], [0, 0, 0.7, 0, 0.3],
                       [Double.nan, 0, 1, 0, 0], [0, 0, 0, 0, 0], [1], [1.1, 0, -0.1, 0, 0]] {
            XCTAssertThrowsError(try GeneratedImageSafety.validate(scores: scores))
        }
    }

    @MainActor
    func testBundledClassifierMatchesReferenceAndWithholdsUncertainOutput() async throws {
        guard GeneratedImageSafety.modelURL != nil else {
            throw XCTSkip("Source-only Debug build has no prepared image safety weights")
        }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 224, height: 224))
        let image = renderer.image { context in
            UIColor(red: 30 / 255, green: 140 / 255, blue: 70 / 255, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 224, height: 224))
        }
        let data = try XCTUnwrap(image.pngData())
        let scores = try await GeneratedImageSafety.shared.scores(pngData: data)
        // Independent frozen-graph/Core ML reference for this out-of-distribution
        // solid color. It is uncertain, not an accuracy fixture for real photos.
        let expected = [0.40196767, 0.19284885, 0.24888666, 0.09543835, 0.06085846]
        XCTAssertEqual(scores.count, expected.count)
        for (actual, reference) in zip(scores, expected) {
            XCTAssertEqual(actual, reference, accuracy: 0.002)
        }
        do {
            try await GeneratedImageSafety.shared.check(pngData: data)
            XCTFail("An uncertain classification must withhold the output")
        } catch GeneratedImageSafety.Failure.sensitiveContent {
            // Expected: validates inference and the conservative publication gate.
        }
    }
}
