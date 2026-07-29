import Foundation
import CryptoKit
import Network

// MARK: - BackgroundDownloadCoordinator
// Shared URLSession with background configuration so model downloads continue
// when the app is suspended. Each file download is registered with a UUID
// key and routed back to its async continuation when finished.
//
// Architecture:
//   • One singleton URLSession created with .background(withIdentifier:)
//   • Map: URLSessionDownloadTask.taskIdentifier → continuation + destination
//   • Delegate methods translate progress callbacks back to per-task closures
//
// When iOS relaunches the app for background-session events, AppDelegate
// calls reattach() so the (lazy) session is re-created and its delegate
// receives the queued events; each task's destination is recovered from
// taskDescription since the in-memory Pending map didn't survive.

@MainActor
final class BackgroundDownloadCoordinator: NSObject {

    static let shared = BackgroundDownloadCoordinator()

    // Public completion handler hook used by AppDelegate when iOS wakes us up
    // to deliver finished events. ContentView/App can wire this if needed.
    var systemCompletionHandler: (() -> Void)?

    // MARK: - URLSession

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(
            withIdentifier: "com.mesutcydev.ioslocalllm.background-downloads"
        )
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        // "Wi-Fi only downloads" setting (Settings → Models). The config is
        // frozen at session creation, so download() ALSO enforces it
        // per-task at enqueue time — this just covers tasks the system
        // restores across relaunches.
        let wifiOnly = AppSettings.shared.wifiOnlyDownloads
        cfg.allowsCellularAccess = !wifiOnly
        cfg.allowsExpensiveNetworkAccess = !wifiOnly
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }()

    /// Watches the current network path so enqueue-time checks can tell
    /// whether we're on an expensive (cellular / hotspot) link.
    private let pathMonitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "com.mesutcydev.ioslocalllm.download-path-monitor"))
        return monitor
    }()

    /// Re-creates the background URLSession after iOS relaunches the app to
    /// deliver background-session events. The session is `lazy`, so without
    /// touching it here the delegate was never attached on relaunch and the
    /// queued events were silently dropped.
    func reattach() { _ = session }

    // MARK: - Per-task tracking

    private struct Pending {
        let destination: URL
        let expectedSize: Int64
        let progress: (Int64, Int64) -> Void
        let continuation: CheckedContinuation<URL, Error>
    }
    private var pendingByTaskID: [Int: Pending] = [:]

    // MARK: - Public API

    /// Downloads `url` to `destination` and reports progress. Survives app
    /// backgrounding. Returns the final destination URL.
    func download(
        from url: URL,
        to destination: URL,
        expectedSize: Int64,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            // Attach HF token for huggingface.co downloads only — the
            // coordinator is generic but the token must not leak to
            // unrelated hosts (e.g. if the bundle ever fetches a
            // CoreML model from a non-HF mirror). Host check is
            // exact-suffix to also cover cdn-lfs.huggingface.co et al.
            if let host = url.host?.lowercased(),
               host == "huggingface.co" || host.hasSuffix(".huggingface.co") {
                HFTokenStore.authorize(&request)
            }

            // Enforce "Wi-Fi only downloads" per task too — the session
            // config can't change after creation, so a setting flipped
            // mid-session would otherwise be ignored.
            if AppSettings.shared.wifiOnlyDownloads {
                request.allowsCellularAccess = false
                request.allowsExpensiveNetworkAccess = false
                if self.pathMonitor.currentPath.isExpensive {
                    continuation.resume(throwing: NSError(
                        domain: "HFDownload", code: -5,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Wi-Fi only downloads is on and this connection is cellular. Connect to Wi-Fi or turn the setting off in Settings → Models."]
                    ))
                    return
                }
            }

            // Resume an interrupted transfer when URLSession handed us
            // resume data for this URL — otherwise a dropped multi-GB file
            // restarted from byte 0. EXCEPTION: an authorized request can't be
            // resumed. URLSession resume data does NOT re-encode request
            // headers, so a resumed gated-HF download would drop the
            // `Authorization: Bearer` token attached above and 401 mid-resume.
            // When an auth header is present we discard the resume data and
            // rebuild from the fresh authorized request; restarting beats a
            // guaranteed auth failure. Public/non-HF downloads keep resume.
            let hasAuthHeader = request.value(forHTTPHeaderField: "Authorization") != nil
            let task: URLSessionDownloadTask
            if !hasAuthHeader, let resumeData = Self.consumeResumeData(for: url) {
                task = self.session.downloadTask(withResumeData: resumeData)
            } else {
                if hasAuthHeader { Self.clearResumeData(for: url) }
                task = self.session.downloadTask(with: request)
            }
            // The destination rides on the task itself so it survives an app
            // relaunch — pendingByTaskID is in-memory only, and without this
            // a download finishing after relaunch was deleted as untracked.
            task.taskDescription = destination.path
            self.pendingByTaskID[task.taskIdentifier] = Pending(
                destination: destination,
                expectedSize: expectedSize,
                progress: progress,
                continuation: continuation
            )
            task.resume()
        }
    }

    // MARK: - Resume data persistence
    //
    // URLSession hands back opaque resume data when a download task fails
    // (didCompleteWithError → NSURLSessionDownloadTaskResumeData). It's
    // persisted to a temp sidecar keyed by a hash of the source URL, and
    // consumed by the next download() for the same URL.

    private nonisolated static func resumeDataSidecar(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-resume-\(name).dat")
    }

    nonisolated static func storeResumeData(_ data: Data, for url: URL?) {
        guard let url else { return }
        try? data.write(to: resumeDataSidecar(for: url), options: [.atomic])
    }

    /// Returns persisted resume data for `url` (deleting the sidecar — it's
    /// single-use either way: consumed by the new task or invalid).
    nonisolated static func consumeResumeData(for url: URL) -> Data? {
        let sidecar = resumeDataSidecar(for: url)
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        try? FileManager.default.removeItem(at: sidecar)
        return data
    }

    nonisolated static func clearResumeData(for url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: resumeDataSidecar(for: url))
    }

    /// Total bytes held by abandoned URLSession resume sidecars. These are
    /// useful for retrying a failed transfer, but once the user explicitly
    /// chooses storage cleanup they should not remain as invisible cache.
    nonisolated static func staleResumeDataBytes() -> Int64 {
        resumeDataSidecars().reduce(0) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + Int64(size)
        }
    }

    /// Removes every persisted HF resume sidecar and returns bytes reclaimed.
    /// Active downloads do not have resume sidecars; the files are written only
    /// after URLSession reports an interrupted task.
    @discardableResult
    nonisolated static func clearAllResumeData() -> Int64 {
        let sidecars = resumeDataSidecars()
        let bytes = sidecars.reduce(Int64(0)) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + Int64(size)
        }
        for url in sidecars { try? FileManager.default.removeItem(at: url) }
        return bytes
    }

    private nonisolated static func resumeDataSidecars() -> [URL] {
        let temporary = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter {
            $0.lastPathComponent.hasPrefix("hf-resume-") && $0.pathExtension == "dat"
        }
    }

    /// Cancels every in-flight download.
    func cancelAll() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    /// Cancels in-flight tasks whose pending destination path begins with the
    /// given root. Used to abort one repo's downloads without stomping others.
    func cancelTasks(matching destinationPrefix: String) async {
        let matchingIDs = pendingByTaskID
            .filter { $0.value.destination.path.hasPrefix(destinationPrefix) }
            .map(\.key)

        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                for task in tasks where matchingIDs.contains(task.taskIdentifier) {
                    task.cancel()
                }
                continuation.resume()
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadCoordinator: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let taskID = downloadTask.taskIdentifier
        let fm = FileManager.default

        // CRITICAL: URLSession deletes `location` the moment this delegate
        // method returns. The move MUST happen synchronously here — not
        // dispatched to MainActor — otherwise the temp file vanishes first.
        let response = downloadTask.response as? HTTPURLResponse
        let statusCode = response?.statusCode ?? 0
        let urlPath = downloadTask.originalRequest?.url?.path ?? "<unknown>"

        // The URLSession was constructed with `delegateQueue: .main`, so this
        // method already runs on the main thread. We can use
        // MainActor.assumeIsolated to access MainActor-isolated state safely.
        let pending: Pending? = MainActor.assumeIsolated {
            self.pendingByTaskID.removeValue(forKey: taskID)
        }
        // After an app relaunch the in-memory Pending map is gone, but the
        // destination was stored on the task itself (taskDescription) at
        // enqueue time — recover it so the completed bytes are kept instead
        // of deleted. Only delete when even that is absent.
        let destination: URL
        if let p = pending {
            destination = p.destination
        } else if let path = downloadTask.taskDescription, !path.isEmpty {
            destination = URL(fileURLWithPath: path)
        } else {
            try? fm.removeItem(at: location)
            return
        }

        // Validate HTTP status — URLSession "succeeds" even on 4xx/5xx,
        // writing the error body to the temp file as if it were the asset.
        if let response, !(200...299).contains(statusCode) {
            try? fm.removeItem(at: location)
            let reason: String
            switch statusCode {
            case 404: reason = "File not found (404): \(urlPath)"
            case 401: reason = "Login required (401): \(urlPath)"
            case 403: reason = "Access denied (403): \(urlPath)"
            case 429: reason = "Rate limited (429). Try again in a minute."
            default:  reason = "HTTP \(statusCode) for \(urlPath)"
            }
            var userInfo: [String: Any] = [NSLocalizedDescriptionKey: reason]
            // Thread the server's pacing hint through to the retry helper
            // so 429/503 backoff can honor it.
            if let retryAfter = response.value(forHTTPHeaderField: "Retry-After") {
                userInfo["Retry-After"] = retryAfter
            }
            pending?.continuation.resume(
                throwing: NSError(domain: "HFDownload", code: statusCode,
                                  userInfo: userInfo)
            )
            return
        }

        // Perform the move SYNCHRONOUSLY. If we fail, copy as a fallback.
        do {
            let parent = destination.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            do {
                try fm.moveItem(at: location, to: destination)
            } catch {
                // Cross-volume or sandbox issue — fall back to copy. Copy
                // into a .tmp sidecar then rename so a mid-copy crash can't
                // leave a half-written file at the final path.
                let tmp = URL(fileURLWithPath: destination.path + ".tmp")
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: location, to: tmp)
                try fm.moveItem(at: tmp, to: destination)
                try? fm.removeItem(at: location)
            }
            // Weights are re-downloadable — keep them out of iCloud backups.
            FileManager.excludeFromBackup(destination)
            // The transfer finished — any stale resume data for this URL is
            // now useless.
            Self.clearResumeData(for: downloadTask.originalRequest?.url
                                       ?? downloadTask.currentRequest?.url)
            pending?.continuation.resume(returning: destination)
        } catch {
            try? fm.removeItem(at: location)
            pending?.continuation.resume(throwing: error)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor [weak self] in
            guard let self,
                  let p = self.pendingByTaskID[taskID] else { return }
            let expected = totalBytesExpectedToWrite > 0
                ? totalBytesExpectedToWrite : p.expectedSize
            p.progress(totalBytesWritten, expected)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }   // success path handled in didFinishDownloadingTo
        // Persist URLSession's resume data so the next attempt for this URL
        // continues where the transfer broke instead of restarting at byte 0.
        if let resumeData = (error as NSError)
            .userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            Self.storeResumeData(resumeData,
                                 for: task.originalRequest?.url ?? task.currentRequest?.url)
        }
        let taskID = task.taskIdentifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let p = self.pendingByTaskID.removeValue(forKey: taskID) {
                p.continuation.resume(throwing: error)
            }
        }
    }

    // Called when all background events have been delivered after a re-launch.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.systemCompletionHandler?()
            self?.systemCompletionHandler = nil
        }
    }
}
