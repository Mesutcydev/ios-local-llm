import AVFoundation
import Foundation

// MARK: - AcousticSpeechAlignmentProvider
// Offline on-device alignment: RMS envelope → silence regions → punctuation
// boundaries → word allocation inside speech regions.

struct AcousticSpeechAlignmentProvider: SpeechAlignmentProvider, Sendable {

    static let shared = AcousticSpeechAlignmentProvider()

    private let estimator = EstimatedSpeechTimingProvider.shared

    func align(
        text: String,
        audio: AVAudioPCMBuffer,
        synthesisMetadata: SynthesisMetadata?,
        timelineOffset: TimeInterval = 0,
        utf16BaseOffset: Int = 0
    ) async -> SpeechAlignmentResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Double(audio.frameLength) / max(1, audio.format.sampleRate)
        guard !trimmed.isEmpty, duration > 0.05, audio.frameLength > 0 else {
            return SpeechAlignmentResult(segments: [], accuracy: .phraseLevel, diagnosticDetail: "empty")
        }

        // Prefer engine-derived pred_dur when metadata is present.
        if let meta = synthesisMetadata,
           let frames = meta.predictedDurationsFrames,
           let ids = meta.phonemeIDs,
           let valid = meta.validTokenCount,
           let engine = PredDurWordAligner.align(
            text: trimmed,
            phonemeIDs: ids,
            predDurFrames: frames,
            validTokenCount: valid,
            audioDuration: duration,
            timelineOffset: timelineOffset,
            utf16BaseOffset: utf16BaseOffset
           ),
           !engine.segments.isEmpty {
            return engine
        }

        // Copy samples so heavy work can leave the caller's actor.
        let envelope = await Task.detached(priority: .utility) {
            Self.rmsEnvelope(audio, windowMs: 20)
        }.value
        let regions = Self.speechRegions(envelope: envelope, duration: duration)
        let words = PredDurWordAligner.extractSourceWords(from: trimmed)

        if words.isEmpty {
            return phraseFallback(text: trimmed, duration: duration, timelineOffset: timelineOffset, utf16BaseOffset: utf16BaseOffset)
        }

        // Need enough speech regions that roughly match clause structure.
        let clauses = Self.splitClauses(trimmed)
        let confidence = Self.confidence(
            regions: regions,
            words: words.count,
            duration: duration,
            clauses: clauses.count
        )

        if confidence < 0.35 || regions.isEmpty {
            // Fall back to duration-weighted estimation, then phrase if that fails.
            if let estimated = try? await estimator.timings(
                for: trimmed,
                audioDuration: duration,
                engineCapabilities: [.completePCMBuffers],
                timelineOffset: timelineOffset,
                utf16BaseOffset: utf16BaseOffset
            ), let seg = estimated.first, !seg.words.isEmpty {
                let rewritten = SpeechSegment(
                    id: seg.id,
                    text: seg.text,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    words: seg.words,
                    timingSource: .estimated
                )
                return SpeechAlignmentResult(
                    segments: [rewritten],
                    accuracy: .estimated,
                    diagnosticDetail: "acoustic confidence \(String(format: "%.2f", confidence))"
                )
            }
            return phraseFallback(text: trimmed, duration: duration, timelineOffset: timelineOffset, utf16BaseOffset: utf16BaseOffset)
        }

        // Allocate words across speech regions proportional to character weight.
        let timings = Self.allocateWords(
            words: words,
            regions: regions,
            duration: duration,
            timelineOffset: timelineOffset,
            utf16BaseOffset: utf16BaseOffset
        )

        guard PredDurWordAligner.validate(
            timings: timings,
            audioDuration: duration,
            timelineOffset: timelineOffset
        ) else {
            return phraseFallback(text: trimmed, duration: duration, timelineOffset: timelineOffset, utf16BaseOffset: utf16BaseOffset)
        }

        // Merge very short words into phrase groups is done at highlight time;
        // store word-level here.
        let segment = SpeechSegment(
            text: trimmed,
            startTime: timelineOffset,
            endTime: timelineOffset + duration,
            words: timings,
            timingSource: .acousticallyAligned
        )
        return SpeechAlignmentResult(
            segments: [segment],
            accuracy: .acousticallyAligned,
            diagnosticDetail: "RMS silence regions=\(regions.count)"
        )
    }

    // MARK: - Envelope / silence

    struct TimeRegion: Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        var duration: TimeInterval { end - start }
    }

    static func rmsEnvelope(_ buffer: AVAudioPCMBuffer, windowMs: Double) -> [Float] {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        let rate = buffer.format.sampleRate
        let window = max(1, Int(rate * windowMs / 1000))
        let count = Int(buffer.frameLength)
        var out: [Float] = []
        out.reserveCapacity(count / window + 1)
        var i = 0
        while i < count {
            let end = min(i + window, count)
            var sum: Float = 0
            var j = i
            while j < end {
                let s = data[j]
                sum += s * s
                j += 1
            }
            let n = Float(end - i)
            out.append(sqrt(sum / max(n, 1)))
            i = end
        }
        // Smooth
        guard out.count > 2 else { return out }
        var smooth = out
        for idx in 1..<out.count - 1 {
            smooth[idx] = out[idx - 1] * 0.25 + out[idx] * 0.5 + out[idx + 1] * 0.25
        }
        return smooth
    }

    static func speechRegions(envelope: [Float], duration: TimeInterval) -> [TimeRegion] {
        guard !envelope.isEmpty, duration > 0 else { return [] }
        let peak = envelope.max() ?? 0
        let threshold = max(0.02, peak * 0.18)
        let step = duration / Double(envelope.count)

        var regions: [TimeRegion] = []
        var start: TimeInterval?
        for (i, v) in envelope.enumerated() {
            let t = Double(i) * step
            if v >= threshold {
                if start == nil { start = t }
            } else if let s = start {
                let end = max(s + 0.05, t)
                if end - s >= 0.08 {
                    regions.append(TimeRegion(start: s, end: end))
                }
                start = nil
            }
        }
        if let s = start {
            regions.append(TimeRegion(start: s, end: duration))
        }

        // Merge tiny gaps (<120ms) — likely intra-word dips.
        guard !regions.isEmpty else { return [TimeRegion(start: 0, end: duration)] }
        var merged: [TimeRegion] = [regions[0]]
        for r in regions.dropFirst() {
            if let last = merged.last, r.start - last.end < 0.12 {
                merged[merged.count - 1] = TimeRegion(start: last.start, end: r.end)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    static func splitClauses(_ text: String) -> [String] {
        var clauses: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?。！？;:".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { clauses.append(t) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { clauses.append(tail) }
        return clauses.isEmpty ? [text] : clauses
    }

    static func confidence(
        regions: [TimeRegion],
        words: Int,
        duration: TimeInterval,
        clauses: Int
    ) -> Double {
        guard duration > 0, words > 0 else { return 0 }
        let covered = regions.reduce(0.0) { $0 + $1.duration } / duration
        let regionWordRatio: Double = {
            if regions.isEmpty { return 0 }
            let ideal = Double(max(clauses, 1))
            let delta = abs(Double(regions.count) - ideal) / max(ideal, 1)
            return max(0, 1 - delta)
        }()
        return min(1, covered * 0.65 + regionWordRatio * 0.35)
    }

    static func allocateWords(
        words: [PredDurWordAligner.SourceWord],
        regions: [TimeRegion],
        duration: TimeInterval,
        timelineOffset: TimeInterval,
        utf16BaseOffset: Int
    ) -> [SpeechWordTiming] {
        // Distribute words across regions by cumulative character weight.
        let weights = words.map { max(Double($0.text.count), 1.5) }
        let totalWeight = weights.reduce(0, +)
        let regionSpeech = regions.reduce(0.0) { $0 + $1.duration }
        guard totalWeight > 0, regionSpeech > 0 else { return [] }

        var timings: [SpeechWordTiming] = []
        var wordIndex = 0
        var weightCursor = 0.0

        for region in regions {
            let regionWeightShare = region.duration / regionSpeech
            let regionWeightBudget = totalWeight * regionWeightShare
            var used = 0.0
            var localCursor = timelineOffset + region.start

            while wordIndex < words.count && used < regionWeightBudget - 0.01 {
                let w = weights[wordIndex]
                // Last region absorbs remaining words.
                let isLastRegion = region.end >= duration - 0.02
                if !isLastRegion && used + w > regionWeightBudget * 1.25 && used > 0 {
                    break
                }
                let share = region.duration * (w / max(regionWeightBudget, w))
                let speak = max(0.06, min(share, region.end + timelineOffset - localCursor))
                let end = min(timelineOffset + region.end, localCursor + speak)
                let src = words[wordIndex]
                timings.append(
                    SpeechWordTiming(
                        word: src.text,
                        startTime: localCursor,
                        endTime: max(localCursor + 0.05, end),
                        utf16Range: NSRange(
                            location: utf16BaseOffset + src.utf16Range.location,
                            length: src.utf16Range.length
                        )
                    )
                )
                localCursor = end
                used += w
                wordIndex += 1
                weightCursor += w
            }
        }

        // Leftover words → pack into final tail.
        if wordIndex < words.count {
            let start = timings.last?.endTime ?? timelineOffset
            let remain = max(0.05, timelineOffset + duration - start)
            let leftover = words[wordIndex...]
            let lw = leftover.map { max(Double($0.text.count), 1.5) }
            let sum = lw.reduce(0, +)
            var c = start
            for (src, w) in zip(leftover, lw) {
                let span = remain * (w / max(sum, 1))
                timings.append(
                    SpeechWordTiming(
                        word: src.text,
                        startTime: c,
                        endTime: c + max(0.05, span),
                        utf16Range: NSRange(
                            location: utf16BaseOffset + src.utf16Range.location,
                            length: src.utf16Range.length
                        )
                    )
                )
                c += max(0.05, span)
            }
        }

        // Final drift correction.
        if let last = timings.last {
            let target = timelineOffset + duration
            let span = max(last.endTime - timelineOffset, 0.001)
            let scale = (target - timelineOffset) / span
            if abs(scale - 1) > 0.001 {
                return timings.map { w in
                    SpeechWordTiming(
                        id: w.id,
                        word: w.word,
                        startTime: timelineOffset + (w.startTime - timelineOffset) * scale,
                        endTime: timelineOffset + (w.endTime - timelineOffset) * scale,
                        utf16Range: w.utf16Range
                    )
                }
            }
        }
        return timings
    }

    private func phraseFallback(
        text: String,
        duration: TimeInterval,
        timelineOffset: TimeInterval,
        utf16BaseOffset: Int
    ) -> SpeechAlignmentResult {
        let range = NSRange(location: utf16BaseOffset, length: (text as NSString).length)
        let word = SpeechWordTiming(
            word: text,
            startTime: timelineOffset,
            endTime: timelineOffset + duration,
            utf16Range: range
        )
        let seg = SpeechSegment(
            text: text,
            startTime: timelineOffset,
            endTime: timelineOffset + duration,
            words: [word],
            timingSource: .phraseLevel
        )
        return SpeechAlignmentResult(
            segments: [seg],
            accuracy: .phraseLevel,
            diagnosticDetail: "phrase fallback"
        )
    }
}
