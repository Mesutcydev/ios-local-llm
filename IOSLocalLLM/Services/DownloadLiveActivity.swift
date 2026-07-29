import Foundation

// Live Activities (ActivityKit) are unavailable on Mac Catalyst: the module
// still imports (`canImport` is true) but every Activity symbol is marked
// `unavailable in Mac Catalyst`, so guard on the environment too. The iOS
// build keeps both conditions true → its code path is unchanged. Mac gets a
// no-op manager (see the #else branch) so callers compile and silently skip
// Live Activities.
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

// MARK: - DownloadActivityAttributes
// Shape of data shown in a download Live Activity (Dynamic Island + lock-screen).
//
// Static attributes are set once when the activity starts; ContentState
// updates with every progress tick.

struct DownloadActivityAttributes: ActivityAttributes {
    public typealias DownloadStatus = ContentState

    public struct ContentState: Codable, Hashable {
        var progress: Double            // 0–1
        var downloadedBytes: Int64
        var totalBytes: Int64
        var currentFile: String
        var filesDone: Int
        var filesTotal: Int
        var failed: Bool
    }

    /// Repo ID stays constant for the life of the activity
    var repoID: String
}

// MARK: - DownloadLiveActivityManager
// Lifecycle wrapper around `Activity<DownloadActivityAttributes>`. One
// activity per repo. Caller drives updates.

@MainActor
final class DownloadLiveActivityManager {

    static let shared = DownloadLiveActivityManager()

    private var activities: [String: Activity<DownloadActivityAttributes>] = [:]

    private init() {}

    /// Starts an activity if Live Activities are enabled. Returns true on success.
    @discardableResult
    func start(repoID: String) -> Bool {
        guard #available(iOS 16.2, *),
              ActivityAuthorizationInfo().areActivitiesEnabled,
              activities[repoID] == nil
        else { return false }

        let attrs = DownloadActivityAttributes(repoID: repoID)
        let state = DownloadActivityAttributes.ContentState(
            progress: 0,
            downloadedBytes: 0, totalBytes: 0,
            currentFile: "starting…",
            filesDone: 0, filesTotal: 0,
            failed: false
        )
        do {
            let activity = try Activity<DownloadActivityAttributes>.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            activities[repoID] = activity
            return true
        } catch {
            print("[LiveActivity] start failed: \(error)")
            return false
        }
    }

    /// Push a progress update.
    func update(repoID: String,
                progress: Double,
                downloadedBytes: Int64,
                totalBytes: Int64,
                currentFile: String,
                filesDone: Int,
                filesTotal: Int) {
        guard #available(iOS 16.2, *),
              let activity = activities[repoID] else { return }
        let state = DownloadActivityAttributes.ContentState(
            progress: progress,
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            currentFile: currentFile,
            filesDone: filesDone,
            filesTotal: filesTotal,
            failed: false
        )
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    /// End an activity (success path).
    func finish(repoID: String) {
        guard #available(iOS 16.2, *),
              let activity = activities[repoID] else { return }
        // Drop the entry NOW (synchronously), before scheduling end(). Otherwise
        // a late update() — these all run as independent unstructured Tasks and
        // can land out of order — could fire its update() AFTER this end() and
        // leave the Live Activity stuck on an intermediate progress state.
        activities.removeValue(forKey: repoID)
        let state = DownloadActivityAttributes.ContentState(
            progress: 1.0,
            downloadedBytes: 0, totalBytes: 0,
            currentFile: "done",
            filesDone: 0, filesTotal: 0,
            failed: false
        )
        Task {
            await activity.end(.init(state: state, staleDate: nil),
                                dismissalPolicy: .after(.now + 4))
        }
    }

    /// End an activity (failure path).
    func fail(repoID: String, reason: String) {
        guard #available(iOS 16.2, *),
              let activity = activities[repoID] else { return }
        let state = DownloadActivityAttributes.ContentState(
            progress: activity.content.state.progress,
            downloadedBytes: activity.content.state.downloadedBytes,
            totalBytes: activity.content.state.totalBytes,
            currentFile: "failed: \(reason)",
            filesDone: activity.content.state.filesDone,
            filesTotal: activity.content.state.filesTotal,
            failed: true
        )
        // Synchronous removal (see finish()) so a late update() can't resurrect
        // the activity after it's ended.
        activities.removeValue(forKey: repoID)
        Task {
            await activity.end(.init(state: state, staleDate: nil),
                                dismissalPolicy: .after(.now + 6))
        }
    }
}

#else

// MARK: - Mac Catalyst no-op
// Live Activities don't exist on Mac. This stub mirrors the manager's API so
// HFModelDownloadManager and other callers compile and run unchanged; every
// method is a no-op and `start` reports "not started".

@MainActor
final class DownloadLiveActivityManager {
    static let shared = DownloadLiveActivityManager()
    private init() {}

    @discardableResult
    func start(repoID: String) -> Bool { false }

    func update(repoID: String,
                progress: Double,
                downloadedBytes: Int64,
                totalBytes: Int64,
                currentFile: String,
                filesDone: Int,
                filesTotal: Int) {}

    func finish(repoID: String) {}

    func fail(repoID: String, reason: String) {}
}

#endif
