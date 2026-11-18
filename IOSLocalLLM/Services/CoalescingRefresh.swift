import Foundation

/// Serializes expensive refreshes and keeps only the latest pending request.
/// Collectors run off the main actor; publication stays on the main actor.
@MainActor
final class CoalescingRefresh<Input: Sendable, Output: Sendable> {
    private let collect: @Sendable (Input) async -> Output
    private let publish: @MainActor (Output) -> Void
    private var pending: Input?
    private var task: Task<Void, Never>?

    init(
        collect: @escaping @Sendable (Input) async -> Output,
        publish: @escaping @MainActor (Output) -> Void
    ) {
        self.collect = collect
        self.publish = publish
    }

    func request(_ input: Input) {
        pending = input
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while let input = self.pending {
                self.pending = nil
                let output = await Task.detached(priority: .utility) { [collect = self.collect] in
                    await collect(input)
                }.value
                // A newer request supersedes this snapshot. Finish the current
                // scan, then publish the latest one instead of stale totals.
                if self.pending == nil { self.publish(output) }
            }
            self.task = nil
        }
    }
}
