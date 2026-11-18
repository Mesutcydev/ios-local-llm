import Foundation
import CoreSpotlight

// MARK: - WipeAllDataService
// Single button: clear every piece of user data the app has stored locally.
// Used for testing AND for privacy-conscious users who want to start over
// before, say, lending their device. Does NOT touch system caches owned by
// other components (e.g., MLX's HF hub cache lives in ~/Library/Caches and
// we wipe it too).
//
// Returns a Receipt of what was wiped so the UI can show a confirmation.

@MainActor
enum WipeAllDataService {

    struct Receipt {
        var modelsDeleted: Int = 0
        var bytesFreed: Int64 = 0
        var conversationsDeleted: Int = 0
        var snippetsDeleted: Int = 0
        var memoriesDeleted: Int = 0
        var settingsCleared: Bool = false
        var keychainItemsCleared: Int = 0
        var failures: [String] = []
    }

    static func wipeAll() async -> Receipt {
        var r = Receipt()
        guard ImageGenerationParentalControls.shared.canGenerate else {
            r.failures = ["Enter the parental PIN in Settings before resetting app data."]
            return r
        }
        KnowledgeBaseService.shared.cancelImports()
        await CoreAIDownloadCenter.shared.cancelAndDrainForWipe()
        defer { CoreAIDownloadCenter.shared.finishWipe() }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        func remove(_ url: URL) {
            guard fm.fileExists(atPath: url.path) else { return }
            do { try fm.removeItem(at: url) }
            catch { r.failures.append("Some local files could not be deleted. Close active tasks and retry the reset.") }
        }

        // Stop consumers before removing their data. Disabling iCloud first
        // makes in-flight sync abort before it can merge old history locally.
        let hadCloudSync = AppSettings.shared.iCloudSyncEnabled
        AppSettings.shared.iCloudSyncEnabled = false
        // iCloud keeps its own copy of every synced conversation. Delete it
        // now when possible. Otherwise keep deletion markers (stamped again
        // after the settings reset below) so the next sync removes the copies
        // instead of pulling the wiped chats back.
        var cloudMarkers: [UUID] = []
        if hadCloudSync {
            do {
                try await CloudSyncService.shared.deleteAllRemoteConversations()
            } catch {
                cloudMarkers = ConversationStore.shared.conversations.map(\.id)
                    + CloudSyncTombstones.markedIDs
                r.failures.append("iCloud copies of your conversations could not be deleted now. They are removed the next time iCloud sync runs.")
            }
        }
        AppSettings.shared.localAPIEnabled = false
        await LocalAPIManager.shared.stop()
        await BridgeManager.shared.stop()
        await WebToolService.shared.cancelAndWait()
        VoiceConversationService.shared.stop()
        for model in ModelDownloadCenter.shared.models { model.cancel() }
        await BackgroundDownloadCoordinator.shared.cancelAllForWipe()
        defer { BackgroundDownloadCoordinator.shared.finishWipe() }
        BenchmarkService.shared.cancel()
        ImageGenerationService.shared.cancel()
        LensInferenceLoop.shared.suspendNewRequests()
        await CodingAssistantService.shared.cancelAndDrainInference()
        await CodingAssistantService.shared.unloadAndWaitForCleanup()
        LensInferenceLoop.shared.unload()
        FastVLMService.shared.unload()
        await LlamaCppVLMService.shared.unloadAndWaitForCleanup()
        VoiceService.shared.unloadAll()
        let coreAIStore = CoreAIModelStore.shared
        r.bytesFreed += dirSize(at: coreAIStore.modelDirectory)
        r.modelsDeleted += coreAIStore.installations.count
        do { try coreAIStore.removeAllModels() }
        catch { r.failures.append("Core AI packs could not be deleted.") }

        // 1. Downloaded models
        for sub in ["HFModels", "FastVLMModels", "LLMModels", "VoiceModels", "GGUFModels", "WhisperModels"] {
            let url = docs.appendingPathComponent(sub, isDirectory: true)
            r.bytesFreed += dirSize(at: url)
            if fm.fileExists(atPath: url.path) {
                let count = (try? fm.contentsOfDirectory(atPath: url.path).count) ?? 0
                r.modelsDeleted += count
                remove(url)
            }
        }

        // 2. MLX HubApi cache. swift-transformers' HubApi defaults its
        // downloadBase to Documents/huggingface — NOT Caches/huggingface
        // as an earlier comment in this file claimed. The previous version
        // of this code wiped the wrong path entirely, leaving the actual
        // MLX downloads behind. Now we wipe both for belt-and-suspenders
        // (some HubApi setups in older swift-transformers releases did use
        // Caches/, so a real install in the wild could have leftover files
        // in either place).
        let hubRoots = [
            docs.appendingPathComponent("huggingface", isDirectory: true),
            caches.appendingPathComponent("huggingface", isDirectory: true),
        ]
        for root in hubRoots where fm.fileExists(atPath: root.path) {
            r.bytesFreed += dirSize(at: root)
            remove(root)
        }

        // 3. Conversations (ConversationStore writes JSON to Documents)
        let conv = docs.appendingPathComponent("conversations.json")
        if fm.fileExists(atPath: conv.path) {
            // Count items first
            if let data = try? Data(contentsOf: conv),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                r.conversationsDeleted = arr.count
            }
            remove(conv)
        }
        // Clear the in-memory store too (and cancel its pending debounced
        // save). Otherwise a later flush() on scene-phase background would
        // rewrite conversations.json AND re-index the just-wiped chats back
        // into Spotlight from memory, silently undoing steps 3 and 6.
        ConversationStore.shared.clearAllForWipe()

        // 4. Clear live stores as well as their actual persistence keys.
        r.snippetsDeleted = SnippetStore.shared.snippets.count
        r.memoriesDeleted = MemoryStore.shared.facts.count
        SnippetStore.shared.clearAllForWipe()
        MemoryStore.shared.clearAllForWipe()
        PersonaStore.shared.clearAllForWipe()
        MacroStore.shared.clearAllForWipe()
        WebActivityLogger.shared.clear()
        WebToolService.shared.settings = WebToolSettings()
        WebToolService.shared.cancel()
        BenchmarkService.shared.clearHistory()
        MetricKitHandler.shared.clear()
        ModelArenaStore.shared.reset()
        URLCache.shared.removeAllCachedResponses()

        // 5. Remove this app's preferences, including prompts, selections,
        // legal acknowledgements and legacy keys. Do not modify other apps.
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        r.settingsCleared = true
        cloudMarkers.forEach(CloudSyncTombstones.mark)

        // 6. CoreSpotlight index. Chats were indexed (title + first ~200 chars
        //    of the first message). Deleting conversations.json does NOT remove
        //    them from system Spotlight, so wiped chats stayed searchable from
        //    the home screen — defeating the privacy purpose of this button.
        do { try await CSSearchableIndex.default().deleteAllSearchableItems() }
        catch { r.failures.append("The search index could not be cleared. Retry the reset to remove searchable history.") }

        // 7. App Group staged share files (SharedImages / SharedText) the share
        //    extension wrote but the app may not have consumed — otherwise this
        //    user content survives a full wipe.
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: AppBridge.appGroupID) {
            for sub in ["SharedImages", "SharedText", SharedContentInbox.directoryName] {
                let url = group.appendingPathComponent(sub, isDirectory: true)
                r.bytesFreed += dirSize(at: url)
                remove(url)
            }
        }

        // 8. Application Support stores: installed-model registry, recovery
        //    breadcrumbs, diagnostics + crash artifacts, RAG queue, and the
        //    Knowledge Base index. Deleting the files alone is not enough —
        //    the in-memory singletons would rewrite them, and the registry
        //    used to re-list wiped models on the refresh below.
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for sub in ["Registry", "Recovery", "LocalAI", "KnowledgeBase"] {
            r.bytesFreed += dirSize(at: appSupport.appendingPathComponent(sub, isDirectory: true))
            remove(appSupport.appendingPathComponent(sub, isDirectory: true))
        }
        // Diagnostics: remove logs + crash artifacts but NOT `running.marker`,
        // which CrashReporter uses to detect an unclean exit for the rest of
        // this session. Deleting the whole directory would silently disable
        // crash/jetsam detection until the next launch.
        let diagnosticsDir = appSupport.appendingPathComponent("Diagnostics", isDirectory: true)
        if let contents = try? fm.contentsOfDirectory(
            at: diagnosticsDir, includingPropertiesForKeys: nil
        ) {
            for item in contents where item.lastPathComponent != "running.marker" {
                r.bytesFreed += dirSize(at: item)
                remove(item)
            }
        }
        InstalledModelRegistry.shared.removeAll()
        RecoveryManager.shared.reset()
        Diagnostics.shared.clear()
        CrashReporter.shared.clearCrashArtifacts()
        KnowledgeBaseService.shared.wipeFromDisk()

        // 9. Keychain credentials — HF token, web search API keys, Mac Bridge
        //    bearer tokens. These survive a file-only wipe unless cleared here.
        if HFTokenStore.shared.clear() { r.keychainItemsCleared += 1 }
        let webKeysBefore = ["brave.apiKey", "tavily.apiKey", "exa.apiKey"]
            .filter { KeychainStore.has(account: $0) }.count
        KeychainStore.deleteAll()
        LocalAPIManager.shared.clearCachedCredentialsForWipe()
        r.keychainItemsCleared += webKeysBefore
        let bridgeClients = BridgePairingStore.shared.clients().count
        BridgePairingStore.shared.deleteAll()
        r.keychainItemsCleared += bridgeClients

        // Refresh in-memory caches that mirror disk state
        ModelDownloadCenter.shared.refreshAllStates()

        return r
    }

    /// Allocated size of a directory in bytes, or 0 on failure.
    private static func dirSize(at url: URL) -> Int64 {
        (try? FileManager.default.allocatedSizeOfDirectory(at: url)) ?? 0
    }
}
