import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SystemSnapshot
//
// A point-in-time picture of the environment — app/OS/device + the live
// memory and thermal state that actually decide whether on-device inference
// survives. Used as the header of an exported diagnostics bundle and shown
// live in DiagnosticsView.

enum SystemSnapshot {

    static func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    static func deviceModelIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        let id = mirror.children.compactMap { ($0.value as? Int8).flatMap { $0 == 0 ? nil : Character(UnicodeScalar(UInt8($0))) } }
        return String(id)
    }

    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func lowPowerMode() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Live memory figures (bytes). Reuses MemoryAdvisor so the numbers match
    /// the safety gate that refuses oversized model loads.
    static func memory() -> (available: Int64, total: Int64, usedFootprint: Int64) {
        (MemoryAdvisor.processAvailableMemory,
         MemoryAdvisor.deviceTotalRAM,
         MemoryAdvisor.deviceTotalRAM - MemoryAdvisor.nonResidentRAMEstimate)
    }

    /// Multi-line header for an exported diagnostics bundle.
    static func header() -> String {
        let mem = memory()
        var lines: [String] = []
        lines.append("=== CodeLens diagnostics ===")
        lines.append("exported: \(Diagnostics.timestampFormatter.string(from: Date()))")
        lines.append("app: \(appVersion())")
        lines.append("device: \(deviceModelIdentifier()) · iOS \(osVersion())")
        lines.append("memory: \(mem.available.formattedBytes) avail of \(mem.total.formattedBytes) total")
        lines.append("thermal: \(thermalState()) · low-power: \(lowPowerMode())")
        return lines.joined(separator: "\n")
    }
}
