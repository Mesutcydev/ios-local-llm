import Foundation

struct CoreAIModelCapabilities: Codable, Equatable, Sendable {
    let textGeneration: Bool
    let streaming: Bool
    let multiTurn: Bool
    let imageInput: Bool
    let guidedGeneration: Bool
    let toolCalling: Bool
    let reasoning: Bool
    let concurrentExecution: Bool
}

struct CoreAIExpectedModelFile: Codable, Equatable, Sendable {
    let relativePath: String
    let byteCount: Int64?
    let sha256: String?
}

struct CoreAIModelManifest: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let version: String
    let modelFamily: String
    let assetPackID: String
    let expectedFiles: [CoreAIExpectedModelFile]
    let totalDownloadBytes: Int64
    let minimumOSVersion: String
    let supportedDeviceFamilies: [String]
    let supportedArchitectures: [String]
    let contextWindow: Int
    let maximumOutputTokens: Int
    let capabilities: CoreAIModelCapabilities
    let tokenizerIdentifier: String?
    let licenseNotice: String
}

struct CoreAIInstalledModel: Identifiable, Equatable, Sendable {
    let installationURL: URL
    let resourcesURL: URL
    let manifest: CoreAIModelManifest

    var id: String { manifest.id }

    var assistantSelectionID: String {
        Self.assistantSelectionID(for: manifest.id)
    }

    static func assistantSelectionID(for manifestID: String) -> String {
        manifestID.hasPrefix("coreai:") ? manifestID : "coreai:\(manifestID)"
    }

    var assistantModel: AssistantModel? {
        // Catalog classification is authoritative, including for packs that
        // were installed by an older build whose generated manifest marked
        // every .aimodel bundle as text generation. This keeps vision,
        // embedding, and transcription assets out of the Assistant picker.
        guard CoreAIZooCatalog.isTextGenerationPack(id: manifest.id) else { return nil }
        if CoreAIZooCatalog.model(forSelectionID: manifest.id) != nil {
            return CoreAIZooCatalog.assistantModel(forSelectionID: manifest.id)
        }
        guard manifest.capabilities.textGeneration else { return nil }
        var capabilities: Set<ModelCapability> = []
        if manifest.capabilities.reasoning { capabilities.insert(.thinking) }
        if manifest.capabilities.toolCalling { capabilities.insert(.tools) }
        if manifest.capabilities.imageInput { capabilities.insert(.vision) }
        return AssistantModel(
            id: assistantSelectionID,
            repoID: Self.repoID(from: manifest.assetPackID),
            displayName: manifest.displayName,
            subtitle: "Core AI · installed on device",
            approxRAMBytes: manifest.totalDownloadBytes + 500_000_000,
            tags: ["core-ai"],
            contextWindowTokens: manifest.contextWindow,
            downloadSizeBytes: manifest.totalDownloadBytes,
            capabilities: capabilities,
            supportsTools: manifest.capabilities.toolCalling,
            runtime: .coreAI
        )
    }

    private static func repoID(from assetPackID: String) -> String {
        let withoutPrefix = assetPackID.hasPrefix("hf:")
            ? String(assetPackID.dropFirst("hf:".count))
            : assetPackID
        return withoutPrefix.split(separator: "#", maxSplits: 1).first.map(String.init)
            ?? assetPackID
    }
}

/// Installation boundary for Core AI asset packs. A pack may contain one or
/// more `.aimodel` resources, tokenizers, metadata, and AOT artifacts.
@MainActor
final class CoreAIModelStore: ObservableObject {
    static let shared = CoreAIModelStore()
    nonisolated static let defaultModelID = "coreai-qwen3-0.6b"
    private static let installedVersionKey = "CoreAI.installedVersion"

    enum State: Equatable {
        case unavailable(String)
        case missing
        case downloading
        case validating
        case ready(URL, CoreAIModelManifest)
        case failed(String)
    }

    @Published private(set) var state: State = .missing
    @Published private(set) var installations: [CoreAIInstalledModel] = []
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let modelDirectoryOverride: URL?

    var modelDirectory: URL {
        modelDirectoryOverride
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoreAIModels", isDirectory: true)
    }

    var installationURL: URL? {
        guard case .ready(let url, _) = state else { return nil }
        return url
    }

    var modelResourcesURL: URL? {
        guard let installationURL else { return nil }
        return installations.first {
            $0.installationURL.standardizedFileURL == installationURL.standardizedFileURL
        }?.resourcesURL
    }

    var manifest: CoreAIModelManifest? {
        guard case .ready(_, let manifest) = state else { return nil }
        return manifest
    }

    init(
        fileManager: FileManager = .default,
        modelDirectory: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.modelDirectoryOverride = modelDirectory
        self.defaults = defaults
        refresh()
    }

    func refresh() {
        guard #available(iOS 27.0, *) else {
            installations = []
            state = .unavailable("Core AI requires iOS 27 or later.")
            return
        }
        installations = discoverInstallations()
        MemoryAdvisor.invalidateFootprintCache()
        guard !installations.isEmpty else {
            defaults.removeObject(forKey: Self.installedVersionKey)
            state = .missing
            return
        }
        let selectedVersion = defaults.string(forKey: Self.installedVersionKey)
        let selected = installations.first {
            $0.installationURL.lastPathComponent == selectedVersion
        } ?? installations[0]
        defaults.set(selected.installationURL.lastPathComponent, forKey: Self.installedVersionKey)
        state = .ready(selected.installationURL, selected.manifest)
    }

    func installedModel(id: String) -> CoreAIInstalledModel? {
        let rawID = id.hasPrefix("coreai:") ? String(id.dropFirst("coreai:".count)) : id
        return installations.first {
            let installedID = $0.manifest.id.hasPrefix("coreai:")
                ? String($0.manifest.id.dropFirst("coreai:".count))
                : $0.manifest.id
            return installedID == rawID
        }
    }

    func installedAssistantModels() -> [AssistantModel] {
        installations.compactMap(\.assistantModel)
    }

    @discardableResult
    func selectModel(id: String) throws -> CoreAIInstalledModel {
        refresh()
        guard let installed = installedModel(id: id) else {
            throw CoreAIModelStoreError.notInstalled
        }
        defaults.set(
            installed.installationURL.lastPathComponent,
            forKey: Self.installedVersionKey
        )
        state = .ready(installed.installationURL, installed.manifest)
        return installed
    }

    func importModel(from sourceURL: URL) throws {
        try importModel(from: sourceURL, preferredID: nil, preferredDisplayName: nil)
    }

    func importModel(
        from sourceURL: URL,
        preferredID: String?,
        preferredDisplayName: String?
    ) throws {
        let previouslySelectedID = manifest?.id
        state = .validating
        do {
            try performImport(
                from: sourceURL,
                preferredID: preferredID,
                preferredDisplayName: preferredDisplayName,
                previouslySelectedID: previouslySelectedID
            )
        } catch {
            refresh()
            // Preserve a previously installed pack; otherwise surface the error.
            if case .ready = state {} else {
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    private func performImport(
        from sourceURL: URL,
        preferredID: String?,
        preferredDisplayName: String?,
        previouslySelectedID: String?
    ) throws {
        let staging = modelDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let resources = staging.appendingPathComponent("resources", isDirectory: true)
        let isDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDirectory {
            // Users often pick the Hub checkout root (`…/ios`, or a wrapper
            // that still contains `resources/`). Copy the resolved pack root
            // so metadata.json + .aimodel land directly under `resources/`.
            let packRoot = try Self.resolvePackRoot(from: sourceURL, fileManager: fileManager)
            try fileManager.copyItem(at: packRoot, to: resources)
        } else {
            let ext = sourceURL.pathExtension.lowercased()
            guard ext == "aimodel" || ext == "aimodelc" else {
                throw CoreAIModelStoreError.invalidExtension
            }
            try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
            try fileManager.copyItem(
                at: sourceURL,
                to: resources.appendingPathComponent(sourceURL.lastPathComponent)
            )
        }

        let manifest = try loadOrCreateManifest(
            in: resources,
            preferredID: preferredID,
            preferredDisplayName: preferredDisplayName
        )
        try validate(manifest: manifest, resourcesAt: resources)
        let destination = modelDirectory.appendingPathComponent(manifest.version, isDirectory: true)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)

        // Reinstalling the same catalog identity replaces only that identity.
        // Other downloaded Core AI packs remain selectable in the library.
        for old in installations where old.manifest.id == manifest.id {
            if old.installationURL.standardizedFileURL != destination.standardizedFileURL {
                try? fileManager.removeItem(at: old.installationURL)
            }
        }
        defaults.set(manifest.version, forKey: Self.installedVersionKey)
        refresh()
        if let previouslySelectedID,
           previouslySelectedID != manifest.id,
           installedModel(id: previouslySelectedID) != nil {
            try selectModel(id: previouslySelectedID)
        }
    }

    /// Prefer the directory that actually contains Core AI resources.
    /// Accepts a bare resource tree, `resources/`, or `ios/`.
    private static func resolvePackRoot(
        from sourceURL: URL,
        fileManager fm: FileManager = .default
    ) throws -> URL {
        func hasModelFiles(_ url: URL) -> Bool {
            !((try? collectModelFiles(in: url)) ?? []).isEmpty
        }
        func isBundleRoot(_ url: URL) -> Bool {
            let metadata = url.appendingPathComponent("metadata.json")
            return fm.fileExists(atPath: metadata.path) && hasModelFiles(url)
        }

        if isBundleRoot(sourceURL) {
            return sourceURL
        }
        let resources = sourceURL.appendingPathComponent("resources", isDirectory: true)
        if isBundleRoot(resources) {
            return resources
        }
        let ios = sourceURL.appendingPathComponent("ios", isDirectory: true)
        if isBundleRoot(ios) {
            return ios
        }

        var candidates: [URL] = []
        if let enumerator = fm.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.lastPathComponent == "metadata.json" {
                let candidate = url.deletingLastPathComponent()
                let ext = candidate.pathExtension.lowercased()
                guard ext != "aimodel", ext != "aimodelc", isBundleRoot(candidate) else {
                    continue
                }
                candidates.append(candidate)
            }
        }
        let unique = Dictionary(
            grouping: candidates,
            by: { $0.standardizedFileURL.path }
        ).values.compactMap(\.first)
        guard unique.count == 1, let root = unique.first else {
            if unique.count > 1 { throw CoreAIModelStoreError.ambiguousBundleRoot }
            throw CoreAIModelStoreError.missingMetadata
        }
        return root
    }

    func removeModel() throws {
        guard let id = manifest?.id else { return }
        try removeModel(id: id)
    }

    func removeModel(id: String) throws {
        refresh()
        guard let installed = installedModel(id: id) else {
            throw CoreAIModelStoreError.notInstalled
        }
        try fileManager.removeItem(at: installed.installationURL)
        if installationURL?.standardizedFileURL == installed.installationURL.standardizedFileURL {
            defaults.removeObject(forKey: Self.installedVersionKey)
        }
        refresh()
    }

    func removeAllModels() throws {
        if fileManager.fileExists(atPath: modelDirectory.path) {
            try fileManager.removeItem(at: modelDirectory)
        }
        defaults.removeObject(forKey: Self.installedVersionKey)
        refresh()
    }

    private func discoverInstallations() -> [CoreAIInstalledModel] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return children.compactMap { root -> (CoreAIInstalledModel, Date)? in
            guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let installed = try? loadInstallation(at: root) else {
                return nil
            }
            let modified = (try? root.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            return (installed, modified)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.manifest.displayName.localizedCaseInsensitiveCompare(
                $1.0.manifest.displayName
            ) == .orderedAscending
        }
        .map(\.0)
    }

    private func loadInstallation(at root: URL) throws -> CoreAIInstalledModel {
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        let manifestURL = resources.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CoreAIModelManifest.self, from: data)
        if (try? validate(manifest: manifest, resourcesAt: resources)) != nil {
            return CoreAIInstalledModel(
                installationURL: root,
                resourcesURL: resources,
                manifest: manifest
            )
        }

        // Migration for packs installed by 1.0: broad catalog prefixes such
        // as `gpu-pipelined/` were saved with several sibling bundles below
        // `resources/`. Keep those bytes and resolve the exact catalog bundle
        // rather than making the user download gigabytes again.
        let nested: URL
        if let catalog = CoreAIZooCatalog.model(id: manifest.id),
           let leaf = catalog.pathPrefix?.split(separator: "/").last {
            let candidate = resources.appendingPathComponent(String(leaf), isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) {
                nested = candidate
            } else {
                nested = try Self.resolvePackRoot(from: resources, fileManager: fileManager)
            }
        } else {
            nested = try Self.resolvePackRoot(from: resources, fileManager: fileManager)
        }
        try validate(manifest: manifest, resourcesAt: nested)
        return CoreAIInstalledModel(
            installationURL: root,
            resourcesURL: nested,
            manifest: manifest
        )
    }

    private func loadOrCreateManifest(
        in resources: URL,
        preferredID: String? = nil,
        preferredDisplayName: String? = nil
    ) throws -> CoreAIModelManifest {
        let manifestURL = resources.appendingPathComponent("manifest.json")
        if fileManager.fileExists(atPath: manifestURL.path) {
            return try JSONDecoder().decode(CoreAIModelManifest.self, from: Data(contentsOf: manifestURL))
        }
        let modelFiles = try Self.collectModelFiles(in: resources)
        guard !modelFiles.isEmpty else { throw CoreAIModelStoreError.missingModelResource }
        let relative = modelFiles.map { file -> String in
            let full = file.standardizedFileURL.path
            let root = resources.standardizedFileURL.path
            if full.hasPrefix(root + "/") {
                return String(full.dropFirst(root.count + 1))
            }
            return file.lastPathComponent
        }
        let totalBytes = Self.recursiveFileBytes(in: resources)
        let manifestID = preferredID ?? Self.defaultModelID
        let catalogModel = CoreAIZooCatalog.model(forSelectionID: manifestID)
        let supportsTextGeneration = CoreAIZooCatalog.isTextGenerationPack(id: manifestID)
        let manifest = CoreAIModelManifest(
            id: manifestID,
            displayName: preferredDisplayName ?? "Core AI model",
            version: UUID().uuidString,
            modelFamily: preferredDisplayName ?? "custom",
            assetPackID: preferredID ?? Self.defaultModelID,
            expectedFiles: relative.map {
                CoreAIExpectedModelFile(relativePath: $0, byteCount: nil, sha256: nil)
            },
            totalDownloadBytes: totalBytes,
            minimumOSVersion: "27.0",
            supportedDeviceFamilies: ["iPhone"],
            supportedArchitectures: ["arm64"],
            contextWindow: catalogModel?.contextWindow ?? 32_768,
            maximumOutputTokens: 2_048,
            capabilities: CoreAIModelCapabilities(
                textGeneration: supportsTextGeneration,
                streaming: supportsTextGeneration,
                multiTurn: supportsTextGeneration,
                imageInput: catalogModel?.category == .vision,
                guidedGeneration: false,
                toolCalling: catalogModel?.supportsTools ?? false,
                reasoning: catalogModel?.supportsThinking ?? false,
                concurrentExecution: false
            ),
            tokenizerIdentifier: nil,
            licenseNotice: catalogModel?.licenseNotice
                ?? "Review the model license before distribution."
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        return manifest
    }

    private static func collectModelFiles(in root: URL) throws -> [URL] {
        var results: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            // Official packs ship `.aimodel` as a directory bundle (main.mlirb +
            // metadata) rather than a single file.
            if ext == "aimodel" || ext == "aimodelc" {
                results.append(url)
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }
            if !isDirectory, url.lastPathComponent.lowercased() == "main.mlirb" {
                results.append(url.deletingLastPathComponent())
                enumerator.skipDescendants()
            }
        }
        // De-dupe directory vs main.mlirb discoveries.
        var seen = Set<String>()
        return results.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func recursiveFileBytes(in root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard values?.isDirectory != true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    private func validate(manifest: CoreAIModelManifest, resourcesAt root: URL) throws {
        guard manifest.minimumOSVersion.hasPrefix("27"),
              manifest.supportedDeviceFamilies.contains(where: {
                  $0.caseInsensitiveCompare("iPhone") == .orderedSame
                      || $0.caseInsensitiveCompare("iphone") == .orderedSame
              }) || manifest.supportedDeviceFamilies.isEmpty else {
            throw CoreAIModelStoreError.unsupportedModel
        }
        // Prefer Apple metadata.json when present — it is the runtime contract.
        let metadata = root.appendingPathComponent("metadata.json")
        let hasMetadata = fileManager.fileExists(atPath: metadata.path)
        let hasTokenizer = fileManager.fileExists(
            atPath: root.appendingPathComponent("tokenizer/tokenizer.json").path
        )
        let hasModelFile = !(try Self.collectModelFiles(in: root)).isEmpty
        if manifest.capabilities.textGeneration {
            guard hasMetadata else { throw CoreAIModelStoreError.missingMetadata }
            guard hasTokenizer else { throw CoreAIModelStoreError.missingTokenizer }
            try validateLanguageMetadata(at: metadata, resourcesAt: root)
            guard hasModelFile else { throw CoreAIModelStoreError.missingModelResource }
            return
        }
        let rootPath = root.standardizedFileURL.path
        for expected in manifest.expectedFiles {
            let candidate = root.appendingPathComponent(expected.relativePath).standardizedFileURL
            guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/"),
                  fileManager.fileExists(atPath: candidate.path),
                  (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw CoreAIModelStoreError.missingModelResource
            }
            if let byteCount = expected.byteCount,
               (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) != byteCount {
                throw CoreAIModelStoreError.invalidManifest
            }
        }
        guard hasModelFile || !manifest.expectedFiles.isEmpty else {
            throw CoreAIModelStoreError.missingModelResource
        }
        _ = hasTokenizer
    }

    private func validateLanguageMetadata(at metadataURL: URL, resourcesAt root: URL) throws {
        struct RuntimeMetadata: Decodable {
            let metadataVersion: String
            let kind: String
            let assets: [String: String]

            enum CodingKeys: String, CodingKey {
                case metadataVersion = "metadata_version"
                case kind, assets
            }
        }

        let metadata: RuntimeMetadata
        do {
            metadata = try JSONDecoder().decode(
                RuntimeMetadata.self,
                from: Data(contentsOf: metadataURL)
            )
        } catch {
            throw CoreAIModelStoreError.invalidRuntimeMetadata
        }
        guard metadata.metadataVersion == "0.2", metadata.kind == "llm",
              let main = metadata.assets["main"] else {
            throw CoreAIModelStoreError.invalidRuntimeMetadata
        }
        let asset = root.appendingPathComponent(main).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard asset.path.hasPrefix(rootPath + "/"),
              fileManager.fileExists(atPath: asset.path) else {
            throw CoreAIModelStoreError.missingModelResource
        }
    }
}

enum CoreAIModelStoreError: LocalizedError, Equatable {
    case invalidExtension
    case notInstalled
    case missingModelResource
    case missingMetadata
    case missingTokenizer
    case ambiguousBundleRoot
    case invalidRuntimeMetadata
    case invalidManifest
    case unsupportedModel

    var errorDescription: String? {
        switch self {
        case .invalidExtension: return "Core AI models must use the .aimodel format."
        case .notInstalled: return "No Core AI model is installed."
        case .missingModelResource: return "The Core AI asset pack is missing a required model resource."
        case .missingMetadata: return "This is not a complete Core AI language bundle: metadata.json is missing."
        case .missingTokenizer: return "This Core AI language bundle is missing tokenizer/tokenizer.json."
        case .ambiguousBundleRoot: return "This download contains multiple Core AI bundles. Choose one exact model folder."
        case .invalidRuntimeMetadata: return "The Core AI metadata.json is invalid or is not a language-model bundle."
        case .invalidManifest: return "The Core AI model manifest is invalid."
        case .unsupportedModel: return "This Core AI model is not supported by this iPhone build."
        }
    }
}
