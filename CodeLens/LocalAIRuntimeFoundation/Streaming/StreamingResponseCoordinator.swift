import Foundation

// MARK: - UTF8StreamDecoder

public final class UTF8StreamDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8] = []

    public init() {}

    public func append(_ bytes: [UInt8]) -> String {
        lock.lock()
        pending.append(contentsOf: bytes)
        let (prefix, tail) = Self.splitCompletePrefix(pending)
        pending = tail
        lock.unlock()
        return prefix
    }

    public func finish() -> String {
        lock.lock()
        defer {
            pending.removeAll()
            lock.unlock()
        }
        guard !pending.isEmpty else { return "" }
        return String(decoding: pending, as: UTF8.self)
    }

    private static func splitCompletePrefix(_ bytes: [UInt8]) -> (String, [UInt8]) {
        guard !bytes.isEmpty else { return ("", []) }
        var cut = bytes.count
        var i = bytes.count - 1
        var continuations = 0
        while i >= 0, continuations < 3, bytes[i] & 0b1100_0000 == 0b1000_0000 {
            continuations += 1
            i -= 1
        }
        if i >= 0 {
            let lead = bytes[i]
            let expected: Int
            if lead & 0b1000_0000 == 0 { expected = 1 }
            else if lead & 0b1110_0000 == 0b1100_0000 { expected = 2 }
            else if lead & 0b1111_0000 == 0b1110_0000 { expected = 3 }
            else if lead & 0b1111_1000 == 0b1111_0000 { expected = 4 }
            else { expected = 1 }
            if continuations + 1 < expected {
                cut = i
            }
        }
        return (String(decoding: bytes[..<cut], as: UTF8.self), Array(bytes[cut...]))
    }
}

// MARK: - StreamingResponseCoordinator

public actor StreamingResponseCoordinator {
    private let flushIntervalNs: UInt64
    private let yield: @Sendable (TokenEvent) -> Void
    private var flushTask: Task<Void, Never>?
    private var bufferedText = ""
    private var hasSentFirstToken = false
    private var isFinished = false

    public init(
        uiBufferIntervalMs: Int = LocalAIFoundationConfig.default.uiBufferIntervalMs,
        yield: @escaping @Sendable (TokenEvent) -> Void
    ) {
        self.flushIntervalNs = UInt64(max(1, uiBufferIntervalMs)) * 1_000_000
        self.yield = yield
    }

    public func start() {
        guard !isFinished else { return }
        yield(.started)
    }

    public func appendToken(_ token: String) {
        guard !isFinished, !token.isEmpty else { return }
        if !hasSentFirstToken {
            hasSentFirstToken = true
            yield(.token(token))
        }
        bufferedText += token
        scheduleFlushIfNeeded()
    }

    public func appendBytes(_ bytes: [UInt8], decoder: UTF8StreamDecoder) {
        let token = decoder.append(bytes)
        appendToken(token)
    }

    public func flush() {
        guard !bufferedText.isEmpty else { return }
        let text = bufferedText
        bufferedText = ""
        yield(.partialText(text))
    }

    public func finish(
        tokensPerSecond: Double? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        guard !isFinished else { return }
        isFinished = true
        flushTask?.cancel()
        flushTask = nil
        flush()
        if let tokensPerSecond {
            yield(.usage(
                tokensPerSecond: tokensPerSecond,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            ))
        }
        yield(.completed)
    }

    public func cancel() {
        isFinished = true
        flushTask?.cancel()
        flushTask = nil
        bufferedText.removeAll()
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self, flushIntervalNs] in
            try? await Task.sleep(nanoseconds: flushIntervalNs)
            await self?.fireScheduledFlush()
        }
    }

    private func fireScheduledFlush() {
        flushTask = nil
        guard !isFinished else { return }
        flush()
        if !bufferedText.isEmpty {
            scheduleFlushIfNeeded()
        }
    }
}
