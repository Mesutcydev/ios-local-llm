import Foundation
import QuartzCore

// MARK: - VoiceDisplayLink
// Real CADisplayLink on the main RunLoop. Uses targetTimestamp — never
// assumes a fixed 60/120 Hz cadence.

@MainActor
final class VoiceDisplayLink: NSObject {
    private var link: CADisplayLink?
    private var handler: ((CADisplayLink) -> Void)?

    /// Preferred range; the system may deliver fewer frames under load.
    var preferredFPSRange: ClosedRange<Float> = 30...60

    func start(_ handler: @escaping (CADisplayLink) -> Void) {
        // Idempotent: streaming TTS re-registers metering every chunk. Tearing
        // down/recreating CADisplayLink each time caused frame gaps that made
        // the speaking orb look static between sentences.
        self.handler = handler
        if link != nil {
            if #available(iOS 15.0, *) {
                link?.preferredFrameRateRange = CAFrameRateRange(
                    minimum: preferredFPSRange.lowerBound,
                    maximum: preferredFPSRange.upperBound,
                    preferred: preferredFPSRange.upperBound
                )
            }
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: preferredFPSRange.lowerBound,
                maximum: preferredFPSRange.upperBound,
                preferred: preferredFPSRange.upperBound
            )
        }
        link.add(to: .main, forMode: .common)
        self.link = link
        #if DEBUG
        VoiceDiagnosticsCenter.shared.noteDisplayLink(active: true)
        #endif
    }

    func stop() {
        let wasRunning = link != nil
        link?.invalidate()
        link = nil
        handler = nil
        #if DEBUG
        if wasRunning {
            VoiceDiagnosticsCenter.shared.noteDisplayLink(active: false)
        }
        #endif
    }

    @objc private func tick(_ link: CADisplayLink) {
        handler?(link)
    }

    deinit {
        // invalidate is safe from deinit; link may outlive MainActor briefly
        link?.invalidate()
    }
}
