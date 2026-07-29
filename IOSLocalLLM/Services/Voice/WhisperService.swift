import Foundation
import AVFoundation

// MARK: - WhisperService
//
// On-device speech-to-text via whisper.cpp. Parallel to LlamaCppBridge
// — same pattern: a Swift class that owns an OpaquePointer to a C
// context and exposes a single high-level method that does the
// tokenize / decode dance internally.
//
// Why this exists alongside SpeechDictationService (which uses Apple's
// SFSpeechRecognizer): Apple's recognizer requires network access for
// many locales, ships transcripts to Apple servers under the hood for
// fallback dictation, and is not available at all on certain device
// models / regions. Whisper runs entirely on-device, works in 99
// languages off a single 142 MB model, and the GGUF weights are
// downloadable through the existing Models tab.
//
// Threading: the wrapper is `@unchecked Sendable` because the
// underlying C context is thread-safe for single-thread use only; the
// caller (a SpeechProvider impl) holds one of these and drives it
// from one queue at a time. No internal locking — that's by design.

enum WhisperError: Error, LocalizedError {
    case modelLoadFailed(String)
    case transcriptionFailed(Int32)
    case audioFormatUnsupported
    case modelNotInstalled

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let p):
            return "Failed to load whisper model at \(p)"
        case .transcriptionFailed(let code):
            return "whisper_full failed with code \(code)"
        case .audioFormatUnsupported:
            return "Audio must be mono PCM at 16 kHz for whisper.cpp"
        case .modelNotInstalled:
            return "No whisper model installed. Download one from the Models tab."
        }
    }
}

/// One loaded whisper model, ready for transcription of 16 kHz mono
/// Float32 PCM.
final class WhisperContext: @unchecked Sendable {

    /// `whisper_context *`. Same OpaquePointer trick as `LlamaCppVLM`
    /// uses for `llama_context`.
    private var ctx: OpaquePointer?

    init(modelPath: String, useGPU: Bool = true) throws {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = useGPU
        // GPU device 0 is the system default (Metal on iOS). Leave the
        // flash-attn flag at its default — whisper.cpp picks the right
        // kernel based on the model's tensor shapes.
        guard let c = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        self.ctx = c
    }

    deinit {
        if let c = ctx { whisper_free(c) }
    }

    /// Transcribe a Float32 mono PCM buffer at 16 kHz. Returns the full
    /// concatenated transcript joined across segments.
    ///
    /// `language` accepts a BCP-47-ish code ("en", "es", "tr", "auto").
    /// "auto" lets whisper detect from the first 30 s.
    func transcribe(
        samples: [Float],
        language: String = "auto",
        translateToEnglish: Bool = false,
        threadCount: Int32 = Int32(ProcessInfo.processInfo.activeProcessorCount)
    ) throws -> String {
        guard let c = ctx else { throw WhisperError.modelLoadFailed("ctx is nil") }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime    = false
        params.print_progress    = false
        params.print_timestamps  = false
        params.print_special     = false
        params.translate         = translateToEnglish
        params.single_segment    = false
        params.n_threads         = threadCount
        params.suppress_blank    = true
        params.suppress_nst      = true

        // language must be set via a C string that outlives the call.
        // Strdup-style copies in withCString are scoped to the closure,
        // which is fine because whisper_full reads it synchronously
        // before returning.
        let status: Int32 = language.withCString { langPtr -> Int32 in
            params.language = langPtr
            return samples.withUnsafeBufferPointer { buf -> Int32 in
                guard let base = buf.baseAddress else { return -1 }
                return whisper_full(c, params, base, Int32(samples.count))
            }
        }
        guard status == 0 else { throw WhisperError.transcriptionFailed(status) }

        let n = whisper_full_n_segments(c)
        var out = ""
        out.reserveCapacity(Int(n) * 32)
        for i in 0..<n {
            guard let seg = whisper_full_get_segment_text(c, i) else { continue }
            out += String(cString: seg)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - WhisperModelCatalog
//
// Resolves "which on-disk file should we hand to WhisperContext?". The
// app stores whisper GGUF/.bin weights under
//   Documents/HFModels/<repo>/<filename>.bin
// just like other models. Mirrors LlamaCppVLMService.stagedDirectory
// in spirit.

enum WhisperModelCatalog {

    /// Repo id strings the app supports out of the box. The first one
    /// (base.en) is the recommended default — ~142 MB, ~3× realtime on
    /// A17 Pro, English-only. Multilingual variants live behind opt-in
    /// catalog rows so the default install footprint stays small.
    static let baseEnRepoID    = "ggerganov/whisper.cpp"
    static let baseEnFilename  = "ggml-base.en.bin"
    /// Multilingual variant — populated by the second catalog row in
    /// ModelDownloadCenter.buildCatalog. Same repo, different file.
    static let baseMultiFilename = "ggml-base.bin"

    /// Resolve the first installed whisper model on disk. Returns nil
    /// if the user hasn't downloaded one yet — SpeechProvider must
    /// fall back to Apple's recognizer in that case.
    ///
    /// Probe order:
    ///   1. The canonical staged path used by HFModelDownloadManager
    ///      today: `HFModels/<repo>/<file>.bin` — both `.en` and
    ///      multilingual variants live under the same parent dir.
    ///   2. The historical `HFModels/ggerganov_whisper.cpp/<file>.bin`
    ///      directory layout from earlier builds, kept as a fallback so
    ///      a user who upgraded doesn't have to re-download.
    ///   3. The pre-HFModels `WhisperModels/<file>.bin` layout.
    static func installedModelPath() -> String? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let names = [baseEnFilename, baseMultiFilename]
        var candidates: [URL] = []
        for name in names {
            candidates.append(
                docs.appendingPathComponent("HFModels")
                    .appendingPathComponent(baseEnRepoID)
                    .appendingPathComponent(name)
            )
            candidates.append(
                docs.appendingPathComponent("HFModels")
                    .appendingPathComponent("ggerganov_whisper.cpp")
                    .appendingPathComponent(name)
            )
            candidates.append(
                docs.appendingPathComponent("WhisperModels")
                    .appendingPathComponent(name)
            )
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    /// True when at least one whisper model is on disk. Cheap — single
    /// fileExists walk. Used by SpeechProvider auto-routing.
    static var isInstalled: Bool { installedModelPath() != nil }
}

// MARK: - WhisperRuntime
//
// Process-wide cache for a single `WhisperContext`. Whisper.cpp keeps
// its model + decoder buffers inside the context object; recreating
// it per transcription means reloading 142 MB from disk and re-
// initialising ~250 ms of GPU/Metal state each time the user taps the
// dictation button. That cost was big enough to make Whisper feel
// slower than SFSpeechRecognizer, even though the actual inference is
// fast (~3× realtime on A17).
//
// The cache is keyed by absolute model path so a swap from base.en →
// base (multilingual) reloads cleanly. Eviction is manual via
// `unload()`; we never auto-evict, because the context is small in
// VRAM terms (~150 MB) and the user is paying for whisper.cpp
// specifically.
//
// Thread-safety: WhisperContext is single-thread by contract.
// Callers MUST serialize calls to `transcribe()` themselves —
// SpeechDictationService does this by only kicking one Task.detached
// per session.

final class WhisperRuntime: @unchecked Sendable {
    static let shared = WhisperRuntime()

    private var cached: (path: String, ctx: WhisperContext)?
    private let lock = NSLock()

    /// Return a `WhisperContext` for the given on-disk model path,
    /// reusing the previously loaded context when the path matches.
    func context(for modelPath: String) throws -> WhisperContext {
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.path == modelPath {
            return cached.ctx
        }
        // Different model — release the previous context before we
        // load the next one. The deinit hits whisper_free synchronously.
        cached = nil
        let ctx = try WhisperContext(modelPath: modelPath)
        cached = (modelPath, ctx)
        return ctx
    }

    /// Drop the cached context. Useful after the user wipes data or
    /// deletes the model file, when the cached pointer would otherwise
    /// reference a freed/now-invalid file handle.
    func unload() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}

// MARK: - PCM resampling helper
//
// Whisper requires 16 kHz mono Float32. iOS microphone capture defaults
// to 44.1 kHz or 48 kHz depending on hardware, often interleaved
// stereo. AVAudioConverter handles both rate conversion and channel
// downmix in one step; the helper wraps it so providers don't have to
// roll their own conversion graph each time.

extension WhisperContext {
    /// Convert an `AVAudioPCMBuffer` (any common iOS mic format) to the
    /// `[Float]` shape whisper expects. Returns nil if conversion
    /// fails — caller treats nil as "skip this chunk".
    static func resampleTo16kMonoFloat(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        // Fast path: already in target format.
        if buffer.format.sampleRate == 16_000,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32,
           let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { return nil }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }
        // The ratio bounds the maximum output frames for one input
        // buffer. We add a small slack for resampler tail samples.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var error: NSError?
        var fed = false
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, status != .error, let channel = out.floatChannelData?[0] else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}
