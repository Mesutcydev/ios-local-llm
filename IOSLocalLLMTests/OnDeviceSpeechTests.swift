import XCTest
@testable import IOSLocalLLM

final class OnDeviceSpeechTests: XCTestCase {
    func testLiveAndFileRequestsNeverPermitServerRecognition() throws {
        let live = try OnDeviceSpeechRequests.buffer(supportsOnDeviceRecognition: true)
        let file = try OnDeviceSpeechRequests.file(url: URL(fileURLWithPath: "/tmp/local-audio-fixture.wav"),
                                                   supportsOnDeviceRecognition: true)
        XCTAssertTrue(live.requiresOnDeviceRecognition)
        XCTAssertTrue(file.requiresOnDeviceRecognition)
        XCTAssertTrue(live.shouldReportPartialResults)
        XCTAssertFalse(file.shouldReportPartialResults)
    }

    func testUnsupportedDeviceCannotCreateARecognitionRequest() {
        XCTAssertThrowsError(try OnDeviceSpeechRequests.buffer(supportsOnDeviceRecognition: false))
        XCTAssertThrowsError(try OnDeviceSpeechRequests.file(url: URL(fileURLWithPath: "/tmp/local-audio-fixture.wav"),
                                                             supportsOnDeviceRecognition: false))
    }
}
