import AVFoundation
import CoreImage
import UIKit
import Combine
import os         // OSAllocatedUnfairLock

// MARK: - Frame output delegate

protocol CameraServiceDelegate: AnyObject {
    func cameraService(_ service: CameraService, didOutput pixelBuffer: CVPixelBuffer, frameIndex: Int)
}

// MARK: - CameraService

final class CameraService: NSObject, ObservableObject {
    // Published state for UI
    @Published var isRunning = false
    @Published var error: CameraError?

    // Published camera control state
    @Published private(set) var zoomFactor: CGFloat = 1.0
    @Published private(set) var minZoom: CGFloat = 1.0
    @Published private(set) var maxZoom: CGFloat = 5.0
    @Published private(set) var torchOn: Bool = false
    @Published private(set) var torchAvailable: Bool = false
    @Published private(set) var focusIndicator: CGPoint? = nil   // normalized 0–1 device coords

    weak var delegate: CameraServiceDelegate?

    // Session + I/O
    let captureSession = AVCaptureSession()
    private var videoOutput = AVCaptureVideoDataOutput()
    private var videoDevice: AVCaptureDevice?

    // Frame management
    private let processingQueue = DispatchQueue(label: "com.codelens.camera", qos: .userInteractive)
    private var frameIndex: Int = 0
    // Was a plain Bool. Promoted to a lock so the read-then-flip inside
    // captureOutput is one atomic critical section — the serial-queue
    // contract today makes the race window theoretical, but tying
    // correctness to that contract is fragile and the lock costs ~25 ns.
    // Drop-when-busy semantics are unchanged; only the gate plumbing is.
    private let isProcessingFrame = OSAllocatedUnfairLock<Bool>(initialState: false)

    // Lifecycle observers — torn down in deinit
    private var bgObserver: NSObjectProtocol?
    private var fgObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    /// True if we suspended on background and need to resume on foreground.
    private var resumeOnForeground = false

    // MARK: - Init / Deinit

    override init() {
        super.init()
        installLifecycleObservers()
    }

    // MARK: - Lifecycle passthrough (driven by LifecycleController)

    /// Called on `.inactive` and `.background`. Pauses frame submission
    /// but keeps the capture session alive. Idempotent.
    func deactivateForLifecycle() {
        resumeOnForeground = captureSession.isRunning
        if captureSession.isRunning {
            stop()
        }
    }

    /// Called on `.active`. Restarts the camera only if it was running
    /// before deactivation. Idempotent.
    func reactivateForLifecycle() {
        guard resumeOnForeground else { return }
        resumeOnForeground = false
        if !captureSession.isRunning {
            start()
        }
    }

    deinit {
        if let o = bgObserver { NotificationCenter.default.removeObserver(o) }
        if let o = fgObserver { NotificationCenter.default.removeObserver(o) }
        if let o = thermalObserver { NotificationCenter.default.removeObserver(o) }
        if captureSession.isRunning { captureSession.stopRunning() }
    }

    /// Auto-suspend the capture session when the app backgrounds so we don't
    /// pin the camera + drain battery while the user is elsewhere. Resume
    /// when they come back.
    private func installLifecycleObservers() {
        bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.resumeOnForeground = true
                self.stop()
            }
        }
        fgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.resumeOnForeground else { return }
            self.resumeOnForeground = false
            self.start()
        }
        // Thermal degradation: halve the frame-rate cap while the device
        // is hot, restore when it cools. Raw ProcessInfo state is fine
        // here — the camera cap is cheap to flip and needs no hysteresis.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyThermalFrameRate()
        }
    }

    // MARK: - Setup

    func configure() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized ||
              AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            error = .permissionDenied
            return
        }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if granted {
                DispatchQueue.main.async { self.setupSession() }
            } else {
                DispatchQueue.main.async { self.error = .permissionDenied }
            }
        }
    }

    private func setupSession() {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Use the best back camera on iPhone 17 Pro Max
        videoDevice = bestBackCamera()
        guard let device = videoDevice,
              let input = try? AVCaptureDeviceInput(device: device) else {
            error = .deviceUnavailable
            return
        }

        // 1080p, not 4K. The only consumer of these buffers is a VLM
        // sampling only on user-triggered captures plus short follow-up bursts
        // (the model downsamples to well
        // below 1080p anyway) — running the sensor + ISP at 4K was pure
        // thermal/battery cost with zero caption-quality benefit.
        captureSession.sessionPreset = .hd1920x1080

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        // Lock to portrait. The Lens is a still-capture/analysis surface, not a
        // video recorder, so the preview is capped below 30 fps to reduce ISP
        // work and heat while keeping framing responsive.
        if let connection = videoOutput.connection(with: .video) {
            connection.videoRotationAngle = 90
            if connection.isVideoStabilizationSupported {
                // ANY stabilisation mode crops the sensor for headroom; on
                // this hardware that crop renders as a visible centred
                // translucent band against the full-bleed preview. With
                // `cinematicExtended` it was severe, with `.standard` it was
                // a faint ghost. `.off` is what finally clears it — and the
                // app doesn't need stabilisation: the only consumer of the
                // pixel buffers is a still-frame VLM, not a video recorder.
                connection.preferredVideoStabilizationMode = .off
            }
        }

        configureFrameRate(for: device, targetFPS: 24)

        // Surface camera capabilities for UI
        let minAvailable = Swift.max(1.0, device.minAvailableVideoZoomFactor)
        let maxAvailable = Swift.min(10.0, device.maxAvailableVideoZoomFactor)
        DispatchQueue.main.async { [weak self] in
            self?.minZoom = minAvailable
            self?.maxZoom = maxAvailable
            self?.zoomFactor = device.videoZoomFactor
            self?.torchAvailable = device.hasTorch && device.isTorchAvailable
        }
    }

    private func bestBackCamera() -> AVCaptureDevice? {
        // Prefer ProRes-capable camera for highest quality
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        if let back = discovery.devices.first { return back }

        #if targetEnvironment(macCatalyst)
        // Macs have no rear camera. Fall back to whatever video device is
        // present (built-in FaceTime camera, Continuity Camera, or an
        // external/USB webcam) so the Lens still works; if none exists the
        // caller surfaces `.deviceUnavailable` and the UI degrades.
        let anyVideo = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return anyVideo.devices.first ?? AVCaptureDevice.default(for: .video)
        #else
        return nil
        #endif
    }

    private func configureFrameRate(for device: AVCaptureDevice, targetFPS: Int) {
        guard let format = device.formats.last(where: {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dims.width >= 1920 &&
                   $0.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= Double(targetFPS) })
        }) else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            applyFrameDurations(device, format: format, targetFPS: targetFPS)
            device.unlockForConfiguration()
        } catch {
            print("[CameraService] lockForConfiguration failed: \(error)")
        }
    }

    /// Retunes ONLY the frame-duration caps on the already-selected active
    /// format — no `activeFormat` reassignment. The thermal governor uses
    /// this: reselecting and assigning `activeFormat` on every thermal
    /// transition tears down and rebuilds the format, glitching the preview
    /// and dropping frames. The format chosen at setup already spans the
    /// 12–24 fps range, so only the min/max duration needs to move.
    private func setFrameRateCapOnly(for device: AVCaptureDevice, targetFPS: Int) {
        do {
            try device.lockForConfiguration()
            applyFrameDurations(device, format: device.activeFormat, targetFPS: targetFPS)
            device.unlockForConfiguration()
        } catch {
            print("[CameraService] frame-rate retune failed: \(error)")
        }
    }

    /// Sets the min/max frame durations for a target fps cap. Caller holds the
    /// device configuration lock. Cap at `targetFPS` but DON'T pin: min frame
    /// duration is the SHORTEST frame time (highest fps) — setting it to
    /// 1/target caps the rate. Max frame duration is the LONGEST frame time
    /// (lowest fps) — leaving it at the format's supported maximum lets
    /// auto-exposure stretch frames in low light and lets the thermal governor
    /// drop the rate when hot. The previous min == max pin defeated both.
    private func applyFrameDurations(_ device: AVCaptureDevice,
                                     format: AVCaptureDevice.Format,
                                     targetFPS: Int) {
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        if let longest = format.videoSupportedFrameRateRanges
            .map(\.maxFrameDuration)
            .max(by: { CMTimeCompare($0, $1) < 0 }) {
            device.activeVideoMaxFrameDuration = longest
        } else {
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        }
    }

    /// Thermal degradation (L2): drop the frame-rate cap to 12 fps when
    /// the device is .serious/.critical, restore 24 fps at .nominal/.fair.
    /// Frame rate only — the session preset and active format are untouched.
    private func applyThermalFrameRate() {
        guard let device = videoDevice else { return }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            setFrameRateCapOnly(for: device, targetFPS: 12)
        default:
            setFrameRateCapOnly(for: device, targetFPS: 24)
        }
    }

    // MARK: - Start / Stop

    func start() {
        // Check `isRunning` INSIDE the serial queue, not on the caller. A rapid
        // background→foreground (stop() then start()) evaluated the guard
        // against the pre-dispatch state on the main thread: stop() could see
        // "not yet running" and bail while start()'s async startRunning was
        // still queued, leaving the camera in the wrong final state. Gating on
        // the serial queue makes the start/stop pair reconcile in dispatch
        // order against the session's true state.
        processingQueue.async { [weak self] in
            guard let self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
            DispatchQueue.main.async { self.isRunning = true }
        }
    }

    func stop() {
        processingQueue.async { [weak self] in
            guard let self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    // MARK: - Camera controls (zoom, focus, torch)

    /// Smoothly ramps the zoom factor. Clamped to [minZoom, maxZoom].
    func setZoom(_ factor: CGFloat, ramped: Bool = false) {
        guard let device = videoDevice else { return }
        let clamped = max(minZoom, min(maxZoom, factor))
        do {
            try device.lockForConfiguration()
            if ramped {
                device.ramp(toVideoZoomFactor: clamped, withRate: 2.0)
            } else {
                device.videoZoomFactor = clamped
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.zoomFactor = clamped
            }
        } catch {
            print("[CameraService] zoom failed: \(error)")
        }
    }

    /// Focuses + meters at a point in the preview's normalized 0–1 coordinate
    /// space (top-left origin). Updates `focusIndicator` for the overlay reticle.
    func focus(at previewPoint: CGPoint) {
        guard let device = videoDevice else { return }
        // AVCaptureDevice expects 0..1 in device coords (landscape).
        // The connection rotation is 90°, so SwiftUI (x, y) → device (y, 1-x).
        let devicePoint = CGPoint(x: previewPoint.y, y: 1.0 - previewPoint.x)
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
            }
            if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        } catch {
            print("[CameraService] focus failed: \(error)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.focusIndicator = previewPoint
        }
        // Hide the reticle after 1.2s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.focusIndicator == previewPoint {
                self?.focusIndicator = nil
            }
        }
    }

    /// Toggles or sets the torch state. No-op when torch is not available.
    func setTorch(on: Bool) {
        guard let device = videoDevice, device.hasTorch, device.isTorchAvailable else { return }
        do {
            try device.lockForConfiguration()
            if on {
                try device.setTorchModeOn(level: 1.0)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.torchOn = on
            }
        } catch {
            print("[CameraService] torch failed: \(error)")
        }
    }

    func toggleTorch() { setTorch(on: !torchOn) }

    // MARK: - Capture still for FastVLM

    /// Grabs the next frame from the live 1080p stream. No reconfiguration
    /// happens — 1080p comfortably exceeds what any of the VLM consumers
    /// can ingest, and a one-shot 4K preset flip would glitch the preview
    /// for no caption-quality gain.
    func captureHighResFrame() async -> CVPixelBuffer? {
        // The live output already delivers full-res (1080p) frames; just grab the next one.
        return await withCheckedContinuation { continuation in
            let originalDelegate = self.delegate

            let capture = OneShotCapture(continuation, original: originalDelegate)
            self.delegate = capture

            // Timeout fallback. Using Task.sleep instead of DispatchQueue side-
            // steps Sendable checks for captured non-Sendable references.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                // Atomic claim — races the capture delegate on processingQueue.
                if capture.claim() {
                    self?.delegate = originalDelegate
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Acquire-or-bail. Read-and-flip happen in one critical
        // section so the gate is race-free even if the queue contract
        // changes. If the gate is already taken, drop this frame —
        // matches the session's `alwaysDiscardsLateVideoFrames = true`
        // policy.
        let acquired: Bool = isProcessingFrame.withLock { busy in
            if busy { return false }
            busy = true
            return true
        }
        guard acquired else { return }
        // ORDERING: this defer must remain at the top of the function,
        // never nested inside an `if`. Releasing the gate before the
        // delegate call returns would let a re-entrant frame from the
        // serial queue enter captureOutput while the delegate is still
        // touching pixelBuffer. The early return below (no pixel buffer)
        // is also covered because defer fires on any function exit.
        defer { isProcessingFrame.withLock { $0 = false } }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        frameIndex += 1
        let currentFrame = frameIndex

        // Deliver the frame to the active delegate (AnalysisService for the
        // live preview/FPS + tap-to-capture, or OneShotCapture during a
        // high-res still grab).
        delegate?.cameraService(self, didOutput: pixelBuffer, frameIndex: currentFrame)
    }
}

// MARK: - OneShotCapture
//
// Lifted from inside captureHighResFrame() ONLY so the streaming
// hook in captureOutput can type-check `delegate is OneShotCapture`
// and suppress itself during a high-res still cycle. Body is
// byte-for-byte identical to the previous in-function declaration —
// same init, same `resumed` guard, same delegate restoration. Do
// not refactor; the delegate-swap dance in captureHighResFrame()
// depends on every line here.

fileprivate final class OneShotCapture: CameraServiceDelegate, @unchecked Sendable {
    let continuation: CheckedContinuation<CVPixelBuffer?, Never>
    var originalDelegate: CameraServiceDelegate?
    // `claim()` runs from BOTH the capture delegate (processingQueue) and the
    // 2 s timeout Task (MainActor). Without a lock both could read resumed ==
    // false and resume the SAME continuation twice → "resume continuation
    // twice" trap (crash). The lock makes the flip-and-claim atomic.
    private let lock = NSLock()
    private var resumedFlag = false

    init(_ cont: CheckedContinuation<CVPixelBuffer?, Never>, original: CameraServiceDelegate?) {
        continuation = cont
        originalDelegate = original
    }

    /// Atomically claims the sole right to resume; returns true at most once.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumedFlag { return false }
        resumedFlag = true
        return true
    }

    func cameraService(_ service: CameraService, didOutput pixelBuffer: CVPixelBuffer, frameIndex: Int) {
        guard claim() else { return }
        service.delegate = originalDelegate
        continuation.resume(returning: pixelBuffer)
    }
}

// MARK: - Errors

enum CameraError: LocalizedError {
    case permissionDenied
    case deviceUnavailable
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera access denied. Enable in Settings."
        case .deviceUnavailable: return "No camera available on this device."
        case .configurationFailed: return "Failed to configure camera session."
        }
    }
}
