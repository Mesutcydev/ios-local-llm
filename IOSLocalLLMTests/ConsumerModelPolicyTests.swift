import XCTest
@testable import IOSLocalLLM

final class ConsumerModelPolicyTests: XCTestCase {
    func testFastVLMResearchWeightsAndConvertedMirrorsAreRefused() {
        XCTAssertFalse(ConsumerModelPolicy.allows(repoID: "apple/FastVLM-0.5B"))
        XCTAssertFalse(ConsumerModelPolicy.allows(repoID: "mlx-community/fastvlm-0.5b-4bit"))
        XCTAssertFalse(ConsumerModelPolicy.allows(repoID: "community/FastVLM-GGUF"))
        XCTAssertFalse(ConsumerModelPolicy.allows(repoID: "mlx-community/llava-fastvithd_0.5b_stage3_llm.fp16"))
        XCTAssertTrue(ConsumerModelPolicy.allows(repoID: "HuggingFaceTB/SmolVLM2-500M-Video-Instruct"))
    }

    @MainActor
    func testLegacyResearchSelectionMigratesToBuiltInOCR() {
        XCTAssertEqual(LocalModelRegistry.storedVisionSelectionID("apple/FastVLM-0.5B"),
                       LocalModelRegistry.defaultVisionSelectionID)
        XCTAssertEqual(LocalModelRegistry.defaultVisionSelectionID, "vision-ocr")
    }

    @MainActor
    func testOCRSelectionNeedsNoModelDownload() async {
        let settings = AppSettings.shared
        let originalID = settings.cameraVisualModelID
        let originalPicked = settings.hasPickedCameraVisualModel
        defer {
            settings.cameraVisualModelID = originalID
            settings.hasPickedCameraVisualModel = originalPicked
        }
        let selected = await VisualModelPickerView.applySelection(LocalModelRegistry.defaultVisionSelectionID)
        XCTAssertTrue(selected)
        XCTAssertEqual(LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID), "vision-ocr")
    }
}
