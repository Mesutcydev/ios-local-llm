import Darwin
import Foundation

/// Audio-callback RMS/peak. Preallocated floats behind a tiny unfair lock —
/// never allocates, never hops to MainActor.
final class AudioMeterAtomics: @unchecked Sendable {
    static let shared = AudioMeterAtomics()

    private var rms: Float = 0
    private var peak: Float = 0
    private var unfair = os_unfair_lock_s()

    func write(rms newRMS: Float, peak newPeak: Float) {
        os_unfair_lock_lock(&unfair)
        rms = newRMS
        peak = newPeak
        os_unfair_lock_unlock(&unfair)
    }

    func read() -> (rms: Float, peak: Float) {
        os_unfair_lock_lock(&unfair)
        let r = rms
        let p = peak
        os_unfair_lock_unlock(&unfair)
        return (r, p)
    }

    func reset() {
        write(rms: 0, peak: 0)
    }
}
