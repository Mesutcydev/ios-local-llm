import Foundation
import Speech

/// There is deliberately no request that permits server recognition.
enum OnDeviceSpeechRequests {
    static func buffer(supportsOnDeviceRecognition: Bool) throws -> SFSpeechAudioBufferRecognitionRequest {
        try requireLocalSupport(supportsOnDeviceRecognition)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        return request
    }

    static func file(url: URL, supportsOnDeviceRecognition: Bool) throws -> SFSpeechURLRecognitionRequest {
        try requireLocalSupport(supportsOnDeviceRecognition)
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return request
    }

    private static func requireLocalSupport(_ supported: Bool) throws {
        guard supported else {
            throw NSError(domain: "OnDeviceSpeech", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "On-device speech recognition is unavailable. Audio was not sent to a server."
            ])
        }
    }
}
