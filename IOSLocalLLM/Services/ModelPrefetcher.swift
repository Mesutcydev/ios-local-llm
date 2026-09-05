import Foundation
import Network

// MARK: - ModelPrefetcher
// Background-warms models the user is likely to need next. Heuristic-driven:
//   • If the user opens the camera tab more than 3 times in a session and
//     doesn't have FastVLM downloaded, prefetch it after a 20s idle delay.
//   • If the user is on voice mode but the active assistant model has high
//     TTFT (>1500ms from last benchmark), warm-start a smaller model swap.
//
// Speculative work only runs when the device is in good shape: thermal
// state nominal, not in Low Power Mode, battery charged or charging, and
// the network path is not expensive/constrained (cellular, hotspot,
// data-saver) — multi-GB weights are never speculatively pulled over
// cellular regardless of the Wi-Fi-only download setting.

@MainActor
final class ModelPrefetcher: ObservableObject {

    static let shared = ModelPrefetcher()

    @Published private(set) var lastPrefetchedRepoID: String?

    private var cameraOpensThisSession: Int = 0
    private var debounce: Task<Void, Never>?

    /// Watches the network path so the prefetch guard can tell whether the
    /// link is expensive (cellular/hotspot) or constrained (data saver).
    private let pathMonitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "com.mesutcydev.ondevicecore.prefetch-path-monitor"))
        return monitor
    }()

    private init() {}

    // MARK: - Triggers

    /// Call from CameraRootView.onAppear.
    func recordCameraOpen() {
        cameraOpensThisSession += 1
        if cameraOpensThisSession >= 3 {
            scheduleFastVLMPrefetch()
        }
    }

    /// Call when the assistant tab is opened — opportunity to prefetch a
    /// secondary model the user might switch to.
    func recordAssistantOpen() {
        // Currently a no-op stub; reserved for future heuristics.
    }

    // MARK: - FastVLM

    private func scheduleFastVLMPrefetch() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)   // 20s idle
            guard let self, !Task.isCancelled else { return }
            self.prefetchFastVLMIfSafe()
        }
    }

    private func prefetchFastVLMIfSafe() {
        // Polite guards — this is speculative work, so any sign the device
        // or network is under strain means we simply skip it.
        let safety = DeviceSafetyMonitor.shared
        guard safety.effectiveThermalState == .nominal else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        // batteryLevel is -1 when unknown (simulator) — must not block there.
        guard safety.isCharging || safety.batteryLevel > 0.3 || safety.batteryLevel < 0 else { return }
        let path = pathMonitor.currentPath
        guard !path.isExpensive, !path.isConstrained else { return }
        guard let fastvlm = ModelDownloadCenter.shared.fastvlmModel else { return }
        switch fastvlm.state {
        case .ready, .downloading, .enumerating: return   // already done or in progress
        default: break
        }
        ToastCenter.shared.info(
            "Pre-fetching FastVLM in the background",
            detail: "We noticed you use the camera — getting weights ready so capture is instant."
        )
        fastvlm.start()
        lastPrefetchedRepoID = fastvlm.id
    }
}
