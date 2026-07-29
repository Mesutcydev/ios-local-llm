import Foundation

// MARK: - LoRA Adapter model
// Represents a LoRA (Low-Rank Adaptation) adapter that can be loaded
// alongside a base model to modify its behavior without full fine-tuning.

struct LoRAAdapter: Identifiable, Codable, Hashable {
    var id: String           // stable key
    var name: String         // display name
    var repoID: String?      // HuggingFace repo (optional)
    var localPath: String?   // on-device path to adapter weights
    var baseModelID: String  // which base model this adapter targets
    var description: String
    var tags: [String]
    /// Approximate additional RAM for this adapter.
    var approxRAMBytes: Int64
    /// Whether the adapter weights are on-device.
    var isDownloaded: Bool
    /// Source: "huggingface", "local", "user"
    var source: String

    init(
        id: String,
        name: String,
        repoID: String? = nil,
        localPath: String? = nil,
        baseModelID: String,
        description: String = "",
        tags: [String] = [],
        approxRAMBytes: Int64 = 0,
        isDownloaded: Bool = false,
        source: String = "huggingface"
    ) {
        self.id = id
        self.name = name
        self.repoID = repoID
        self.localPath = localPath
        self.baseModelID = baseModelID
        self.description = description
        self.tags = tags
        self.approxRAMBytes = approxRAMBytes
        self.isDownloaded = isDownloaded
        self.source = source
    }
}

// MARK: - LoRA Adapter Store
// Manages the catalog of known LoRA adapters, persisted to UserDefaults.

@MainActor
final class LoRAAdapterStore: ObservableObject {
    static let shared = LoRAAdapterStore()

    @Published private(set) var adapters: [LoRAAdapter] = []

    /// Currently loaded adapter ID (nil = no adapter loaded).
    @Published var activeAdapterID: String? {
        didSet {
            UserDefaults.standard.set(activeAdapterID, forKey: Self.activeKey)
        }
    }

    /// Stack of adapter IDs for multi-LoRA (future). Today only one.
    @Published var activeAdapterIDs: [String] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(activeAdapterIDs) {
                UserDefaults.standard.set(data, forKey: Self.stackKey)
            }
        }
    }

    private static let adaptersKey = "lora.adapters.v1"
    private static let activeKey   = "lora.activeAdapterID"
    private static let stackKey    = "lora.activeAdapterIDs"

    private init() {
        load()
        activeAdapterID = UserDefaults.standard.string(forKey: Self.activeKey)
        if let data = UserDefaults.standard.data(forKey: Self.stackKey),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            activeAdapterIDs = ids
        }
    }

    func add(_ adapter: LoRAAdapter) {
        adapters.removeAll { $0.id == adapter.id }
        adapters.append(adapter)
        save()
    }

    func remove(id: String) {
        adapters.removeAll { $0.id == id }
        if activeAdapterID == id { activeAdapterID = nil }
        activeAdapterIDs.removeAll { $0 == id }
        save()
    }

    func adapter(for id: String) -> LoRAAdapter? {
        adapters.first { $0.id == id }
    }

    /// Returns adapters compatible with the given base model.
    func adapters(forBaseModel baseModelID: String) -> [LoRAAdapter] {
        adapters.filter { $0.baseModelID == baseModelID || $0.baseModelID.isEmpty }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.adaptersKey),
              let decoded = try? JSONDecoder().decode([LoRAAdapter].self, from: data)
        else { return }
        adapters = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(adapters) else { return }
        UserDefaults.standard.set(data, forKey: Self.adaptersKey)
    }
}
