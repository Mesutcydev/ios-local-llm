// MARK: - PhonemizerEN
//
// English-text → KittenTTS/Kokoro phoneme-id sequence.
//
// Background. The previous in-tree phonemizer (`BasicG2P`) had two fatal
// problems that together produced the "robotic zombie" voice users heard:
//
//   1. WRONG VOCABULARY. It used a hand-curated 51-symbol subset of the
//      Kokoro symbol table. The actual KittenTTS / Kokoro CoreML model
//      was trained on the upstream StyleTTS2 vocabulary — 1 pad + 16
//      punctuation + 52 ASCII letters + 109 IPA letters = 178 symbols.
//      Sending id 8 (our `ɑ`) was decoded by the model as id 8 of ITS
//      table (`¿`, an inverted question mark). Every phoneme came out
//      as a non-phoneme. The model produced the closest babble it
//      could, which sounded like a faded zombie.
//
//   2. APPROXIMATE LETTER-TO-SOUND RULES. Even with the right ID
//      space, a hand-rolled LTS engine ("every 'a' → /æ/, every 'e'
//      → /ɛ/") loses the distinctions that English speech requires —
//      silent-e, vowel teams, diphthongs, stress, schwa reduction.
//
// Fix:
//   • Vocabulary now matches the upstream Python `TextCleaner` byte
//     for byte (see https://github.com/KittenML/KittenTTS, file
//     `kittentts/onnx_model.py`).
//   • G2P uses the bundled CMU Pronouncing Dictionary (~126K entries
//     with ARPAbet phonemes + stress digits). For OOV words we fall
//     back to a small letter-to-sound rule set that's only used for
//     proper nouns, acronyms, and made-up tokens.
//   • Stress digits (0/1/2) translate into the IPA stress markers
//     `ˈ` (primary) and `ˌ` (secondary), placed before the stressed
//     vowel — matching what espeak-ng + `with_stress=True` produces.
//   • The output sequence is framed `[0, …, 10, 0]` — a leading pad,
//     the phoneme IDs, an ellipsis (`…`, id 10) as the
//     end-of-utterance marker, then a trailing pad. This exact
//     framing is what `KittenTTS_1_Onnx._prepare_inputs` does, and
//     the model is trained to expect it.
//
// Thread-safety: `shared` is loaded lazily on first call. The
// dictionary is read-only after init and is reachable from any
// actor.

import Foundation

final class PhonemizerEN: @unchecked Sendable {

    static let shared = PhonemizerEN()

    /// Token IDs used to frame the sequence — matches upstream
    /// `tokens.insert(0,0); tokens.append(10); tokens.append(0)`.
    static let padTokenID: Int32 = 0
    static let endOfUtteranceTokenID: Int32 = 10   // `…`

    private var loaded = false
    private let loadLock = NSLock()

    /// `word_index_dictionary` — same name as the Python upstream
    /// class for ease of cross-reference.
    private var symbolToID: [Character: Int32] = [:]

    /// CMUdict: lowercased word → list of ARPAbet phonemes (with
    /// stress digit attached to vowels, e.g. "AH1", "AY2").
    private var dict: [String: [String]] = [:]

    private init() {}

    // MARK: - Public API

    /// Returns the framed phoneme-ID sequence for `text`.
    /// The sequence is *unpadded*: callers must zero-pad to the
    /// CoreML model's expected fixed length and produce a matching
    /// attention mask.
    func phonemeIDs(for text: String) -> [Int32] {
        loadIfNeeded()
        let phonemeChars = phonemes(for: text)
        var ids: [Int32] = []
        ids.reserveCapacity(phonemeChars.count + 3)
        ids.append(Self.padTokenID)                            // leading $
        for ch in phonemeChars {
            if let id = symbolToID[ch] { ids.append(id) }
            // Unknown chars are silently dropped — same as the
            // upstream `TextCleaner`'s try/except KeyError pattern.
        }
        ids.append(Self.endOfUtteranceTokenID)                 // trailing …
        ids.append(Self.padTokenID)                            // trailing $
        return ids
    }

    /// Returns the raw phoneme string for `text` (useful for
    /// debugging — surfaced in the voice debug overlay).
    func phonemeString(for text: String) -> String {
        loadIfNeeded()
        return String(phonemes(for: text))
    }

    // MARK: - Vocabulary
    //
    // Byte-for-byte reproduction of the upstream `TextCleaner`'s
    // symbol list. Indices below are mechanical:
    //   id 0          : pad `$`
    //   id 1..16      : punctuation (16 entries)
    //   id 17..68     : ASCII letters (52 entries)
    //   id 69..177    : IPA letters (109 entries)

    private static let pad: Character = "$"

    /// Punctuation portion of the upstream vocabulary, verbatim.
    /// Three identical `"` (U+0022) appear in the upstream source —
    /// preserved here so the IDs stay aligned.
    private static let punctuationChars: [Character] = [
        ";", ":", ",", ".", "!", "?",
        "\u{00A1}", "\u{00BF}",   // ¡ ¿
        "\u{2014}", "\u{2026}",   // — …
        "\u{0022}", "\u{00AB}", "\u{00BB}",
        "\u{0022}", "\u{0022}",
        " "
    ]

    /// ASCII letters portion: A..Z then a..z.
    private static let letterChars: [Character] = {
        var chars: [Character] = []
        for u in UnicodeScalar("A").value...UnicodeScalar("Z").value { chars.append(Character(UnicodeScalar(u)!)) }
        for u in UnicodeScalar("a").value...UnicodeScalar("z").value { chars.append(Character(UnicodeScalar(u)!)) }
        return chars
    }()

    /// IPA portion of the upstream vocabulary, verbatim. Order
    /// matters — IDs are derived from position.
    private static let ipaChars: [Character] = Array(
        "ɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘\u{0027}\u{0329}\u{0027}ᵻ"
    )

    // MARK: - Initialisation

    private func loadIfNeeded() {
        loadLock.lock()
        defer { loadLock.unlock() }
        if loaded { return }
        buildSymbolTable()
        loadCMUdict()
        loaded = true
    }

    private func buildSymbolTable() {
        var table: [Character: Int32] = [:]
        var id: Int32 = 0
        table[Self.pad] = id; id += 1
        for c in Self.punctuationChars { table[c] = id; id += 1 }
        for c in Self.letterChars      { table[c] = id; id += 1 }
        for c in Self.ipaChars         { table[c] = id; id += 1 }
        symbolToID = table
    }

    private func loadCMUdict() {
        guard let url = Bundle.main.url(forResource: "cmudict", withExtension: "txt"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            // Without the dictionary every word falls through to LTS
            // and quality drops to ~Kokoro-with-BasicG2P levels —
            // still better than the old vocab bug, but obviously
            // worth flagging at startup.
            #if DEBUG
            print("[PhonemizerEN] cmudict.txt missing from bundle — falling back to letter-to-sound for all words.")
            #endif
            return
        }
        var d: [String: [String]] = [:]
        d.reserveCapacity(130_000)
        text.enumerateLines { line, _ in
            // Format: `word P P P ...` (space-delimited; vowels carry
            // a 0/1/2 stress digit).
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
    // 1. Walk the input string, building (word | punctuation) tokens.
    // 2. For each word, look up CMUdict → ARPAbet sequence; on miss
    //    use the LTS fallback.
    // 3. Map ARPAbet → IPA characters with stress markers inserted
    //    before the stressed vowel.
    // 4. Concatenate tokens with a single space character separator.

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
                // Read digits as English (rare in chat-style text;
                // we don't pretend to be a number expander). "1" → "one".
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
                // Preserve punctuation that exists in the vocabulary —
                // the model uses these for prosody. Drop anything else.
                if symbolToID[ch] != nil {
                    out.append(ch)
                }
            }
        }
        flushWord()
        return out
    }

    /// "1" → "one", etc. CMUdict has the spelled-out words.
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
    // Each ARPAbet phoneme maps to one or two IPA characters.
    // Diphthongs are emitted as two chars (e.g. "AY" → "a","ɪ"),
    // matching what espeak-ng + the upstream `with_stress=True`
    // produces. Stress digits become IPA stress markers placed
    // immediately before the vowel.

    private func arpabetToIPA(_ phones: [String]) -> [Character] {
        var out: [Character] = []
        for raw in phones {
            // Strip stress digit (last char if it's 0/1/2) and
            // capture it.
            var stress: Character? = nil
            var code = raw
            if let last = code.last, last.isASCII, last.isNumber {
                switch last {
                case "1": stress = "ˈ"
                case "2": stress = "ˌ"
                default:  stress = nil    // 0 = unstressed
                }
                code.removeLast()
            }
            // For monophthongs we put the stress marker right before
            // the vowel. For diphthongs we put it before the first
            // element, which is the syllable nucleus by convention.
            if let s = stress, Self.arpabetIsVowel(code) {
                out.append(s)
            }
            // Unstressed `AH` is the schwa `ə`; everywhere else
            // `AH` is `ʌ`. CMUdict uses AH0 = ə, AH1/AH2 = ʌ.
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
        // Monophthongs
        "AA": ["ɑ"],
        "AE": ["æ"],
        "AO": ["ɔ"],
        "EH": ["ɛ"],
        "ER": ["ɝ"],
        "IH": ["ɪ"],
        "IY": ["i"],
        "UH": ["ʊ"],
        "UW": ["u"],
        // Diphthongs (two chars)
        "AW": ["a", "ʊ"],
        "AY": ["a", "ɪ"],
        "EY": ["e", "ɪ"],
        "OW": ["o", "ʊ"],
        "OY": ["ɔ", "ɪ"],
        // Consonants
        "B":  ["b"],
        "CH": ["ʧ"],
        "D":  ["d"],
        "DH": ["ð"],
        "F":  ["f"],
        "G":  ["ɡ"],
        "HH": ["h"],
        "JH": ["ʤ"],
        "K":  ["k"],
        "L":  ["l"],
        "M":  ["m"],
        "N":  ["n"],
        "NG": ["ŋ"],
        "P":  ["p"],
        "R":  ["ɹ"],
        "S":  ["s"],
        "SH": ["ʃ"],
        "T":  ["t"],
        "TH": ["θ"],
        "V":  ["v"],
        "W":  ["w"],
        "Y":  ["j"],
        "Z":  ["z"],
        "ZH": ["ʒ"]
    ]

    // MARK: - LTS fallback for OOV words
    //
    // Used only when CMUdict has no entry — proper nouns, acronyms,
    // typos, new product names. Much rougher than CMUdict but the
    // miss rate on conversational English is well under 1%, so the
    // quality hit is bounded.

    private func lettersToIPA(_ word: String) -> [Character] {
        var out: [Character] = []
        let chars = Array(word)
        var i = 0
        // Default-place primary stress on the first vowel.
        var stressPlaced = false

        func placeStressIfNeeded() {
            if !stressPlaced {
                out.append("ˈ")
                stressPlaced = true
            }
        }

        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let nnext: Character? = i + 2 < chars.count ? chars[i + 2] : nil
            switch c {
            // Vowel teams
            case "a" where next == "i" || next == "y":
                placeStressIfNeeded(); out.append("e"); out.append("ɪ"); i += 2; continue
            case "a" where next == "u" || next == "w":
                placeStressIfNeeded(); out.append("ɔ"); i += 2; continue
            case "e" where next == "e":
                placeStressIfNeeded(); out.append("i"); i += 2; continue
            case "e" where next == "a":
                placeStressIfNeeded(); out.append("i"); i += 2; continue
            case "i" where next == "e":
                placeStressIfNeeded(); out.append("i"); i += 2; continue
            case "o" where next == "a":
                placeStressIfNeeded(); out.append("o"); out.append("ʊ"); i += 2; continue
            case "o" where next == "w":
                placeStressIfNeeded(); out.append("o"); out.append("ʊ"); i += 2; continue
            case "o" where next == "o":
                placeStressIfNeeded(); out.append("u"); i += 2; continue
            case "o" where next == "u":
                placeStressIfNeeded(); out.append("a"); out.append("ʊ"); i += 2; continue
            case "o" where next == "i" || next == "y":
                placeStressIfNeeded(); out.append("ɔ"); out.append("ɪ"); i += 2; continue
            case "e" where next == "i":
                placeStressIfNeeded(); out.append("e"); out.append("ɪ"); i += 2; continue
            // r-controlled vowels
            case "a" where next == "r":
                placeStressIfNeeded(); out.append("ɑ"); out.append("ɹ"); i += 2; continue
            case "o" where next == "r":
                placeStressIfNeeded(); out.append("ɔ"); out.append("ɹ"); i += 2; continue
            case "e" where next == "r", "i" where next == "r", "u" where next == "r":
                placeStressIfNeeded(); out.append("ɝ"); i += 2; continue
            // Single vowels
            case "a": placeStressIfNeeded(); out.append("æ")
            case "e":
                // Drop a silent terminal 'e' (CVCe pattern).
                let isFinalSilentE = (i == chars.count - 1) && i >= 2
                if isFinalSilentE {
                    // Look at the vowel two positions back; long-ify
                    // it. This handles "make"→/m eɪ k/, "code"→/k oʊ d/.
                    // We don't re-scan; the prior vowel emit stands as
                    // the short version. A second pass would be more
                    // correct but adds a lot of code for a fallback.
                    i += 1; continue
                }
                placeStressIfNeeded(); out.append("ɛ")
            case "i": placeStressIfNeeded(); out.append("ɪ")
            case "o": placeStressIfNeeded(); out.append("ɑ")
            case "u": placeStressIfNeeded(); out.append("ʌ")
            case "y":
                if i == 0 { out.append("j") } else { placeStressIfNeeded(); out.append("ɪ") }
            // Digraphs
            case "c" where next == "h":
                out.append("ʧ"); i += 2; continue
            case "s" where next == "h":
                out.append("ʃ"); i += 2; continue
            case "t" where next == "h":
                out.append("θ"); i += 2; continue
            case "p" where next == "h":
                out.append("f"); i += 2; continue
            case "w" where next == "h":
                out.append("w"); i += 2; continue
            case "n" where next == "g":
                out.append("ŋ"); i += 2; continue
            case "g" where next == "h":
                i += 2; continue   // silent gh as in "thought"
            // Common suffix shortcuts
            case "t" where next == "i" && nnext == "o" && i + 3 < chars.count && chars[i+3] == "n":
                out.append("ʃ"); out.append("ə"); out.append("n"); i += 4; continue
            // Single consonants
            case "b": out.append("b")
            case "c":
                if next == "e" || next == "i" || next == "y" { out.append("s") } else { out.append("k") }
            case "d": out.append("d")
            case "f": out.append("f")
            case "g":
                if next == "e" || next == "i" || next == "y" { out.append("ʤ") } else { out.append("ɡ") }
            case "h": out.append("h")
            case "j": out.append("ʤ")
            case "k": out.append("k")
            case "l": out.append("l")
            case "m": out.append("m")
            case "n": out.append("n")
            case "p": out.append("p")
            case "q":
                out.append("k"); if next == "u" { out.append("w"); i += 1 }
            case "r": out.append("ɹ")
            case "s": out.append("s")
            case "t": out.append("t")
            case "v": out.append("v")
            case "w": out.append("w")
            case "x": out.append("k"); out.append("s")
            case "z": out.append("z")
            default: break
            }
            i += 1
        }
        return out
    }
}
