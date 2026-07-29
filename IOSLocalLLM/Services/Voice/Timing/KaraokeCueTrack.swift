import Foundation

// MARK: - KaraokeCueTrack
// Sample-indexed cues. Lookup is O(log n). No per-word Task.sleep.

struct KaraokeCue: Sendable, Equatable {
    let id: Int
    let phraseID: UUID
    let textRange: NSRange
    let startSample: Int64
    let endSample: Int64
    let confidence: Float
    let timingSource: SpeechAlignmentAccuracy
}

struct KaraokeCueTrack: Sendable, Equatable {
    let cues: [KaraokeCue]
    let sampleRate: Double

    static let empty = KaraokeCueTrack(cues: [], sampleRate: 24_000)

    func cueIndex(at sample: Int64) -> Int? {
        guard !cues.isEmpty else { return nil }
        if sample < cues[0].startSample { return 0 }
        var lo = 0
        var hi = cues.count - 1
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            let c = cues[mid]
            if sample < c.startSample {
                hi = mid - 1
            } else if sample >= c.endSample {
                best = mid
                lo = mid + 1
            } else {
                return mid
            }
        }
        return min(best, cues.count - 1)
    }

    func cue(at sample: Int64) -> KaraokeCue? {
        guard let idx = cueIndex(at: sample) else { return nil }
        return cues[idx]
    }

    func spokenUTF16End(at sample: Int64, transcriptLength: Int) -> Int {
        guard let idx = cueIndex(at: sample) else { return 0 }
        let cue = cues[idx]
        let start = cue.textRange.location
        let end = start + cue.textRange.length
        if sample >= cue.endSample {
            return min(transcriptLength, end)
        }
        if sample <= cue.startSample {
            return min(transcriptLength, start)
        }
        // Interpolate within the active phrase so karaoke advances smoothly
        // even when the player clock only delivers phrase-level cues.
        let span = max(1, cue.endSample - cue.startSample)
        let t = Double(sample - cue.startSample) / Double(span)
        let spoken = start + Int((Double(cue.textRange.length) * min(max(t, 0), 1)).rounded(.down))
        return min(transcriptLength, max(start, spoken))
    }

    /// Build from phrase timeline + utterance sample rate.
    static func from(
        phrases: [KaraokePhrase],
        sampleRate: Double,
        timingSource: SpeechAlignmentAccuracy
    ) -> KaraokeCueTrack {
        let sr = max(1, sampleRate)
        let cues: [KaraokeCue] = phrases.enumerated().map { index, phrase in
            KaraokeCue(
                id: index,
                phraseID: phrase.id,
                textRange: phrase.utf16Range,
                startSample: Int64((phrase.startTime * sr).rounded()),
                endSample: Int64((max(phrase.endTime, phrase.startTime) * sr).rounded()),
                confidence: timingSource == .estimated || timingSource == .phraseLevel ? 0.5 : 0.9,
                timingSource: timingSource
            )
        }
        return KaraokeCueTrack(cues: cues, sampleRate: sr)
    }
}
