import Foundation
import Speech
import AVFoundation

// MARK: - AudioTranscriptionService
// Transcribes a local audio file using Apple's SFSpeechRecognizer in
// on-device mode (no Apple Cloud round-trip when the device supports it).
// Whisper-Core ML can later be wired in here without changing the public API.
//
// Usage:
//   let text = try await AudioTranscriptionService.shared.transcribe(fileURL: url)
//   chatComposer.text = text

@MainActor
final class AudioTranscriptionService {

    static let shared = AudioTranscriptionService()

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private init() {}

    /// Requests permission then transcribes the file. Returns plain text.
    func transcribe(fileURL: URL) async throws -> String {
        // Permission
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw NSError(domain: "Transcription", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Speech recognition permission denied."
            ])
        }

        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Transcription", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Speech recognition not available right now."
            ])
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        guard recognizer.supportsOnDeviceRecognition else {
            throw NSError(domain: "AudioTranscription", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "On-device speech recognition isn't available on this device."
            ])
        }
        request.requiresOnDeviceRecognition = true

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }
}
