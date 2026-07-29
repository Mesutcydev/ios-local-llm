import Foundation

// MARK: - VoiceVisualLevelStore
// Lock-backed visual amplitude read directly by the Metal orb renderer
// without publishing ObservableObject changes every frame.

final class VoiceVisualLevelStore: @unchecked Sendable {
    static let shared = VoiceVisualLevelStore()

    private let lock = NSLock()
    private var _playbackLevel: Float = 0
    private var _micLevel: Float = 0
    private var _phaseRaw: Int = 0

    var playbackLevel: Float {
        get { locked { _playbackLevel } }
        set { locked { _playbackLevel = newValue } }
    }

    var micLevel: Float {
        get { locked { _micLevel } }
        set { locked { _micLevel = newValue } }
    }

    /// Packed VoiceSessionPhase discriminator for cheap cross-thread reads.
    /// 0 idle, 1 listening, 2 thinking, 3 preparing, 4 speaking, 5 paused,
    /// 6 interrupted, 7 failed, 8 speechDetected.
    var phaseCode: Int {
        get { locked { _phaseRaw } }
        set { locked { _phaseRaw = newValue } }
    }

    func reset() {
        locked {
            _playbackLevel = 0
            _micLevel = 0
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
