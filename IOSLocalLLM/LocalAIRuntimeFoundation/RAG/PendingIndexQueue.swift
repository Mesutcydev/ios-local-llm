import Foundation

// MARK: - PendingIndexQueue

public struct PendingIndexPolicySnapshot: Equatable, Sendable {
    public var canProcessBulkIngestion: Bool
    public var blockedReason: String?

    public init(canProcessBulkIngestion: Bool, blockedReason: String? = nil) {
        self.canProcessBulkIngestion = canProcessBulkIngestion
        self.blockedReason = blockedReason
    }

    public static let allowed = PendingIndexPolicySnapshot(canProcessBulkIngestion: true)
}

public struct PendingIndexJob: Identifiable, Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case pending
        case processing
        case completed
    }

    public let id: UUID
    public var documentURL: URL
    public var documentID: String
    public var status: Status
    public var enqueuedAt: Date
    public var updatedAt: Date
    public var attemptCount: Int
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        documentURL: URL,
        documentID: String,
        status: Status = .pending,
        enqueuedAt: Date = Date(),
        updatedAt: Date = Date(),
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.documentURL = documentURL
        self.documentID = documentID
        self.status = status
        self.enqueuedAt = enqueuedAt
        self.updatedAt = updatedAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}

public actor PendingIndexQueue {
    public typealias Processor = @Sendable (PendingIndexJob) async throws -> Void
    public typealias PolicyProvider = @Sendable () async -> PendingIndexPolicySnapshot

    private var jobs: [PendingIndexJob] = []
    private let storeURL: URL
    private let processor: Processor
    private let policyProvider: PolicyProvider
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        storeURL: URL = PendingIndexQueue.defaultStoreURL(),
        policyProvider: @escaping PolicyProvider = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
                ? PendingIndexPolicySnapshot(
                    canProcessBulkIngestion: false,
                    blockedReason: "Low Power Mode is enabled."
                )
                : .allowed
        },
        processor: @escaping Processor
    ) {
        self.storeURL = storeURL
        self.policyProvider = policyProvider
        self.processor = processor
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? decoder.decode([PendingIndexJob].self, from: data) {
            jobs = decoded.map { job in
                var mutable = job
                if mutable.status == .processing {
                    mutable.status = .pending
                }
                return mutable
            }
        }
    }

    public func enqueue(documentURL: URL, documentID: String) async throws {
        if jobs.contains(where: {
            $0.documentID == documentID && $0.status != .completed
        }) {
            return
        }
        jobs.append(PendingIndexJob(documentURL: documentURL, documentID: documentID))
        try persist()
    }

    @discardableResult
    public func processNextBatch(limit: Int) async throws -> Int {
        let policy = await policyProvider()
        guard policy.canProcessBulkIngestion else { return 0 }

        let clampedLimit = max(0, limit)
        guard clampedLimit > 0 else { return 0 }

        var processed = 0
        while processed < clampedLimit,
              let index = jobs.firstIndex(where: { $0.status == .pending }) {
            jobs[index].status = .processing
            jobs[index].attemptCount += 1
            jobs[index].updatedAt = Date()
            try persist()

            let job = jobs[index]
            do {
                try await processor(job)
                if let current = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[current].status = .completed
                    jobs[current].lastError = nil
                    jobs[current].updatedAt = Date()
                }
                processed += 1
                try persist()
            } catch {
                if let current = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[current].status = .pending
                    jobs[current].lastError = error.localizedDescription
                    jobs[current].updatedAt = Date()
                }
                try persist()
                throw error
            }
        }
        return processed
    }

    public func processAllAllowedBatches(limitPerBatch: Int = 5) async {
        while true {
            do {
                let count = try await processNextBatch(limit: limitPerBatch)
                if count == 0 { return }
            } catch {
                return
            }
        }
    }

    public func pendingJobs() -> [PendingIndexJob] {
        jobs.filter { $0.status == .pending }
    }

    public func allJobs() -> [PendingIndexJob] {
        jobs
    }

    public func resetCompletedJobs() async throws {
        jobs.removeAll { $0.status == .completed }
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(jobs)
        try data.write(to: storeURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    public static func defaultStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAI", isDirectory: true)
        return base.appendingPathComponent("PendingIndexQueue.json")
    }
}
