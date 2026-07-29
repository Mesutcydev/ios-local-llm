import MetalKit
import SwiftUI

// Native GPU port of thinking-orbs by Jakub Antalik (MIT).
// SwiftUI owns only lifecycle and semantic state. Metal owns the animation
// clock, particle geometry, audio response, and every rendered frame.

struct VoiceActivityOrb: View {
    let phase: VoiceSessionPhase
    let micLevel: Float
    let reduceMotion: Bool
    var renderingMode: VoiceRenderingMode = .automatic

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ThinkingOrbMetalSurface(
            configuration: ThinkingOrbConfiguration(
                mode: ThinkingOrbMode(phase: phase),
                dark: colorScheme == .dark,
                reduceMotion: reduceMotion,
                reducedQuality: renderingMode == .reduced,
                fallbackLevel: micLevel,
                active: scenePhase == .active
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("voiceOrb")
        .accessibilityLabel(phase.statusLabel)
        .accessibilityAddTraits(.isButton)
    }
}

struct VoiceStatusLabel: View {
    let phase: VoiceSessionPhase
    let detail: String?

    @Environment(\.koduTheme) private var theme

    var body: some View {
        VStack(spacing: 3) {
            KMono(
                text: phase.statusLabel.lowercased(),
                size: 12,
                weight: .semibold,
                color: theme.ink
            )
            if let detail {
                KMono(text: detail.lowercased(), size: 10, color: theme.ink3)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: phase.statusLabel)
    }
}

private enum ThinkingOrbMode: Int32, Sendable, Equatable {
    case working
    case searching
    case solving
    case listening
    case composing
    case shaping

    init(phase: VoiceSessionPhase) {
        switch phase {
        case .idle, .paused:
            self = .working
        case .listening, .speechDetected:
            self = .listening
        case .thinking:
            self = .solving
        case .preparingSpeech:
            self = .shaping
        case .speaking:
            self = .composing
        case .interrupted:
            self = .searching
        case .failed:
            self = .shaping
        }
    }
}

private struct ThinkingOrbConfiguration: Equatable, Sendable {
    let mode: ThinkingOrbMode
    let dark: Bool
    let reduceMotion: Bool
    let reducedQuality: Bool
    let fallbackLevel: Float
    let active: Bool
}

private struct ThinkingOrbMetalSurface: UIViewRepresentable {
    let configuration: ThinkingOrbConfiguration

    func makeUIView(context: Context) -> ThinkingOrbMTKView {
        ThinkingOrbMTKView(configuration: configuration)
    }

    func updateUIView(_ view: ThinkingOrbMTKView, context: Context) {
        view.apply(configuration)
    }

    static func dismantleUIView(_ view: ThinkingOrbMTKView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
private final class ThinkingOrbMTKView: MTKView {
    private var orbRenderer: ThinkingOrbMetalRenderer?
    private var lastConfiguration: ThinkingOrbConfiguration?

    init(configuration: ThinkingOrbConfiguration) {
        let metalDevice = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: metalDevice)

        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .invalid
        framebufferOnly = true
        presentsWithTransaction = false
        enableSetNeedsDisplay = false
        autoResizeDrawable = true

        if let metalDevice {
            do {
                let renderer = try ThinkingOrbMetalRenderer(
                    device: metalDevice,
                    pixelFormat: colorPixelFormat,
                    configuration: configuration
                )
                orbRenderer = renderer
                delegate = renderer
            } catch {
                assertionFailure("Thinking orb Metal setup failed: \(error)")
            }
        }

        apply(configuration)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ configuration: ThinkingOrbConfiguration) {
        guard configuration != lastConfiguration else { return }
        lastConfiguration = configuration
        orbRenderer?.update(configuration)

        // Before attachment, use the universal 60 Hz baseline. didMoveToWindow
        // reapplies this configuration with the actual window screen, including
        // 120 Hz ProMotion, without relying on deprecated UIScreen.main.
        let nativeFPS = max(60, window?.screen.maximumFramesPerSecond ?? 60)
        let targetFPS: Int
        if configuration.reduceMotion {
            targetFPS = 15
        } else if configuration.reducedQuality {
            targetFPS = 30
        } else {
            targetFPS = nativeFPS
        }
        preferredFramesPerSecond = targetFPS
        isPaused = !configuration.active
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let lastConfiguration else { return }
        // The final UIScreen is known only after attachment. Re-apply the
        // requested cadence so ProMotion devices use their native 120 Hz.
        self.lastConfiguration = nil
        apply(lastConfiguration)
    }

    func stop() {
        isPaused = true
        delegate = nil
        orbRenderer = nil
    }
}

private struct ThinkingOrbUniforms {
    // time, smoothed activity, current mode, previous mode
    var state = SIMD4<Float>(repeating: 0)
    // transition progress, dark flag, display scale, sample stride
    var presentation = SIMD4<Float>(repeating: 0)
    // drawable aspect ratio, motion scale, reserved, reserved
    var geometry = SIMD4<Float>(repeating: 0)
}

private final class ThinkingOrbMetalRenderer: NSObject, MTKViewDelegate {
    private struct RenderState {
        var configuration: ThinkingOrbConfiguration
        var previousMode: ThinkingOrbMode
        var transitionStarted: CFTimeInterval
        var lastFrameTime: CFTimeInterval
        var animationTime: Float = 0
        var smoothedActivity: Float = 0
    }

    private struct Snapshot {
        let uniforms: ThinkingOrbUniforms
        let vertexCount: Int
    }

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let lock = NSLock()
    private var renderState: RenderState

    init(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        configuration: ThinkingOrbConfiguration
    ) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw ThinkingOrbMetalError.commandQueueUnavailable
        }
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "thinkingOrbVertex"),
              let fragment = library.makeFunction(name: "thinkingOrbFragment") else {
            throw ThinkingOrbMetalError.shaderUnavailable
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Thinking Orb Pipeline"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.commandQueue = commandQueue
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let now = CACurrentMediaTime()
        renderState = RenderState(
            configuration: configuration,
            previousMode: configuration.mode,
            transitionStarted: now - 1,
            lastFrameTime: now
        )
        super.init()
    }

    func update(_ configuration: ThinkingOrbConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        if configuration.mode != renderState.configuration.mode {
            renderState.previousMode = renderState.configuration.mode
            renderState.transitionStarted = CACurrentMediaTime()
        }
        renderState.configuration = configuration
    }

    func draw(in view: MTKView) {
        let cpuStart = CACurrentMediaTime()
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let snapshot = makeSnapshot(view: view, now: cpuStart)
        var uniforms = snapshot.uniforms
        encoder.label = "Thinking Orb Particles"
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<ThinkingOrbUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(
            type: .point,
            vertexStart: 0,
            vertexCount: snapshot.vertexCount
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func makeSnapshot(view: MTKView, now: CFTimeInterval) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        let configuration = renderState.configuration
        let elapsed = min(max(now - renderState.lastFrameTime, 0), 1.0 / 15.0)
        renderState.lastFrameTime = now
        let motionScale: Float = configuration.reduceMotion ? 0.12 : 1
        renderState.animationTime += Float(elapsed) * motionScale

        let targetActivity: Float
        switch configuration.mode {
        case .listening:
            targetActivity = max(configuration.fallbackLevel, VoiceVisualLevelStore.shared.micLevel)
        case .composing:
            targetActivity = max(configuration.fallbackLevel, VoiceVisualLevelStore.shared.playbackLevel)
        case .working, .searching, .solving, .shaping:
            targetActivity = 0
        }
        let smoothing = Float(1 - exp(-elapsed * 18))
        renderState.smoothedActivity += (min(max(targetActivity, 0), 1) - renderState.smoothedActivity) * smoothing

        let transitionElapsed = now - renderState.transitionStarted
        let linearTransition = min(max(Float(transitionElapsed / 0.22), 0), 1)
        let transition = linearTransition * linearTransition * (3 - 2 * linearTransition)
        let scale = Float(max(view.contentScaleFactor, 1))
        let width = max(Float(view.drawableSize.width), 1)
        let height = max(Float(view.drawableSize.height), 1)
        let stride: Float = configuration.reducedQuality ? 2 : 1

        var uniforms = ThinkingOrbUniforms()
        uniforms.state = SIMD4(
            renderState.animationTime,
            renderState.smoothedActivity,
            Float(configuration.mode.rawValue),
            Float(renderState.previousMode.rawValue)
        )
        uniforms.presentation = SIMD4(
            transition,
            configuration.dark ? 1 : 0,
            scale,
            stride
        )
        uniforms.geometry = SIMD4(width / height, motionScale, 0, 0)
        return Snapshot(
            uniforms: uniforms,
            vertexCount: configuration.reducedQuality ? 256 : 512
        )
    }
}

private enum ThinkingOrbMetalError: Error {
    case commandQueueUnavailable
    case shaderUnavailable
}
