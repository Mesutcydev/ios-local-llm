import Foundation
import Combine

// MARK: - Render quality

public enum VoiceOrbRenderQuality: String, Sendable, CaseIterable, Comparable {
    case reduced
    case balanced
    case full

    private var rank: Int {
        switch self {
        case .reduced: return 0
        case .balanced: return 1
        case .full: return 2
        }
    }

    public static func < (lhs: VoiceOrbRenderQuality, rhs: VoiceOrbRenderQuality) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Minimum frame interval for the animation clock.
    /// Cap at 60 Hz even for `.full` — ProMotion 120 Hz dual-Canvas is a
    /// hitch factory on iPhone Pro (industry voice UIs stay ≤30–60 FPS).
    public var minimumFrameInterval: Double? {
        switch self {
        case .full: return 1.0 / 60.0
        case .balanced: return 1.0 / 30.0
        case .reduced: return 1.0 / 20.0
        }
    }

    /// Maximum fine particles inside the orb.
    public var particleCount: Int {
        switch self {
        case .full: return 18
        case .balanced: return 8
        case .reduced: return 0
        }
    }

    /// Number of internal energy fields drawn.
    public var energyLayerCount: Int {
        switch self {
        case .full: return 2
        case .balanced: return 1
        case .reduced: return 1
        }
    }

    /// Whether the Metal distortion effect may be applied.
    public var allowsDistortion: Bool { self == .full }

    /// Multiplier on the atmospheric glow radius/alpha.
    public var glowMultiplier: Double {
        switch self {
        case .full: return 1.0
        case .balanced: return 0.75
        case .reduced: return 0.5
        }
    }

    /// Whether soft-blur passes may be used inside the canvas.
    public var allowsSoftBlur: Bool { self != .reduced }
}

// MARK: - Quality controller (pure, hysteresis-tested)

/// Decides the render quality from environmental inputs with hysteresis:
/// downgrades apply quickly, upgrades require sustained good conditions so
/// small thermal fluctuations never flap the tier back and forth.
public struct VoiceOrbQualityController: Sendable, Equatable {

    public struct Inputs: Sendable, Equatable {
        public var lowPowerMode: Bool
        public var thermalState: ProcessInfo.ThermalState
        public var reduceMotion: Bool
        public var sceneActive: Bool

        public init(
            lowPowerMode: Bool = false,
            thermalState: ProcessInfo.ThermalState = .nominal,
            reduceMotion: Bool = false,
            sceneActive: Bool = true
        ) {
            self.lowPowerMode = lowPowerMode
            self.thermalState = thermalState
            self.reduceMotion = reduceMotion
            self.sceneActive = sceneActive
        }
    }

    public private(set) var quality: VoiceOrbRenderQuality = .balanced

    /// How long conditions must stay favorable before upgrading.
    public var upgradeHoldDuration: TimeInterval = 12
    /// Minimum time between two consecutive downgrades (unless critical).
    public var downgradeCooldown: TimeInterval = 2

    private var favorableSince: TimeInterval?
    private var lastDowngradeAt: TimeInterval = -.infinity

    public init() {}

    /// The quality the environment alone would want, without hysteresis.
    public func desiredQuality(for inputs: Inputs) -> VoiceOrbRenderQuality {
        if !inputs.sceneActive || inputs.lowPowerMode || inputs.reduceMotion {
            return .reduced
        }
        switch inputs.thermalState {
        case .critical: return .reduced
        case .serious: return .reduced
        case .fair: return .balanced
        case .nominal: return .balanced
        @unknown default: return .balanced
        }
    }

    /// Re-evaluates with hysteresis. Returns the (possibly unchanged) quality.
    @discardableResult
    public mutating func evaluate(_ inputs: Inputs, now: TimeInterval) -> VoiceOrbRenderQuality {
        let desired = desiredQuality(for: inputs)

        if desired < quality {
            // Downgrade: immediate for critical constraints, throttled otherwise.
            let severe = inputs.thermalState == .critical || inputs.lowPowerMode || !inputs.sceneActive
            if severe || now - lastDowngradeAt >= downgradeCooldown {
                quality = desired
                lastDowngradeAt = now
            }
            favorableSince = nil
        } else if desired > quality {
            // Upgrade only after sustained favorable conditions.
            let since = favorableSince ?? now
            favorableSince = since
            if now - since >= upgradeHoldDuration {
                quality = desired
                favorableSince = nil
            }
        } else {
            favorableSince = nil
        }
        return quality
    }
}

// MARK: - Observable policy

/// Bridges environment signals (thermal, low power, reduce motion, scene
/// phase) into the render quality the orb should use right now.
@MainActor
public final class VoiceOrbPerformancePolicy: ObservableObject {

    @Published public private(set) var quality: VoiceOrbRenderQuality = .balanced

    /// Set from the view's `accessibilityReduceMotion` environment value.
    public var reduceMotion: Bool = false {
        didSet { if reduceMotion != oldValue { refresh() } }
    }

    /// Set from the view's `scenePhase`.
    public var sceneIsActive: Bool = true {
        didSet { if sceneIsActive != oldValue { refresh() } }
    }

    /// Exposed for tests via `@testable`.
    var controller = VoiceOrbQualityController()

    /// Injectable clock for tests.
    var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private var cancellables: Set<AnyCancellable> = []

    public init() {
        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .NSProcessInfoPowerStateDidChange)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &cancellables)

        refresh()
    }

    public func refresh() {
        let inputs = VoiceOrbQualityController.Inputs(
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState,
            reduceMotion: reduceMotion,
            sceneActive: sceneIsActive
        )
        let resolved = controller.evaluate(inputs, now: now())
        if resolved != quality {
            quality = resolved
        }
    }
}
