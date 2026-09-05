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
    }

    static func wipeAll() -> Receipt {
        var r = Receipt()
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]

        // 1. Models (HF + FastVLM + Voice + GGUF)
        for sub in ["HFModels", "FastVLMModels", "LLMModels", "VoiceModels", "GGUFModels"] {
            let url = docs.appendingPathComponent(sub, isDirectory: true)
            r.bytesFreed += dirSize(at: url)
            if fm.fileExists(atPath: url.path) {
                let count = (try? fm.contentsOfDirectory(atPath: url.path).count) ?? 0
                r.modelsDeleted += count
                try? fm.removeItem(at: url)
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
            try? fm.removeItem(at: root)
        }

        // 2b. Apple Core AI resource packs live in Application Support, not
        // Documents/Hub. Without this, "Wipe all" left the largest and most
        // privacy-sensitive new model tree behind.
        let coreAIRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoreAIModels", isDirectory: true)
        if fm.fileExists(atPath: coreAIRoot.path) {
            r.bytesFreed += dirSize(at: coreAIRoot)
            r.modelsDeleted += (try? fm.contentsOfDirectory(atPath: coreAIRoot.path).count) ?? 0
            try? fm.removeItem(at: coreAIRoot)
        }

        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for sub in ["KnowledgeBase", "Registry"] {
            let url = support.appendingPathComponent(sub, isDirectory: true)
            if fm.fileExists(atPath: url.path) {
                r.bytesFreed += dirSize(at: url)
                try? fm.removeItem(at: url)
            }
        }
        KnowledgeBaseService.shared.wipeFromDisk()
        InstalledModelRegistry.shared.wipe()
        PersonaStore.shared.resetForWipe()

        // 3. Conversations (ConversationStore writes JSON to Documents)
        let conv = docs.appendingPathComponent("conversations.json")
        if fm.fileExists(atPath: conv.path) {
            // Count items first
            if let data = try? Data(contentsOf: conv),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                r.conversationsDeleted = arr.count
            }
            try? fm.removeItem(at: conv)
        }
        // Clear the in-memory store too (and cancel its pending debounced
        // save). Otherwise a later flush() on scene-phase background would
        // rewrite conversations.json AND re-index the just-wiped chats back
        // into Spotlight from memory, silently undoing steps 3 and 6.
        ConversationStore.shared.clearAllForWipe()

        // 4. Snippets, memory, benchmark history, metrickit entries
        let defaults = UserDefaults.standard
        let keysToWipe = [
            "ioslocalllm.snippets.v1",
            "ioslocalllm.memory.v1",
            "ioslocalllm.benchmark.history.v1",
            "ioslocalllm.metrickit.entries.v1",
            "ioslocalllm.recentPrompts",
        ]
        // Snippet / memory counts (best-effort)
        if let snipData = defaults.data(forKey: "ioslocalllm.snippets.v1"),
           let snips = try? JSONSerialization.jsonObject(with: snipData) as? [Any] {
            r.snippetsDeleted = snips.count
        }
        if let memData = defaults.data(forKey: "ioslocalllm.memory.v1"),
           let mems = try? JSONSerialization.jsonObject(with: memData) as? [Any] {
            r.memoriesDeleted = mems.count
        }
        for k in keysToWipe { defaults.removeObject(forKey: k) }

        // 5. Reset onboarding + model-pick flags so the next launch feels
        //    like a fresh install.
        let settingsKeys = [
            "hasSeenOnboarding",
            "hasPickedAssistantModel",
            "voiceConversationModelID",
            "assistantModelID",
            "CoreAI.installedVersion",
            "cameraVisualModelID",
            "sttProvider",
            "iCloudSyncEnabled",
            "userPersonas.v1",
            "activePersonaID",
            "knowledgeBase.enabled",
        ]
        for k in settingsKeys { defaults.removeObject(forKey: k) }
        r.settingsCleared = true

        // 6. CoreSpotlight index. Chats were indexed (title + first ~200 chars
        //    of the first message). Deleting conversations.json does NOT remove
        //    them from system Spotlight, so wiped chats stayed searchable from
        //    the home screen — defeating the privacy purpose of this button.
        CSSearchableIndex.default().deleteAllSearchableItems { _ in }

        // 7. App Group staged share files (SharedImages / SharedText) the share
        //    extension wrote but the app may not have consumed — otherwise this
        //    user content survives a full wipe.
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: AppBridge.appGroupID) {
            for sub in ["SharedImages", "SharedText"] {
                let url = group.appendingPathComponent(sub, isDirectory: true)
                r.bytesFreed += dirSize(at: url)
                try? fm.removeItem(at: url)
            }
        }

        // 8. Keychain credentials — HF token, web search API keys, Mac Bridge
        //    bearer tokens. These survive a file-only wipe unless cleared here.
        if HFTokenStore.shared.clear() { r.keychainItemsCleared += 1 }
        let webKeysBefore = ["brave.apiKey", "tavily.apiKey", "exa.apiKey"]
            .filter { KeychainStore.has(account: $0) }.count
        KeychainStore.deleteAll()
        r.keychainItemsCleared += webKeysBefore
        let bridgeClients = BridgePairingStore.shared.clients().count
        BridgePairingStore.shared.deleteAll()
        r.keychainItemsCleared += bridgeClients

        // Refresh in-memory caches that mirror disk state
        ModelDownloadCenter.shared.refreshAllStates()
        CoreAIModelStore.shared.refresh()

        return r
    }

    /// Allocated size of a directory in bytes, or 0 on failure.
    private static func dirSize(at url: URL) -> Int64 {
        (try? FileManager.default.allocatedSizeOfDirectory(at: url)) ?? 0
    }
}
