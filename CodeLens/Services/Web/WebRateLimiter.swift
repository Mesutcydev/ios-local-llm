import Foundation

// MARK: - WebRateLimiter
// Per-host minimum spacing + per-user-request global cap. Stateful actor
// so concurrent fetches across the orchestrator coordinate naturally.

public actor WebRateLimiter {

    private var lastHitByHost: [String: Date] = [:]
    private let minIntervalPerHost: TimeInterval
    /// How many fetches the orchestrator is allowed per single user request.
    /// Reset via `resetRequestBudget(...)`.
    private var budgetForCurrentRequest: Int
    private let defaultBudget: Int

    public init(minIntervalPerHost: TimeInterval = 1.5, defaultBudget: Int = 6) {
        self.minIntervalPerHost = minIntervalPerHost
        self.defaultBudget = defaultBudget
        self.budgetForCurrentRequest = defaultBudget
    }

    public func resetRequestBudget(_ budget: Int? = nil) {
        budgetForCurrentRequest = budget ?? defaultBudget
    }

    /// Waits until both per-host spacing and global budget allow the request.
    /// Returns false if the global budget is exhausted.
    public func consumeBudgetAndWait(forHost host: String) async -> Bool {
        if budgetForCurrentRequest <= 0 { return false }
        budgetForCurrentRequest -= 1

        if let last = lastHitByHost[host] {
            let elapsed = Date().timeIntervalSince(last)
            let wait = minIntervalPerHost - elapsed
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastHitByHost[host] = Date()
        return true
    }

    public func remainingBudget() -> Int { budgetForCurrentRequest }
}
