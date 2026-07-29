import Foundation
import Metal
import UIKit

// MARK: - SystemStatusService
// One-stop dashboard of device + runtime health.
// Used by Settings → System Status and the diagnostics surface.

@MainActor
final class SystemStatusService: ObservableObject {

    static let shared = SystemStatusService()

    // MARK: - Published snapshot

    @Published private(set) var snapshot: Snapshot = .empty

    struct Snapshot {
        // Memory
        var totalRAM: Int64 = 0
        var usedByApp: Int64 = 0
        var availableForML: Int64 = 0
        var freeRightNow: Int64 = 0

        // Disk
        var diskFree: Int64 = 0
        var modelStorageUsed: Int64 = 0

        // Compute
        var device: String = ""
        var os: String = ""
        var metalDeviceName: String = ""
        var metalSupportsRayTracing: Bool = false
        var supportsNeuralEngine: Bool = false

        // Model runtime
        var qwen3Ready: Bool = false
        var fastVLMReady: Bool = false
        var voiceEngineReady: Bool = false

        // Last generation perf
        var lastQwen3TPS: Double? = nil
        var lastFastVLMTPS: Double? = nil

        static let empty = Snapshot()
    }

    // MARK: - Private

    private var refreshTimer: Timer?
    private var subscriberCount = 0

    private init() {
        refresh()
        // Timer is started lazily by `startObserving()` and stopped when no
        // subscriber needs live updates. Avoids constant re-publishing that
        // re-renders Settings/HUD views and causes scroll lag.
    }

    /// Call when a view appears that wants live updates.
    func startObserving() {
        subscriberCount += 1
        guard refreshTimer == nil else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Call when the view disappears.
    func stopObserving() {
        subscriberCount = max(0, subscriberCount - 1)
        if subscriberCount == 0 {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Refresh

    func refresh() {
        var snap = Snapshot()

        // Memory
        snap.totalRAM       = Int64(ProcessInfo.processInfo.physicalMemory)
        // Use the same phys_footprint accounting and clamped process ceiling
        // as the model admission gate. The old values mixed three unrelated
        // quantities: 70% of physical RAM, RSS, and total RAM minus RSS. That
        // made Status claim 8.58–12.06 GB was free while the loader correctly
        // enforced the validated ~6.2 GB iPhone process budget.
        snap.availableForML = MemoryAdvisor.availableMemoryForModel
        snap.freeRightNow   = MemoryAdvisor.processAvailableMemory
        snap.usedByApp      = MemoryAdvisor.physFootprint

        // Disk
        snap.diskFree           = HFModelDownloadManager.freeDiskBytes() ?? 0
        snap.modelStorageUsed   = ModelDownloadCenter.shared.totalStorageUsed

        // Device
        snap.device = UIDevice.current.modelIdentifier
        snap.os     = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"

        // Metal
        if let metal = MTLCreateSystemDefaultDevice() {
            snap.metalDeviceName = metal.name
            snap.metalSupportsRayTracing = metal.supportsRaytracing
        } else {
            snap.metalDeviceName = "unavailable"
        }

        // Neural Engine — heuristic: all Apple A11+ and M-series chips have one.
        // We check the device model identifier.
        snap.supportsNeuralEngine = Self.hasNeuralEngine()

        // Runtime model state
        snap.qwen3Ready    = CodingAssistantService.shared.state == .ready
        snap.fastVLMReady  = FastVLMService.shared.componentStatus.canGenerate
        snap.voiceEngineReady = VoiceService.shared.systemState == .ready
                              || VoiceService.shared.kittenState == .ready
                              || VoiceService.shared.kokoroState == .ready

        // Perf (best-effort: pull last known)
        snap.lastFastVLMTPS = FastVLMService.shared.debugInfo?.lastTokensPerSecond
        snap.lastQwen3TPS = CodingAssistantService.shared.tokenRate > 0
            ? CodingAssistantService.shared.tokenRate
            : ModelUsageTracker.shared.lastTPS(for: "qwen3-4b")

        snapshot = snap
    }

    // MARK: - Helpers

    /// Resident set size of the current process (bytes).
    private static func currentRSS() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size /
                                            MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    private static func hasNeuralEngine() -> Bool {
        // A11 Bionic (iPhone X) and later have ANE. Conservative check.
        let id = UIDevice.current.modelIdentifier
        if id.hasPrefix("iPhone") {
            // iPhone10,3 / iPhone10,6 = X (A11+)
            // Everything from X onwards has ANE
            let parts = id.dropFirst("iPhone".count).split(separator: ",")
            if let major = parts.first.flatMap({ Int($0) }) { return major >= 10 }
        }
        if id.hasPrefix("iPad") {
            // iPad8,x = 11" Pro 2018, A12X (has ANE), everything later too
            let parts = id.dropFirst("iPad".count).split(separator: ",")
            if let major = parts.first.flatMap({ Int($0) }) { return major >= 8 }
        }
        // Simulator / unknown — assume true on modern Macs
        if id == "x86_64" || id.hasPrefix("arm64") { return true }
        return true
    }
}

// MARK: - UIDevice + model identifier

extension UIDevice {
    var modelIdentifier: String {
        var sys = utsname()
        uname(&sys)
        let identifier = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "" }
        }
        return identifier
    }
}
