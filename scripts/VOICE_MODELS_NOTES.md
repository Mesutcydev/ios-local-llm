# Voice Models — Setup Notes

CodeLens supports three text-to-speech engines:

| Engine | Size | Quality | Requires Download |
|--------|------|---------|-------------------|
| Apple System Voice | — | Good | No |
| KittenTTS Nano | ~61 MB | High (24 kHz) | Yes |
| KittenTTS Mini | ~280 MB | Higher (24 kHz) | Yes |
| Kokoro-82M | ~82 MB | High (24 kHz) | Yes (experimental) |

---

## Quick Start

```bash
# KittenTTS Nano (recommended):
./scripts/download_voice_models.sh nano

# KittenTTS Mini (higher quality):
./scripts/download_voice_models.sh mini

# Also download Kokoro (experimental):
./scripts/download_voice_models.sh nano --kokoro
```

The script auto-detects a booted iOS Simulator and copies files to its
`Documents/VoiceModels/` directory. For a physical device, use `--staging-dir`:

```bash
./scripts/download_voice_models.sh nano --staging-dir=/path/to/staging
# Then copy VoiceModels/ into the app's Documents folder via Xcode → Device & Simulators → Files
```

---

## Manual File Layout

Place files here (relative to the app's Documents folder):

```
Documents/
└── VoiceModels/
    ├── KittenTTS/
    │   ├── kitten_tts_nano.mlpackage/   ← OR kitten_tts_mini.mlpackage/
    │   └── voices.npz
    └── Kokoro/
        └── kokoro.mlpackage/            ← optional, experimental
```

---

## Model Sources

### KittenTTS CoreML
- Repo: https://huggingface.co/alexwengg/kittentts-coreml
- Architecture: Kokoro-based TTS, CoreML-exported
- Voices: 8 English voices (American + British, male + female)
- Sample rate: 24 kHz
- License: Apache 2.0

### Kokoro-82M (Experimental)
- Repo: https://huggingface.co/hexgrad/Kokoro-82M
- Note: CoreML export may require manual conversion — check the repo for
  updated `mlpackage` exports. The `KokoroTTSService` skeleton is ready
  to activate once the model file is present.
- Sample rate: 24 kHz
- License: Apache 2.0

---

## G2P (Text-to-Phoneme) Notes

KittenTTS and Kokoro are phoneme-input models — they require converting
English text to IPA phoneme token IDs before synthesis.

CodeLens uses `BasicG2P` (in `KittenTTSService.swift`), a rule-based
English letter-to-sound engine. It handles common English prose adequately.

**Limitations:**
- Not trained; uses hand-written rules + a small common-word dictionary
- Non-English text, technical abbreviations (e.g. `async`, `sizeof`), and
  proper nouns may be mispronounced
- Does not support SSML

**Upgrade path:** Replace `BasicG2P.phonemeIDs(for:)` with a proper
phonemizer (e.g. a Core ML–exported G2P model) for production-quality output.
Apple System Voice has no G2P limitation — it handles all of this natively.

---

## Privacy

All synthesis is 100% on-device. No audio or text is transmitted to any server.
