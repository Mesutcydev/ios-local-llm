import Foundation

// MARK: - RuntimeEngine

protocol RuntimeEngine: Sendable {
    var id: String { get }
    var runtime: ModelRuntime { get }

    func load(model: LocalModel) async throws
    func unload() async
    func generate(
        messages: [ChatMessage],
        options: GenerationOptions
    ) -> AsyncThrowingStream<TokenEvent, Error>
    func cancel() async
}

// MARK: - InferenceSessionActor

actor InferenceSessionActor {
    struct Cancelled: Error {}

    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var generation: UInt64 = 0

    func run<T>(_ body: () async throws -> T) async throws -> T {
        let ticket = try await acquire()
        defer { release() }
        if ticket != generation { throw Cancelled() }
        if Task.isCancelled { throw Cancelled() }
        return try await body()
    }

    func cancelAll() {
        generation &+= 1
        let queued = waiters
        waiters.removeAll()
        for waiter in queued {
            waiter.resume(throwing: Cancelled())
        }
    }

    private func acquire() async throws -> UInt64 {
        while isRunning {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
        }
        isRunning = true
        return generation
    }

    private func release() {
        isRunning = false
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        next.resume()
    }
}
