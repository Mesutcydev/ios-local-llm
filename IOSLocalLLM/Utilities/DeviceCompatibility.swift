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

// MARK: - DeviceCopy

/// Keys for interface copy that names the device the app runs on. The Mac
/// Catalyst build runs this same iPhone/iPad UI, so "on this iPhone" has to
/// become "on this Mac" there. The Mac strings are separate catalog keys
/// rather than a substituted noun: translations inflect the article and the
/// verb around the device, so "ce Mac" cannot be derived from "cet iPhone".
enum DeviceCopy {
    /// Mid-sentence, e.g. "8.3 GB on this iPhone".
    static var onThisDevice: String {
        #if targetEnvironment(macCatalyst)
        return "on this Mac"
        #else
        return "on this iPhone"
        #endif
    }

    /// Sentence-case section header.
    static var onThisDeviceTitle: String {
        #if targetEnvironment(macCatalyst)
        return "On this Mac"
        #else
        return "On this iPhone"
        #endif
    }

    /// Hero subtitle under the assistant title.
    static var repliesStayOnDevice: String {
        #if targetEnvironment(macCatalyst)
        return "replies stay on your Mac"
        #else
        return "replies stay on your iPhone"
        #endif
    }

    /// Voice picker summary above the engine list.
    static var downloadedVoicesRunOffline: String {
        #if targetEnvironment(macCatalyst)
        return "Choose the voice that reads replies aloud. Downloaded voices run offline on this Mac."
        #else
        return "Choose the voice that reads replies aloud. Downloaded voices run offline on this iPhone."
        #endif
    }

    /// Fit badge on a model row that this device can run.
    static var runsOnDevice: String {
        #if targetEnvironment(macCatalyst)
        return "runs on this Mac"
        #else
        return "runs on this iPhone"
        #endif
    }

    /// Fit badge on a model row this device cannot run.
    static var wontRunOnDevice: String {
        #if targetEnvironment(macCatalyst)
        return "won't run on this Mac"
        #else
        return "won't run on this iPhone"
        #endif
    }

    /// Image-model screen note about SDXL's memory needs.
    static var sdxlMemoryNote: String {
        #if targetEnvironment(macCatalyst)
        return "SDXL needs a high-memory Mac. Live headroom is checked before loading a model."
        #else
        return "SDXL needs the highest-memory iPhones. Live headroom is checked before loading a model."
        #endif
    }

    /// Core AI import error when the bundle targets another platform build.
    static var coreAIUnsupportedBuild: String {
        #if targetEnvironment(macCatalyst)
        return "This Core AI model is not supported by this Mac build."
        #else
        return "This Core AI model is not supported by this iPhone build."
        #endif
    }
}
