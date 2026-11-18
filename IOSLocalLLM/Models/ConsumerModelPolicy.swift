import Foundation

/// Applies equally to normal use and review builds. Never bypass model terms
/// by changing mirrors: conversions retain the upstream weights' license.
enum ConsumerModelPolicy {
    static func allows(repoID: String) -> Bool {
        !["fastvlm", "fastvithd"].contains { repoID.localizedCaseInsensitiveContains($0) }
    }
}
