import Foundation

// MARK: - RecoveryState
//
// Compact record written atomically at every clean shutdown and read back
// at next launch. When the previous session ended without marking itself
// clean, the next launch enters safe recovery mode: no automatic heavyweight
// model loads, a non-blocking explanation is shown, and the user must
// manually retry the large model.

struct RecoveryState: Codable, Sendable {
    /// True when the previous session did NOT complete a clean shutdown.
    var uncleanExit: Bool = false

    /// The runtime slot active at shutdown time (assistant / lens / voice).
    var lastActiveSlot: String?

    /// Repo ID of the model loaded when the app last went to background.
    var lastModelID: String?

    /// Last tracked operation (e.g. "generate", "load", "describe", "camera_stream").
    var lastOperation: String?

    /// ScenePhase when the app last suspended.
    var lastLifecyclePhase: String?

    /// Monotonic timestamp (mach_absolute_time-based) of the last persistence write.
    var lastCleanMark: TimeInterval = 0
}

// MARK: - Recovery manager

@MainActor
final class RecoveryManager: Sendable {
    static let shared = RecoveryManager()

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recovery.json")
    }()

    private(set) var state: RecoveryState = RecoveryState()

    private init() {
        state = Self.readAtomic(fileURL) ?? RecoveryState()
    }

    // MARK: - Read / write

    /// Called at launch. Returns nil when no file exists (first launch) or
    /// when the file is corrupt; in both cases we start with a clean RecoveryState.
    private static func readAtomic(_ url: URL) -> RecoveryState? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RecoveryState.self, from: data) else {
            return nil
        }
        return decoded
    }

    /// Writes the current state atomically. Called during background
    /// transition and after a clean foreground return.
    func flush() {
        let snapshot = state
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    // MARK: - Lifecycle hooks (called by LifecycleController)

    func markUncleanLaunchDetected() {
        state.uncleanExit = true
        flush()
    }

    func markRunning(slot: String, modelID: String?, operation: String?) {
        state.uncleanExit = true          // will be cleared on clean shutdown
        state.lastActiveSlot = slot
        state.lastModelID = modelID
        state.lastOperation = operation
        flush()
    }

    func markCleanShutdown(phase: String) {
        state.uncleanExit = false
        state.lastLifecyclePhase = phase
        state.lastCleanMark = ProcessInfo.processInfo.systemUptime
        flush()
    }

    /// True when the previous session ended uncleanly with a heavy model
    /// (≥ 8 GB estimated weights) active. Used to decide whether to enter
    /// safe recovery mode.
    var shouldEnterRecoveryMode: Bool {
        guard state.uncleanExit else { return false }
        guard state.lastModelID != nil else { return false }
        // Conservative: any model that was loaded during an unclean exit
        // is treated as potentially dangerous to auto-reload.
        return true
    }
}
