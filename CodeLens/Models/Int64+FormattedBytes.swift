import Foundation

// MARK: - Int64.formattedBytes
//
// Tiny formatter used app-wide for "234 MB" / "1.2 GB"-style labels.
// Lived in the legacy ModelDownloadManager.swift until that file was
// retired; lifted into its own utility so the rest of the codebase keeps
// compiling. Locale-aware via ByteCountFormatter so users in cs_CZ see
// "1,2 GB" etc.

extension Int64 {
    /// Human-readable byte count: `1_234_567 → "1.2 MB"`. Returns `"0 B"`
    /// for negative values rather than the system formatter's spelled-out
    /// "Zero bytes" placeholder.
    var formattedBytes: String {
        if self <= 0 { return "0 B" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle  = .file
        return f.string(fromByteCount: self)
    }
}
