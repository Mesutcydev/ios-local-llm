import Foundation
import CryptoKit

/// Foreground-only Hugging Face pack downloader for Core AI.
///
/// Sideloaded builds often stall forever on `URLSessionConfiguration.background`
/// (no delegate callbacks until a background relaunch). This manager uses a
/// dedicated foreground session with byte progress, timeouts, and retries so
/// multi-hundred-MB `ios/` packs actually finish while the app is open.
@MainActor
final class CoreAIHFDownloadManager: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle
        case enumerating
        case downloading
        case paused
        case installing
        case ready
        case failed(String)

        var isActive: Bool {
            self == .enumerating || self == .downloading || self == .installing
        }
    }

    let id: String
    let repoID: String
    let revision: String
    let pathPrefix: String?
    let displayName: String

    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var currentFile = ""
    @Published private(set) var filesDone = 0
    @Published private(set) var filesTotal = 0
    @Published private(set) var speedMBps: Double = 0
    @Published private(set) var statusDetail = ""

    private var runTask: Task<Void, Never>?
    private var pauseRequested = false
    private var files: [RemoteFile] = []
    private var stagingRoot: URL?
    private var lastSampleBytes: Int64 = 0
    private var lastSampleAt = Date()
    private var committedBytes: Int64 = 0
    private var activeTransfer: CoreAIForegroundTransfer?

    private struct RemoteFile: Sendable {
        let remotePath: String
        let localPath: String
        var size: Int64
        /// Hugging Face LFS object id (`sha256:<hex>`), when provided.
        let sha256: String?
    }

    init(
        id: String,
        repoID: String,
        revision: String = "main",
        pathPrefix: String? = nil,
        displayName: String
    ) {
        self.id = id
        self.repoID = repoID
        self.revision = revision
        self.pathPrefix = pathPrefix
        self.displayName = displayName
    }

    convenience init(model: CoreAIZooModel) {
        self.init(
            id: model.id,
            repoID: model.hfRepo,
            revision: model.revision,
            pathPrefix: model.pathPrefix,
            displayName: model.displayName
        )
    }

    func start() {
        guard runTask == nil else { return }
        pauseRequested = false
        if state == .paused, stagingRoot != nil, !files.isEmpty {
            // Publish before scheduling the Task. The Models card reads this in
            // the same event turn as the tap; deferring it made Resume look dead.
            state = .downloading
            statusDetail = "Resuming…"
            runTask = Task { [weak self] in
                await self?.downloadRemaining()
            }
            return
        }
        // Same immediate-feedback rule for a new transfer. `run()` repeats the
        // assignment defensively, but this synchronous state change is what
        // makes the button visibly respond on the first frame.
        state = .enumerating
        statusDetail = "Listing Hub files…"
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    func pause() {
        guard state == .downloading || state == .enumerating else { return }
        pauseRequested = true
        activeTransfer?.cancel()
        activeTransfer = nil
        runTask?.cancel()
        runTask = nil
        state = .paused
        statusDetail = "Paused"
        Diagnostics.shared.breadcrumb("Paused Core AI download · \(repoID)", category: "coreai")
    }

    func resume() {
        switch state {
        case .paused, .failed, .idle, .ready:
            pauseRequested = false
            start()
        default:
            break
        }
    }

    func cancel() {
        pauseRequested = false
        activeTransfer?.cancel()
        activeTransfer = nil
        runTask?.cancel()
        runTask = nil
        if let stagingRoot {
            try? FileManager.default.removeItem(at: stagingRoot)
        }
        stagingRoot = nil
        files = []
        state = .idle
        progress = 0
        downloadedBytes = 0
        committedBytes = 0
        totalBytes = 0
        filesDone = 0
        filesTotal = 0
        currentFile = ""
        speedMBps = 0
        statusDetail = ""
    }

    private func run() async {
        state = .enumerating
        currentFile = ""
        statusDetail = "Listing Hub files…"
        committedBytes = 0
        downloadedBytes = 0
        progress = 0
        do {
            let listed = try await listRemoteFiles()
            try Task.checkCancellation()
            guard !pauseRequested else {
                state = .paused
                runTask = nil
                return
            }
            files = listed
            filesTotal = listed.count
            totalBytes = listed.reduce(0) { $0 + max(0, $1.size) }
            statusDetail = "\(listed.count) files · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
            // Fail before the next byte rather than after several gigabytes.
            // Credit a resumable partial tree already on disk; the remaining
            // transfer plus install headroom is the real requirement.
            let partialRoot = CoreAIModelStore.shared.modelDirectory
                .appendingPathComponent(".download-\(id)/resources", isDirectory: true)
            let remainingBytes = max(
                0,
                totalBytes - Self.allocatedBytes(in: partialRoot)
            )
            try Self.assertStorageAvailable(for: remainingBytes)
            let staging = try prepareStaging()
            stagingRoot = staging
            state = .downloading
            Diagnostics.shared.breadcrumb(
                "Core AI download started · \(displayName) · \(listed.count) files",
                category: "coreai"
            )
            await downloadRemaining()
        } catch is CancellationError {
            if pauseRequested { state = .paused }
            runTask = nil
        } catch {
            state = .failed(error.localizedDescription)
            statusDetail = error.localizedDescription
            runTask = nil
            Diagnostics.shared.error(
                "Core AI download failed · \(error.localizedDescription)",
                category: "coreai"
            )
            ToastCenter.shared.error(error.localizedDescription)
        }
    }

    private func downloadRemaining() async {
        guard let stagingRoot else {
            state = .failed("Missing staging directory.")
            runTask = nil
            return
        }
        state = .downloading
        pauseRequested = false
        lastSampleBytes = downloadedBytes
        lastSampleAt = Date()

        committedBytes = 0
        for file in files {
            let destination = stagingRoot
                .appendingPathComponent("resources", isDirectory: true)
                .appendingPathComponent(file.localPath)
            if fileAlreadyComplete(at: destination, expectedSize: file.size) {
                committedBytes += max(file.size, 0)
            }
        }
        downloadedBytes = committedBytes
        recalculateProgress()

        do {
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                if pauseRequested {
                    state = .paused
                    runTask = nil
                    return
                }
                let destination = stagingRoot
                    .appendingPathComponent("resources", isDirectory: true)
                    .appendingPathComponent(file.localPath)
                if fileAlreadyComplete(at: destination, expectedSize: file.size) {
                    filesDone = index + 1
                    recalculateProgress()
                    continue
                }
                currentFile = file.remotePath
                statusDetail = "File \(index + 1)/\(filesTotal)"
                try await downloadFile(file, to: destination)
                filesDone = index + 1
                recalculateProgress()
            }

            // The tree API supplies the immutable Hugging Face LFS object id.
            // Verify every LFS-backed file before the pack can enter the model
            // store; size-only validation cannot detect same-length corruption
            // or a compromised transfer cache.
            currentFile = ""
            statusDetail = "Verifying downloaded files…"
            for file in files {
                try Task.checkCancellation()
                guard let expected = file.sha256 else { continue }
                let destination = stagingRoot
                    .appendingPathComponent("resources", isDirectory: true)
                    .appendingPathComponent(file.localPath)
                let actual = try Self.sha256(of: destination)
                guard actual == expected else {
                    try? FileManager.default.removeItem(at: destination)
                    throw CoreAIDownloadError.checksumMismatch(file.remotePath)
                }
            }

            state = .installing
            currentFile = ""
            statusDetail = "Validating pack…"
            // Reinstalling the active identity replaces its files, so drain that
            // runtime first. Installing a different identity does not disturb
            // the current Assistant selection or any other saved Core AI pack.
            let assistant = CodingAssistantService.shared
            let replacedActiveCoreAI = assistant.activeExecutionLocation == .localCoreAI
                && assistant.activeModel.id == "coreai:\(id)"
            if replacedActiveCoreAI {
                await assistant.unloadAndWaitForCleanup()
            }
            let resources = stagingRoot.appendingPathComponent("resources", isDirectory: true)
            try CoreAIModelStore.shared.importModel(
                from: resources,
                preferredID: id,
                preferredDisplayName: displayName
            )
            if replacedActiveCoreAI,
               let installed = CoreAIModelStore.shared.installedModel(id: id),
               let newModel = installed.assistantModel {
                await assistant.adoptSelectionWithoutLoading(newModel)
            }
            try? FileManager.default.removeItem(at: stagingRoot)
            self.stagingRoot = nil
            state = .ready
            progress = 1
            statusDetail = "Installed"
            currentFile = ""
            runTask = nil
            Diagnostics.shared.breadcrumb("Core AI pack installed · \(displayName)", category: "coreai")
            ToastCenter.shared.success(
                "Installed \(displayName)",
                detail: CoreAIZooCatalog.isTextGenerationPack(id: id)
                    ? "Select it from Assistant to use the Core AI runtime."
                    : "This pack is installed but is not a chat model."
            )
        } catch is CancellationError {
            if pauseRequested { state = .paused }
            runTask = nil
        } catch {
            if Self.isUserCancellation(error) {
                if pauseRequested { state = .paused }
                runTask = nil
                return
            }
            state = .failed(error.localizedDescription)
            statusDetail = error.localizedDescription
            runTask = nil
            Diagnostics.shared.error(
                "Core AI download failed · \(error.localizedDescription)",
                category: "coreai"
            )
            ToastCenter.shared.error(error.localizedDescription)
        }
    }

    private func prepareStaging() throws -> URL {
        let root = CoreAIModelStore.shared.modelDirectory
            .appendingPathComponent(".download-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        return root
    }

    /// Reserve for the OS plus the temporary duplication the install move can
    /// incur. Without this a 5 GB pack on a nearly-full device downloads for
    /// twenty minutes and then fails at the last step with a write error.
    private static let storageHeadroom: Int64 = 1_500_000_000

    private static func allocatedBytes(in root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.fileAllocatedSizeKey, .isDirectoryKey]
            )
            guard values?.isDirectory != true else { continue }
            total += Int64(values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    private static func assertStorageAvailable(for required: Int64) throws {
        guard required > 0 else { return }
        let dir = CoreAIModelStore.shared.modelDirectory
        // `volumeAvailableCapacityForImportantUsage` is the value iOS will
        // actually let the app consume (it accounts for purgeable space),
        // unlike the raw free-byte count.
        let probe = FileManager.default.fileExists(atPath: dir.path)
            ? dir
            : dir.deletingLastPathComponent()
        guard let available = (try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ))?.volumeAvailableCapacityForImportantUsage else {
            return  // Cannot measure — do not block the operator on a guess.
        }
        let needed = required + storageHeadroom
        guard available < needed else { return }
        throw CoreAIDownloadError.insufficientStorage(
            required: needed,
            available: Int64(available)
        )
    }

    private func listRemoteFiles() async throws -> [RemoteFile] {
        var collected: [RemoteFile] = []
        var cursor: String?
        repeat {
            // The repo id comes from a free-text field; anything URL-hostile
            // (spaces, emoji, `#`) must fail with a friendly error instead of
            // trapping on the force-unwrap this replaced.
            guard var components = URLComponents(
                string: "https://huggingface.co/api/models/\(repoID)/tree/\(revision)"
            ) else {
                throw CoreAIDownloadError.invalidRepoID(repoID)
            }
            var items: [URLQueryItem] = [
                URLQueryItem(name: "recursive", value: "1")
            ]
            if let cursor {
                items.append(URLQueryItem(name: "cursor", value: cursor))
            }
            components.queryItems = items
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(
                "OnDeviceCoreAIStudio/3.2.6 (iOS; Core AI pack download)",
                forHTTPHeaderField: "User-Agent"
            )
            HFTokenStore.authorize(&request)
            let (data, response) = try await withRetries {
                try await URLSession.shared.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CoreAIDownloadError.tokenRequired
            }
            guard 200..<300 ~= http.statusCode else {
                throw CoreAIDownloadError.httpStatus(http.statusCode)
            }
            let page = try JSONDecoder().decode([HFTreeEntry].self, from: data)
            for entry in page where entry.type == "file" {
                if let pathPrefix, !pathPrefix.isEmpty {
                    let normalized = pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/"
                    guard entry.path == pathPrefix
                        || entry.path.hasPrefix(normalized) else { continue }
                }
                let lower = entry.path.lowercased()
                if lower.hasSuffix(".md") || lower.hasSuffix(".gitattributes") { continue }
                let size = entry.lfs?.size ?? entry.size ?? 0
                collected.append(
                    RemoteFile(
                        remotePath: entry.path,
                        localPath: stripPrefix(entry.path),
                        size: size,
                        sha256: entry.lfs?.oid.flatMap(HFHubMetadata.normalizedSHA256)
                    )
                )
            }
            // The Hub paginates its tree API through the RFC `Link` header
            // (`Link: <...cursor=xyz...>; rel="next"`), not a custom
            // X-Next-Cursor field. Parsing anything else stops after the
            // first page and silently downloads an incomplete pack.
            cursor = HFHubMetadata.nextCursor(fromLinkHeader: http.value(forHTTPHeaderField: "Link"))
        } while cursor != nil && !(cursor?.isEmpty ?? true)

        guard !collected.isEmpty else { throw CoreAIDownloadError.emptyTree }
        return collected
    }

    private func stripPrefix(_ path: String) -> String {
        guard let pathPrefix, !pathPrefix.isEmpty else { return path }
        if path == pathPrefix {
            return pathPrefix.split(separator: "/").last.map(String.init) ?? path
        }
        let normalized = pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/"
        if path.hasPrefix(normalized) {
            return String(path.dropFirst(normalized.count))
        }
        return path
    }

    private func downloadFile(_ file: RemoteFile, to destination: URL) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encodedPath = file.remotePath
            .split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(
            string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(encodedPath)"
        ) else {
            throw URLError(.badURL)
        }

        let maxAttempts = 4
        var attempt = 0
        while true {
            do {
                let transfer = CoreAIForegroundTransfer()
                activeTransfer = transfer
                defer { if activeTransfer === transfer { activeTransfer = nil } }

                _ = try await transfer.download(from: url, to: destination) { [weak self] received, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.downloadedBytes = self.committedBytes + max(0, received)
                        self.recalculateProgress()
                        self.sampleSpeed()
                    }
                }

                let onDisk = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map(Int64.init) ?? max(file.size, 0)
                committedBytes += max(onDisk, 0)
                downloadedBytes = committedBytes
                sampleSpeed()
                return
            } catch {
                attempt += 1
                if Task.isCancelled || Self.isUserCancellation(error) {
                    throw CancellationError()
                }
                let ns = error as NSError
                if ns.domain == "HFDownload" || ns.domain == "CoreAIDownload",
                   ns.code == 401 || ns.code == 403 {
                    throw CoreAIDownloadError.tokenRequired
                }
                guard attempt < maxAttempts, Self.isRetryable(error) else { throw error }
                statusDetail = "Retry \(attempt)/\(maxAttempts - 1)…"
                Diagnostics.shared.warning(
                    "\(repoID): \(file.remotePath) attempt \(attempt) failed; retrying — \(error.localizedDescription)",
                    category: "coreai"
                )
                downloadedBytes = committedBytes
                recalculateProgress()
                try? await Task.sleep(nanoseconds: Self.retryDelayNs(attempt: attempt, error: error))
            }
        }
    }

    private func fileAlreadyComplete(at url: URL, expectedSize: Int64) -> Bool {
        guard expectedSize > 0 else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        return size == expectedSize
    }

    /// Incremental hashing keeps the memory envelope flat for 1–5 GB model
    /// files. Reading `Data(contentsOf:)` here would briefly duplicate the
    /// entire pack in RAM just before Core AI specialization.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 8 * 1_024 * 1_024),
                  !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func recalculateProgress() {
        if totalBytes > 0 {
            progress = min(0.999, Double(downloadedBytes) / Double(totalBytes))
            if filesDone >= filesTotal, filesTotal > 0 {
                progress = min(1, progress)
            }
        } else if filesTotal > 0 {
            progress = Double(filesDone) / Double(filesTotal)
        }
    }

    private func sampleSpeed() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleAt)
        guard elapsed >= 0.35 else { return }
        let delta = Double(downloadedBytes - lastSampleBytes)
        speedMBps = max(0, (delta / elapsed) / 1_000_000)
        lastSampleBytes = downloadedBytes
        lastSampleAt = now
    }

    private func withRetries<T>(
        maxAttempts: Int = 3,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                attempt += 1
                if Task.isCancelled || Self.isUserCancellation(error) {
                    throw CancellationError()
                }
                guard attempt < maxAttempts, Self.isRetryable(error) else { throw error }
                try? await Task.sleep(nanoseconds: Self.retryDelayNs(attempt: attempt, error: error))
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorResourceUnavailable,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCancelled:
                // Cancelled by our stall watchdog / pause is handled separately;
                // network cancels from the session are still worth one retry.
                return ns.code != NSURLErrorCancelled
            default:
                return false
            }
        }
        if ns.domain == "HFDownload" || ns.domain == "CoreAIDownload" {
            return ns.code == 429 || (500...599).contains(ns.code) || ns.code == -6
        }
        return false
    }

    private static func isUserCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    private static func retryDelayNs(attempt: Int, error: Error) -> UInt64 {
        let capSeconds: Double = 60
        if let retryAfter = (error as NSError).userInfo["Retry-After"] as? String,
           let seconds = Double(retryAfter), seconds > 0 {
            return UInt64(min(seconds, capSeconds) * 1_000_000_000)
        }
        let base = 1.5 * pow(2, Double(attempt - 1))
        let jittered = base * Double.random(in: 0.75...1.25)
        return UInt64(min(jittered, capSeconds) * 1_000_000_000)
    }
}

// MARK: - Foreground transfer

/// One-shot foreground download with live byte progress.
/// Avoids background URLSession, which frequently never resumes continuations
/// in ad-hoc / TrollStore sideloads.
final class CoreAIForegroundTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: ((Int64, Int64) -> Void)?
    private var destination: URL?
    private var expectedSize: Int64 = 0
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var lastProgressAt = Date()
    private var watchdog: Task<Void, Never>?

    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        self.destination = destination
        self.progressHandler = progress

        let wifiOnly = await MainActor.run { AppSettings.shared.wifiOnlyDownloads }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 6 * 60 * 60
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.allowsCellularAccess = !wifiOnly
        cfg.allowsExpensiveNetworkAccess = !wifiOnly

        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        self.session = session

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(
            "OnDeviceCoreAIStudio/3.2.6 (iOS; Core AI pack download)",
            forHTTPHeaderField: "User-Agent"
        )
        if let host = url.host?.lowercased(),
           host == "huggingface.co" || host.hasSuffix(".huggingface.co") {
            HFTokenStore.authorize(&request)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                self.continuation = cont
                let task = session.downloadTask(with: request)
                self.task = task
                self.lastProgressAt = Date()
                self.watchdog = Task { [weak self] in
                    await self?.watchForStall()
                }
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func cancel() {
        watchdog?.cancel()
        watchdog = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(throwing: CancellationError())
        }
        progressHandler = nil
        destination = nil
    }

    private func watchForStall() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            guard continuation != nil else { return }
            if Date().timeIntervalSince(lastProgressAt) >= 90 {
                Diagnostics.shared.warning(
                    "Core AI transfer stalled 90s; cancelling for retry",
                    category: "coreai"
                )
                let cont = continuation
                continuation = nil
                task?.cancel()
                session?.invalidateAndCancel()
                cont?.resume(throwing: NSError(
                    domain: "CoreAIDownload",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "Download stalled — retrying."]
                ))
                return
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        watchdog?.cancel()
        watchdog = nil
        guard let cont = continuation else { return }
        continuation = nil
        progressHandler = nil
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
        cont.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lastProgressAt = Date()
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        progressHandler?(totalBytesWritten, expected)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destination else {
            finish(.failure(URLError(.cannotCreateFile)))
            return
        }
        let response = downloadTask.response as? HTTPURLResponse
        let code = response?.statusCode ?? -1
        if !(200..<300 ~= code) {
            var userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: "HTTP \(code) while downloading \(destination.lastPathComponent)"
            ]
            if let retryAfter = response?.value(forHTTPHeaderField: "Retry-After") {
                userInfo["Retry-After"] = retryAfter
            }
            finish(.failure(NSError(domain: "CoreAIDownload", code: code, userInfo: userInfo)))
            return
        }

        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            // URLSession may delete `location` when this delegate returns —
            // move synchronously before returning.
            do {
                try fm.moveItem(at: location, to: destination)
            } catch {
                let tmp = destination.appendingPathExtension("tmp")
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: location, to: tmp)
                try fm.moveItem(at: tmp, to: destination)
            }
            FileManager.excludeFromBackup(destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(.failure(error))
    }
}

private struct HFTreeEntry: Decodable {
    let type: String
    let path: String
    let size: Int64?
    let lfs: LFS?

    struct LFS: Decodable {
        let size: Int64?
        let oid: String?
    }
}

enum CoreAIDownloadError: LocalizedError {
    case tokenRequired
    case httpStatus(Int)
    case emptyTree
    case invalidRepoID(String)
    case insufficientStorage(required: Int64, available: Int64)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .tokenRequired:
            return "Hugging Face returned 401/403. Add an access token for gated repos."
        case .httpStatus(let code):
            return "Hugging Face HTTP \(code)"
        case .emptyTree:
            return "No downloadable files found under the selected Hub path."
        case .invalidRepoID(let value):
            return "\"\(value)\" is not a valid repository id. Use the owner/repo form, for example mlx-community/Some-Model."
        case .insufficientStorage(let required, let available):
            let need = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Not enough storage: this pack needs about \(need) (including install headroom) but only \(have) is free."
        case .checksumMismatch(let path):
            return "The downloaded file failed its Hugging Face LFS SHA-256 check: \(path). The bad file was removed; retry the download."
        }
    }
}

/// Active Core AI downloads observed by the Models UI.
@MainActor
final class CoreAIDownloadCenter: ObservableObject {
    static let shared = CoreAIDownloadCenter()

    @Published private(set) var downloads: [CoreAIHFDownloadManager] = []

    func existing(id: String) -> CoreAIHFDownloadManager? {
        downloads.first(where: { $0.id == id })
    }

    func manager(for model: CoreAIZooModel) -> CoreAIHFDownloadManager {
        if let existing = existing(id: model.id) { return existing }
        let created = CoreAIHFDownloadManager(model: model)
        downloads.insert(created, at: 0)
        objectWillChange.send()
        return created
    }

    func manager(
        repoID: String,
        pathPrefix: String? = nil,
        displayName: String? = nil
    ) -> CoreAIHFDownloadManager {
        let id = "hf:\(repoID)#\(pathPrefix ?? "")"
        if let existing = existing(id: id) { return existing }
        let created = CoreAIHFDownloadManager(
            id: id,
            repoID: repoID,
            pathPrefix: pathPrefix,
            displayName: displayName ?? repoID
        )
        downloads.insert(created, at: 0)
        objectWillChange.send()
        return created
    }

    func start(model: CoreAIZooModel) {
        manager(for: model).start()
    }

    func removeFinished() {
        downloads.removeAll {
            if case .ready = $0.state { return true }
            if case .idle = $0.state { return true }
            return false
        }
        objectWillChange.send()
    }
}
