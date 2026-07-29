import Foundation
import Darwin

// MARK: - CrashReporter
//
// Catches what MetricKit can't give you in-session and surfaces it on the very
// next launch:
//   • NSException        — uncaught Obj-C/Swift exceptions.
//   • POSIX signals      — SIGABRT (the MLX/Metal C++ abort!), SIGSEGV, SIGILL,
//                          SIGTRAP, SIGBUS, SIGFPE. Handler writes a native
//                          backtrace to a pre-opened fd (async-signal-safe
//                          path), then re-raises so the OS / MetricKit still
//                          records the crash.
//   • Unclean exit       — a "running" marker created at launch and removed on
//                          clean shutdown. If it's still there next launch, we
//                          were killed without a catchable signal — almost
//                          always a jetsam (out-of-memory) or watchdog kill,
//                          which is exactly the image-generation failure mode.
//
// The breadcrumb trail (Diagnostics' rolling disk log) is written continuously
// BEFORE any crash, so on the next launch we can show "what led up to it".

final class CrashReporter: @unchecked Sendable {

    static let shared = CrashReporter()

    struct CrashInfo {
        let kind: String          // "signal" | "exception" | "unclean-exit"
        let detail: String
        let trail: [String]       // tail of the breadcrumb log from last session
    }

    /// Populated by `install()` if the previous session ended badly.
    private(set) var lastCrash: CrashInfo?

    private var markerURL: URL { Diagnostics.directory.appendingPathComponent("running.marker") }
    private var signalURL: URL { Diagnostics.directory.appendingPathComponent("last_signal.crash") }
    private var exceptionURL: URL { Diagnostics.directory.appendingPathComponent("last_exception.crash") }

    private init() {}

    // MARK: - Install

    /// Call once, as early as possible at launch (before heavy work).
    func install() {
        detectPreviousCrash()
        installExceptionHandler()
        installSignalHandlers()
        writeRunningMarker()
        if let c = lastCrash {
            Diagnostics.shared.fault("Recovered from previous \(c.kind): \(c.detail)", category: "crash")
        }
    }

    /// Remove the marker so the next launch knows we exited cleanly. Call when
    /// the app leaves the foreground (background/inactive) — a kill there isn't
    /// a crash we want to flag.
    func markCleanShutdown() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// (Re)create the running marker when the app becomes active. If the
    /// process is then killed while active (e.g. jetsam during generation),
    /// the marker survives and we flag it next launch.
    func markRunning() {
        writeRunningMarker()
    }

    // MARK: - Previous-crash detection

    private func detectPreviousCrash() {
        let fm = FileManager.default

        // 1. A caught signal from last session?
        if let text = try? String(contentsOf: signalURL, encoding: .utf8), !text.isEmpty {
            lastCrash = CrashInfo(kind: "signal", detail: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  trail: trailTail())
            try? fm.removeItem(at: signalURL)
            return
        }
        // 2. A caught exception?
        if let text = try? String(contentsOf: exceptionURL, encoding: .utf8), !text.isEmpty {
            lastCrash = CrashInfo(kind: "exception", detail: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  trail: trailTail())
            try? fm.removeItem(at: exceptionURL)
            return
        }
        // 3. No signal/exception but the marker is still here → killed without a
        //    catchable signal. Overwhelmingly a jetsam (OOM) or watchdog kill.
        if fm.fileExists(atPath: markerURL.path) {
            lastCrash = CrashInfo(
                kind: "unclean-exit",
                detail: "Terminated without a catchable signal — most likely an out-of-memory (jetsam) or watchdog kill.",
                trail: trailTail()
            )
        }
    }

    /// Last ~40 lines of the rolling diagnostics log = the breadcrumb trail.
    private func trailTail(_ maxLines: Int = 40) -> [String] {
        guard let text = try? String(contentsOf: Diagnostics.logFileURL, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(maxLines).map(String.init))
    }

    private func writeRunningMarker() {
        let stamp = Diagnostics.timestampFormatter.string(from: Date())
        try? "launched \(stamp)".data(using: .utf8)?.write(to: markerURL, options: .atomic)
    }

    // MARK: - Exception handler

    private func installExceptionHandler() {
        // The handler is a C function pointer and can't capture context, so the
        // destination path lives in a file-scope global set here.
        codelensExceptionPath = exceptionURL.path
        NSSetUncaughtExceptionHandler { exception in
            guard !codelensExceptionPath.isEmpty else { return }
            var text = "NSException: \(exception.name.rawValue)\n"
            text += "reason: \(exception.reason ?? "nil")\n"
            text += "stack:\n" + exception.callStackSymbols.joined(separator: "\n")
            try? text.data(using: .utf8)?.write(to: URL(fileURLWithPath: codelensExceptionPath), options: .atomic)
        }
    }

    // MARK: - Signal handlers

    private func installSignalHandlers() {
        // Pre-open the crash fd and pre-allocate the backtrace buffer so the
        // handler itself does no allocation (kept on the async-signal-safe path).
        CrashSignalState.shared.prepare(path: signalURL.path)

        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGILL, SIGTRAP, SIGBUS, SIGFPE]
        for sig in signals {
            signal(sig, codelens_signal_handler)
        }
    }
}

/// File-scope path for the uncaught-exception handler (a C function pointer
/// that cannot capture `self`).
private var codelensExceptionPath: String = ""

// MARK: - Async-signal-safe handler state

/// Holds the pre-opened fd + pre-allocated backtrace buffer the C handler uses.
/// Set up before any crash so the handler allocates nothing.
private final class CrashSignalState: @unchecked Sendable {
    static let shared = CrashSignalState()
    var fd: Int32 = -1
    let frameCapacity = 128
    let frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>

    private init() {
        frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
    }

    func prepare(path: String) {
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    }
}

/// Top-level C handler — no captured context, only async-signal-safe calls
/// (write / backtrace / backtrace_symbols_fd), then restore default & re-raise
/// so the OS and MetricKit still see the crash.
private func codelens_signal_handler(_ sig: Int32) {
    let state = CrashSignalState.shared
    let fd = state.fd
    if fd >= 0 {
        func emit(_ s: StaticString) {
            s.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
        }
        emit("CODELENS_SIGNAL ")
        switch sig {
        case SIGABRT: emit("SIGABRT (abort — often the MLX/Metal C++ command-buffer error)")
        case SIGSEGV: emit("SIGSEGV (bad memory access)")
        case SIGILL:  emit("SIGILL (illegal instruction)")
        case SIGTRAP: emit("SIGTRAP (trap / fatalError)")
        case SIGBUS:  emit("SIGBUS (bus error)")
        case SIGFPE:  emit("SIGFPE (arithmetic error)")
        default:      emit("OTHER")
        }
        emit("\nbacktrace:\n")
        let count = backtrace(state.frames, Int32(state.frameCapacity))
        backtrace_symbols_fd(state.frames, count, fd)
        fsync(fd)
    }
    // Restore the default disposition and re-raise so the process still
    // terminates as a crash (and MetricKit captures the full report).
    signal(sig, SIG_DFL)
    raise(sig)
}
