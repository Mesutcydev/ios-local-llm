import Darwin
import Foundation
import UIKit

// MARK: - DeviceCompatibility
//
// Hardware gate for IOSLocalLLM. The app ships a 470 MB Core ML vision
// encoder + ~520 MB bundled GGUF VLM + downloadable 1.5–4 GB MLX
// assistants. To keep the user experience tolerable on real hardware
// (no Jetsam kills, no minutes-long loads, no thermal throttling that
// renders the model useless after one capture) we gate install on
// physical RAM ≥ 8 GB.
//
// That single rule cleanly maps to:
//   iPhone 15 Pro       — A17 Pro · 8 GB
//   iPhone 15 Pro Max   — A17 Pro · 8 GB
//   iPhone 16, 16 Plus  — A18     · 8 GB
//   iPhone 16 Pro, Max  — A18 Pro · 8 GB
//   iPhone 16e / Air    — A18     · 8 GB
//   iPhone 17 series    — A19/Pro · 8–12 GB
//   iPad Pro (M1+)      — 8–16 GB
//   iPad Air (M1+)      — 8 GB
//   iPad mini 7         — A17 Pro · 8 GB
//
// Naturally excludes:
//   • iPhone 15, 15 Plus, 14/Plus, 13/Pro/Mini, 12, 11, SE 2/3   (≤6 GB)
//   • iPad Pro 11"/12.9" pre-M1, iPad Air pre-M1, base iPad     (≤6 GB)
//
// `physicalMemory` is in bytes; we check against 7.5 GB so devices
// reported as "8 GB" but with kernel overhead under 7.95 GB still
// pass (real reads on 8 GB devices typically come back ~7.9 GB).

enum DeviceCompatibility {

    /// True when this device meets the RAM floor and isn't an
    /// architecture we explicitly reject. Simulator always passes so
    /// the design loop stays fast on a Mac.
    static func isSupported() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let bytes = ProcessInfo.processInfo.physicalMemory
        let floor: UInt64 = 7_500_000_000        // ≈ 7.5 GB
        return bytes >= floor
        #endif
    }

    /// Reads the hardware model identifier (e.g. `iPhone17,3`). Kept
    /// for diagnostics — `isSupported()` no longer relies on a
    /// whitelist of identifiers, but the UI surfaces this in the
    /// unsupported-device screen so users know exactly what device
    /// they're holding.
    static func machineIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Reported physical RAM in gigabytes, rounded down. Diagnostic
    /// use — same surfacing as `machineIdentifier`.
    static func physicalMemoryGB() -> Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return Int(bytes / 1_073_741_824)
    }

    /// True when the current device is an iPad. Used by the
    /// unsupported-device view to tailor the recommendation
    /// ("iPad with M-series or A17 Pro chip" vs. "iPhone 15 Pro+").
    static func isiPad() -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
}
