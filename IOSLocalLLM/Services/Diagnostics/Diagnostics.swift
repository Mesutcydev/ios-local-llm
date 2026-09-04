import Foundation
import os

// MARK: - Diagnostics
//
// App-wide structured logging + breadcrumb trail. One funnel for everything we
// want to see when something goes wrong:
//   • os.Logger      — shows up in Console.app / `log stream`, free in Xcode.
//   • in-memory ring — the last N entries, surfaced live in DiagnosticsView.
//   • rolling file   — survives a crash so CrashReporter can attach the trail
//                      that led up to a SIGABRT / jetsam.
//
// Deliberately not @MainActor and lock-guarded so it's safe to call from any
// thread (MLX inference runs off-main, and crash paths are thread-agnostic).

enum DiagLevel: Int, Codable, Comparable, CaseIterable {
    case debug, info, notice, warning, error, fault

    static func < (a: DiagLevel, b: DiagLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        }
    }

    var osType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .default
        case .error: return .error
        case .fault: return .fault
        }
    }
}

struct DiagEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    let timestamp: Date
    let level: DiagLevel
    let category: String
    let message: String

    var line: String {
        "\(Diagnostics.timestampFormatter.string(from: timestamp)) [\(level.label)] (\(category)) \(message)"
    }
}

final class Diagnostics: @unchecked Sendable {

    static let shared = Diagnostics()

    private let subsystem = "com.mesutcydev.ioslocalllm.IOSLocalLLM"
    private let lock = NSLock()
    private var ring: [DiagEntry] = []
    private let ringCap = 600

    /// Minimum level actually recorded (debug entries are noisy; default
    /// drops them unless explicitly raised).
    var minimumLevel: DiagLevel = .info

    private var loggers: [String: Logger] = [:]
    private let diskQueue = DispatchQueue(label: "com.mesutcydev.ioslocalllm.diagnostics.disk", qos: .utility)
    private let maxFileBytes = 512 * 1024

    static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Paths

    /// Directory holding the diagnostics log + crash artifacts.
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var logFileURL: URL { directory.appendingPathComponent("diagnostics.log") }

    private init() {}

    // MARK: - Logging

    func log(_ message: String, level: DiagLevel = .info, category: String = "app") {
        guard level >= minimumLevel else { return }
        let entry = DiagEntry(timestamp: Date(), level: level, category: category, message: message)

        // os.Logger (Console / Xcode).
        logger(for: category).log(level: level.osType, "\(message, privacy: .public)")

        // In-memory ring.
        lock.lock()
        ring.append(entry)
        if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }
        lock.unlock()

        // Rolling disk file (so the trail survives a crash).
        appendToDisk(entry.line)
    }

    func debug(_ m: String, category: String = "app")   { log(m, level: .debug, category: category) }
    func info(_ m: String, category: String = "app")    { log(m, level: .info, category: category) }
    func notice(_ m: String, category: String = "app")  { log(m, level: .notice, category: category) }
    func warning(_ m: String, category: String = "app") { log(m, level: .warning, category: category) }
    func error(_ m: String, category: String = "app")   { log(m, level: .error, category: category) }
    func fault(_ m: String, category: String = "app")   { log(m, level: .fault, category: category) }

    /// Short, high-signal event marker — the trail you read after a crash.
    func breadcrumb(_ m: String, category: String = "trail") {
        log(m, level: .notice, category: category)
    }

    private func logger(for category: String) -> Logger {
        lock.lock(); defer { lock.unlock() }
        if let l = loggers[category] { return l }
        let l = Logger(subsystem: subsystem, category: category)
        loggers[category] = l
        return l
    }

    // MARK: - Snapshot / export

    func recentEntries(minLevel: DiagLevel = .debug, category: String? = nil) -> [DiagEntry] {
        lock.lock(); defer { lock.unlock() }
        return ring.filter { $0.level >= minLevel && (category == nil || $0.category == category) }
    }

    func clear() {
        lock.lock(); ring.removeAll(); lock.unlock()
        diskQueue.async {
            try? FileManager.default.removeItem(at: Self.logFileURL)
        }
    }

    /// Full text bundle for the share sheet — environment header + trail.
    func exportText() -> String {
        var out = SystemSnapshot.header()
        out += """


        === RELEASE VALIDATION ===
        This export contains diagnostics, not a test certification.
        Load / generate / cancel / switch / unload: not recorded
        Memory-pressure recovery: not recorded
        Thermal escalation and cooldown: not recorded
        Background cleanup: not recorded
        VoiceOver and largest Dynamic Type: not recorded
        Record device, OS, app build, model, procedure, and result when testing.
        Simulator results do not validate physical-device thermals or Metal residency.
        """
        if let c = CrashReporter.shared.lastCrash {
            out += "\n\n=== LAST CRASH ===\n\(c.kind): \(c.detail)"
            if !c.trail.isEmpty {
                out += "\n\n=== PREVIOUS SESSION TRAIL (\(c.trail.count) entries) ===\n"
                out += c.trail.joined(separator: "\n") + "\n"
            }
        }
        let entries = recentEntries()
        out += "\n\n=== RECENT LOG (\(entries.count) entries) ===\n"
        for e in entries { out += e.line + "\n" }
        return out
    }

    /// Compact context for on-device AI analysis: system snapshot + last crash
    /// + the most recent warnings/errors (capped to fit the model's context
    /// window). Shared by DiagnosticsView's "Analyze with on-device AI" and the
    /// chat "Diagnose app errors" action so both stay in sync.
    func analysisContext() -> String {
        var out = SystemSnapshot.header()
        if let c = CrashReporter.shared.lastCrash {
            out += "\n\n=== LAST CRASH ===\n\(c.kind): \(c.detail)"
            if !c.trail.isEmpty {
                out += "\nBreadcrumbs:\n" + c.trail.suffix(20).joined(separator: "\n")
            }
        }
        let errs = recentEntries(minLevel: .warning).suffix(40)
        out += "\n\n=== RECENT WARNINGS / ERRORS (\(errs.count)) ===\n"
        out += errs.isEmpty ? "(none)" : errs.map(\.line).joined(separator: "\n")
        return out
    }

    // MARK: - Disk

    private func appendToDisk(_ line: String) {
        diskQueue.async {
            let url = Self.logFileURL
            let fm = FileManager.default
            // Rotate when the file grows past the cap.
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > self.maxFileBytes {
                try? fm.removeItem(at: url.deletingPathExtension().appendingPathExtension("1.log"))
                try? fm.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("1.log"))
            }
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            }
        }
    }
}
