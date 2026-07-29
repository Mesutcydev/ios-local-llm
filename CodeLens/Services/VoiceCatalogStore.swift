import Combine
import Foundation

@MainActor
final class VoiceCatalogStore: ObservableObject {
    static let shared = VoiceCatalogStore()
    static let schemaVersion = 2
    static let resourceName = "VoiceModelCatalog"

    @Published private(set) var allEntries: [VoiceCatalogEntry] = []
    @Published private(set) var loadState: VoiceCatalogLoadState = .idle
    @Published private(set) var loadError: String?

    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        load()
    }

    func load() {
        loadState = .loading
        do {
            guard let url = bundle.url(forResource: Self.resourceName, withExtension: "json") else {
                throw CatalogError.resourceMissing
            }
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(VoiceCatalogDocument.self, from: data)
            guard document.schemaVersion == Self.schemaVersion else {
                throw CatalogError.schemaMismatch(document.schemaVersion)
            }
            allEntries = document.entries
            loadError = nil
            loadState = .loaded
            UserDefaults.standard.set(Self.schemaVersion, forKey: "voiceCatalogSchemaVersion")
            print("[VoiceCatalog] loaded \(allEntries.count) production entries from \(url.lastPathComponent)")
        } catch {
            loadError = error.localizedDescription
            loadState = .failed
            allEntries = Self.completeFallback
            assertionFailure("Voice catalog decode failed: \(error)")
            print("[VoiceCatalog] decode failed: \(error); using complete fallback (\(allEntries.count) entries)")
        }
    }

    func entries(task: VoiceCatalogTask? = nil, query: String = "") -> [VoiceCatalogEntry] {
        allEntries.filter { entry in
            (task == nil || entry.task == task)
                && (query.isEmpty
                    || entry.name.localizedCaseInsensitiveContains(query)
                    || entry.summary.localizedCaseInsensitiveContains(query))
        }
    }

    enum CatalogError: LocalizedError {
        case resourceMissing
        case schemaMismatch(Int)
        var errorDescription: String? {
            switch self {
            case .resourceMissing: return "VoiceModelCatalog.json is missing from the app bundle."
            case .schemaMismatch(let version): return "Unsupported voice catalog schema \(version)."
            }
        }
    }

    // This is deliberately complete: decoding failure must never resurrect the
    // obsolete four-card catalog. The integrity tests pin parity with JSON.
    static let completeFallback: [VoiceCatalogEntry] = VoiceCatalogFallback.entries
}

private enum VoiceCatalogFallback {
    static let entries: [VoiceCatalogEntry] = [
        e("tts.apple.system", "Apple System Voices", .textToSpeech, "Built-in Apple voices managed in system settings.", nil, .production, true, nil),
        e("tts.kokoro.82m.official", "Kokoro-82M", .textToSpeech, "Compact multilingual neural speech synthesis.", "https://huggingface.co/hexgrad/Kokoro-82M", .production, true, "kokoro-82m"),
        e("tts.kitten.micro.0_8", "KittenTTS Micro", .textToSpeech, "Official KittenML ONNX · 8 English voices.", "https://huggingface.co/KittenML/kitten-tts-micro-0.8", .production, true, "tts.kitten.micro.0_8"),
        e("tts.kitten.nano.0_8.int8", "KittenTTS Nano INT8", .textToSpeech, "Official quantized KittenML ONNX · 8 English voices.", "https://huggingface.co/KittenML/kitten-tts-nano-0.8-int8", .production, true, "tts.kitten.nano.0_8.int8"),
        e("tts.kitten.nano.0_8.fp32", "KittenTTS Nano FP32", .textToSpeech, "Full-precision KittenTTS Nano.", "https://huggingface.co/KittenML/kitten-tts-nano-0.8-fp32", .catalogOnly, false, nil),
        e("tts.kitten.mini.0_8", "KittenTTS Mini", .textToSpeech, "Official higher-quality KittenML ONNX · 8 English voices.", "https://huggingface.co/KittenML/kitten-tts-mini-0.8", .production, true, "tts.kitten.mini.0_8"),
        e("tts.piper.family", "Piper Voices", .textToSpeech, "Fast multilingual Piper voice family.", "https://huggingface.co/rhasspy/piper-voices", .licenseReview, false, nil),
        e("tts.melotts.family", "MeloTTS", .textToSpeech, "Multilingual text-to-speech by MyShell.", "https://github.com/myshell-ai/MeloTTS", .catalogOnly, false, nil),
        e("tts.parler.mini.v1_1", "Parler-TTS Mini", .textToSpeech, "Description-guided expressive speech.", "https://huggingface.co/parler-tts/parler-tts-mini-v1.1", .catalogOnly, false, nil),
        e("tts.parler.mini.multilingual.v1_1", "Parler-TTS Mini Multilingual", .textToSpeech, "Multilingual description-guided speech.", "https://huggingface.co/parler-tts/parler-tts-mini-multilingual-v1.1", .catalogOnly, false, nil),
        e("tts.outetts.family", "OuteTTS", .textToSpeech, "OuteAI speech synthesis family.", "https://github.com/edwko/OuteTTS", .catalogOnly, false, nil),
        e("tts.qwen.family", "Qwen-TTS", .textToSpeech, "Qwen speech synthesis family; native adapter pending.", "https://github.com/QwenLM/Qwen3-TTS", .catalogOnly, false, nil),
        e("tts.f5.family", "F5-TTS", .textToSpeech, "Flow-matching speech synthesis research model.", "https://github.com/SWivid/F5-TTS", .macOnly, false, nil),
        e("tts.chatterbox.family", "Chatterbox TTS", .textToSpeech, "Expressive open speech synthesis.", "https://github.com/resemble-ai/chatterbox", .catalogOnly, false, nil),
        e("tts.xtts.v2", "XTTS v2", .textToSpeech, "Coqui multilingual voice cloning model.", "https://huggingface.co/coqui/XTTS-v2", .licenseReview, false, nil),
        e("tts.styletts2.family", "StyleTTS2", .textToSpeech, "Style diffusion speech synthesis.", "https://github.com/yl4579/StyleTTS2", .macOnly, false, nil),
        e("stt.whisper.tiny", "Whisper Tiny", .speechRecognition, "Multilingual Whisper Tiny.", "https://github.com/argmaxinc/argmax-oss-swift", .catalogOnly, false, nil),
        e("stt.whisper.tiny.en", "Whisper Tiny.en", .speechRecognition, "English Whisper Tiny.", "https://github.com/argmaxinc/argmax-oss-swift", .catalogOnly, false, nil),
        e("stt.whisper.base", "Whisper Base", .speechRecognition, "Multilingual Whisper Base.", "https://github.com/argmaxinc/argmax-oss-swift", .production, true, "whisper-base-multi"),
        e("stt.whisper.base.en", "Whisper Base.en", .speechRecognition, "English Whisper Base.", "https://github.com/argmaxinc/argmax-oss-swift", .production, true, "whisper-base-en"),
        e("stt.whisper.small", "Whisper Small", .speechRecognition, "Multilingual Whisper Small.", "https://github.com/argmaxinc/argmax-oss-swift", .catalogOnly, false, nil),
        e("stt.whisper.small.en", "Whisper Small.en", .speechRecognition, "English Whisper Small.", "https://github.com/argmaxinc/argmax-oss-swift", .catalogOnly, false, nil),
        e("stt.moonshine.base", "Moonshine Base", .speechRecognition, "Efficient on-device speech recognition.", "https://huggingface.co/UsefulSensors/moonshine-base", .catalogOnly, false, nil),
        e("stt.moonshine.streaming-tiny", "Moonshine Streaming Tiny", .speechRecognition, "Low-latency streaming recognition.", "https://huggingface.co/UsefulSensors/moonshine-streaming-tiny", .catalogOnly, false, nil),
        e("stt.moonshine.streaming-medium", "Moonshine Streaming Medium", .speechRecognition, "Higher-accuracy streaming recognition.", "https://huggingface.co/UsefulSensors/moonshine-streaming-medium", .catalogOnly, false, nil),
    ]

    private static func e(_ id: String, _ name: String, _ task: VoiceCatalogTask,
                          _ summary: String, _ source: String?,
                          _ support: VoiceCatalogSupportLevel, _ runtime: Bool,
                          _ legacyID: String?) -> VoiceCatalogEntry {
        VoiceCatalogEntry(id: id, name: name, task: task, summary: summary,
                          sourceURL: source, supportLevel: support,
                          runtimeAvailable: runtime, legacyDownloadID: legacyID,
                          sizeLabel: nil)
    }
}
