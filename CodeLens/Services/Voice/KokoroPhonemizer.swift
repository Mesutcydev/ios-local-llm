// MARK: - KokoroPhonemizer
//
// Text → Kokoro phoneme-ID sequence using the model's own
// vocab_index.json vocabulary.
//
// The Kokoro-82M CoreML model (kokoro_5s.mlmodelc) expects
// `input_ids` as INT32 phoneme token IDs drawn from the vocabulary
// in `vocab_index.json`. This vocabulary is similar to but NOT
// identical to the StyleTTS2 vocabulary used by KittenTTS /
// PhonemizerEN — the punctuation regions mostly align below ID 17,
// and the IPA regions align from ID 69+, but the letter ranges
// differ. Feeding KittenTTS vocab IDs to the Kokoro model produces
// silent or garbled output because every token decodes to the wrong
// symbol.
//
// This phonemizer:
//   1. Converts text → IPA phoneme characters (same CMUdict + ARPAbet
//      logic as PhonemizerEN).
//   2. Maps each IPA / punctuation character to an ID using
//      vocab_index.json.
//   3. Wraps the sequence with BOS (1) and EOS (2) tokens — the
//      framing the upstream Kokoro pipeline uses.
//   4. Returns the unpadded sequence; the caller (KokoroTTSService)
//      pads to 128 and builds the attention mask.

import Foundation

final class KokoroPhonemizer {

    static let shared = KokoroPhonemizer()

    // Token IDs from vocab_index.json
    let bosTokenID: Int32
    let eosTokenID: Int32
    let padTokenID: Int32

    private var loaded = false
    private let loadLock = NSLock()
    private var charToID: [Character: Int32] = [:]
    private var maxID: Int32 = 0

    // CMUdict: lowercased word → ARPAbet phonemes
    private var dict: [String: [String]] = [:]

    private init() {
        // Safe defaults — real values loaded from vocab_index.json.
        bosTokenID = 1
        eosTokenID = 2
        padTokenID = 0
    }

    // MARK: - Public API

    /// Returns the phoneme-ID sequence for `text`, framed with
    /// BOS (1) … EOS (2). The caller pads to the model's fixed
    /// 128-token window.
    func phonemeIDs(for text: String) -> [Int32] {
        loadIfNeeded()
        let phonemeChars = phonemes(for: text)
        var ids: [Int32] = []
        ids.reserveCapacity(phonemeChars.count + 2)
        ids.append(bosTokenID)
        for ch in phonemeChars {
            if let id = charToID[ch] {
                ids.append(id)
            } else {
                // Character not in Kokoro's vocab — skip it so the
                // model still sees a valid sequence. Unknown chars
                // are rare (the CMUdict + LTS path only emits chars
                // from a known IPA set).
            }
        }
        ids.append(eosTokenID)
        return ids
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        loadLock.lock()
        defer { loadLock.unlock() }
        if loaded { return }
        loadVocabIndex()
        loadCMUdict()
        loaded = true
    }

    /// Load vocab_index.json — the phoneme symbol → ID table.
    /// Ships alongside kokoro_5s.mlmodelc in the bundle.
    private func loadVocabIndex() {
        var table: [Character: Int32] = [:]
        let fm = FileManager.default

        // Search roots: bundled first, then Documents/VoiceModels/.
        let roots: [URL] = {
            var urls: [URL] = []
            if let bundled = VoiceModelBundleValidator.bundledVoiceModelsRoot() {
                urls.append(bundled)
            }
            urls.append(VoiceModelBundleValidator.voiceModelsRoot())
            return urls
        }()

        for root in roots {
            let url = root
                .appendingPathComponent("Kokoro", isDirectory: true)
                .appendingPathComponent("vocab_index.json")
            guard fm.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let vocab = json["vocab"] as? [String: Any]
            else { continue }

            for (symbol, rawID) in vocab {
                guard symbol.count == 1, let ch = symbol.first else { continue }
                let id: Int32
                if let i = rawID as? Int { id = Int32(i) }
                else if let d = rawID as? Double { id = Int32(d) }
                else { continue }
                table[ch] = id
                if id > maxID { maxID = id }
            }
            break
        }

        charToID = table
    }

    private func loadCMUdict() {
        guard let url = Bundle.main.url(forResource: "cmudict", withExtension: "txt"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            #if DEBUG
            print("[KokoroPhonemizer] cmudict.txt missing — using LTS for all words.")
            #endif
            return
        }
        var d: [String: [String]] = [:]
        d.reserveCapacity(130_000)
        text.enumerateLines { line, _ in
            var first = true
            var word = ""
            var phones: [String] = []
            for piece in line.split(separator: " ", omittingEmptySubsequences: true) {
                if first { word = String(piece); first = false }
                else     { phones.append(String(piece)) }
            }
            if !word.isEmpty && !phones.isEmpty {
                d[word] = phones
            }
        }
        dict = d
    }

    // MARK: - Text → phoneme chars
    //
    // Same pipeline as PhonemizerEN: word-level CMUdict lookup with
    // ARPAbet → IPA conversion, LTS fallback for OOV words.

    private func phonemes(for text: String) -> [Character] {
        var out: [Character] = []
        var word = ""
        var firstTokenEmitted = false

        func flushWord() {
            guard !word.isEmpty else { return }
            let lower = word.lowercased()
            if !out.isEmpty && firstTokenEmitted { out.append(" ") }
            if let arpa = dict[lower] {
                out.append(contentsOf: arpabetToIPA(arpa))
            } else {
                out.append(contentsOf: lettersToIPA(lower))
            }
            firstTokenEmitted = true
            word.removeAll(keepingCapacity: true)
        }

        for ch in text {
            if ch.isLetter || ch == "'" || ch == "’" {
                word.append(ch)
            } else if ch.isNumber {
                if !word.isEmpty { flushWord() }
                let spoken = digitWord(ch)
                if !out.isEmpty && firstTokenEmitted { out.append(" ") }
                if let arpa = dict[spoken] {
                    out.append(contentsOf: arpabetToIPA(arpa))
                } else {
                    out.append(contentsOf: lettersToIPA(spoken))
                }
                firstTokenEmitted = true
            } else {
                flushWord()
                // Pass through punctuation that Kokoro's vocab
                // recognizes (period, comma, question mark, etc.).
                // The model uses these for prosody.
                if charToID[ch] != nil {
                    out.append(ch)
                }
            }
        }
        flushWord()
        return out
    }

    private func digitWord(_ c: Character) -> String {
        switch c {
        case "0": return "zero"
        case "1": return "one"
        case "2": return "two"
        case "3": return "three"
        case "4": return "four"
        case "5": return "five"
        case "6": return "six"
        case "7": return "seven"
        case "8": return "eight"
        case "9": return "nine"
        default:  return String(c)
        }
    }

    // MARK: - ARPAbet → IPA
    //
    // PhonemizerEN-compatible ARPAbet→IPA table. Each ARPAbet phoneme
    // maps to one or two IPA characters + optional stress markers.

    private func arpabetToIPA(_ phones: [String]) -> [Character] {
        var out: [Character] = []
        for raw in phones {
            var stress: Character? = nil
            var code = raw
            if let last = code.last, last.isASCII, last.isNumber {
                switch last {
                case "1": stress = "ˈ"
                case "2": stress = "ˌ"
                default:  stress = nil
                }
                code.removeLast()
            }
            if let s = stress, Self.arpabetIsVowel(code) {
                // Kokoro vocab_index.json includes stress markers
                // — insert if present.
                if charToID[s] != nil { out.append(s) }
            }
            if code == "AH" {
                out.append(stress == nil ? "ə" : "ʌ")
                continue
            }
            for ch in Self.arpabetToIPATable[code] ?? [] {
                out.append(ch)
            }
        }
        return out
    }

    private static func arpabetIsVowel(_ code: String) -> Bool {
        switch code {
        case "AA","AE","AH","AO","AW","AY","EH","ER","EY","IH","IY","OW","OY","UH","UW":
            return true
        default:
            return false
        }
    }

    private static let arpabetToIPATable: [String: [Character]] = [
        "AA": ["ɑ"], "AE": ["æ"], "AO": ["ɔ"],
        "EH": ["ɛ"], "ER": ["ɝ"], "IH": ["ɪ"],
        "IY": ["i"], "UH": ["ʊ"], "UW": ["u"],
        "AW": ["a", "ʊ"], "AY": ["a", "ɪ"],
        "EY": ["e", "ɪ"], "OW": ["o", "ʊ"],
        "OY": ["ɔ", "ɪ"],
        "B":  ["b"], "CH": ["ʧ"], "D":  ["d"],
        "DH": ["ð"], "F":  ["f"], "G":  ["ɡ"],
        "HH": ["h"], "JH": ["ʤ"], "K":  ["k"],
        "L":  ["l"], "M":  ["m"], "N":  ["n"],
        "NG": ["ŋ"], "P":  ["p"], "R":  ["ɹ"],
        "S":  ["s"], "SH": ["ʃ"], "T":  ["t"],
        "TH": ["θ"], "V":  ["v"], "W":  ["w"],
        "Y":  ["j"], "Z":  ["z"], "ZH": ["ʒ"]
    ]

    // MARK: - LTS fallback
    //
    // Heuristic letter-to-sound rules for OOV words. Only used when
    // CMUdict has no entry (~1% of conversational English).

    private func lettersToIPA(_ word: String) -> [Character] {
        var out: [Character] = []
        let chars = Array(word)
        var i = 0
        var stressPlaced = false
        func placeStressIfNeeded() {
            if !stressPlaced, charToID["ˈ"] != nil {
                out.append("ˈ"); stressPlaced = true
            }
        }
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "a" where next == "i" || next == "y":
                placeStressIfNeeded(); out.append("e"); out.append("ɪ"); i += 2; continue
            case "a" where next == "u" || next == "w":
                placeStressIfNeeded(); out.append("ɔ"); i += 2; continue
            case "e" where next == "e", "e" where next == "a":
                placeStressIfNeeded(); out.append("i"); i += 2; continue
            case "i" where next == "e":
                placeStressIfNeeded(); out.append("i"); i += 2; continue
            case "o" where next == "a", "o" where next == "w":
                placeStressIfNeeded(); out.append("o"); out.append("ʊ"); i += 2; continue
            case "o" where next == "o":
                placeStressIfNeeded(); out.append("u"); i += 2; continue
            case "o" where next == "u":
                placeStressIfNeeded(); out.append("a"); out.append("ʊ"); i += 2; continue
            case "o" where next == "i" || next == "y":
                placeStressIfNeeded(); out.append("ɔ"); out.append("ɪ"); i += 2; continue
            case "u" where next == "e":
                placeStressIfNeeded(); out.append("j"); out.append("u"); i += 2; continue
            case "c" where next == "h":
                out.append("ʧ"); i += 2; continue
            case "s" where next == "h":
                out.append("ʃ"); i += 2; continue
            case "t" where next == "h":
                out.append("θ"); i += 2; continue
            case "p" where next == "h":
                out.append("f"); i += 2; continue
            case "n" where next == "g":
                out.append("ŋ"); i += 2; continue
            case "a":
                placeStressIfNeeded(); out.append("æ"); i += 1; continue
            case "e":
                placeStressIfNeeded(); out.append("ɛ"); i += 1; continue
            case "i":
                placeStressIfNeeded(); out.append("ɪ"); i += 1; continue
            case "o":
                placeStressIfNeeded(); out.append("ɑ"); i += 1; continue
            case "u":
                placeStressIfNeeded(); out.append("ʌ"); i += 1; continue
            case "y":
                out.append("j"); i += 1; continue
            case "b": out.append("b"); i += 1; continue
            case "c": out.append("k"); i += 1; continue
            case "d": out.append("d"); i += 1; continue
            case "f": out.append("f"); i += 1; continue
            case "g": out.append("ɡ"); i += 1; continue
            case "h": out.append("h"); i += 1; continue
            case "j": out.append("ʤ"); i += 1; continue
            case "k": out.append("k"); i += 1; continue
            case "l": out.append("l"); i += 1; continue
            case "m": out.append("m"); i += 1; continue
            case "n": out.append("n"); i += 1; continue
            case "p": out.append("p"); i += 1; continue
            case "q": out.append("k"); i += 1; continue
            case "r": out.append("ɹ"); i += 1; continue
            case "s": out.append("s"); i += 1; continue
            case "t": out.append("t"); i += 1; continue
            case "v": out.append("v"); i += 1; continue
            case "w": out.append("w"); i += 1; continue
            case "x": out.append("k"); out.append("s"); i += 1; continue
            case "z": out.append("z"); i += 1; continue
            default: i += 1
            }
        }
        return out
    }
}
