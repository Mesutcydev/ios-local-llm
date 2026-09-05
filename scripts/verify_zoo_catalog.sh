#!/usr/bin/env bash
# Executes the model-catalog invariants on the Mac.
#
# The app's XCTest bundle cannot run in the Simulator (the CoreAI module is
# device-SDK only), and the catalog is pure Foundation data, so this compiles
# CoreAIZooCatalog.swift for macOS with a checker main and runs it. Same
# invariants as IOSLocalLLMTests/CoreAIZooCatalogTests.swift, actually executed.
#
#   ./scripts/verify_zoo_catalog.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/IOSLocalLLM/Models/CoreAIZooCatalog.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# CoreAIZooCatalog now also adapts entries into the full workbench's
# AssistantModel. The catalog invariants are still pure Foundation, so provide
# minimal compile-time stubs rather than pulling the entire iOS app into this
# Mac executable.
cat > "$WORK/stubs.swift" <<'SWIFT'
import Foundation

enum ModelCapability: Hashable { case thinking, tools, vision }
enum ModelRuntime { case mlx, llamaCpp, coreAI }
struct AssistantModel {
    let id: String
    let repoID: String
    let displayName: String
    let subtitle: String
    let approxRAMBytes: Int64
    let tags: [String]
    let contextWindowTokens: Int
    var downloadSizeBytes: Int64?
    var capabilities: Set<ModelCapability>
    var supportsTools: Bool
    var runtime: ModelRuntime

    init(
        id: String, repoID: String, displayName: String, subtitle: String,
        approxRAMBytes: Int64, tags: [String], contextWindowTokens: Int,
        downloadSizeBytes: Int64? = nil,
        capabilities: Set<ModelCapability> = [],
        supportsTools: Bool = false, runtime: ModelRuntime = .mlx
    ) {
        self.id = id; self.repoID = repoID; self.displayName = displayName
        self.subtitle = subtitle; self.approxRAMBytes = approxRAMBytes
        self.tags = tags; self.contextWindowTokens = contextWindowTokens
        self.downloadSizeBytes = downloadSizeBytes
        self.capabilities = capabilities; self.supportsTools = supportsTools
        self.runtime = runtime
    }
}
SWIFT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

let catalog = CoreAIZooCatalog.iphoneLanguageModels

check(catalog.count >= 20, "catalog has only \(catalog.count) entries")

let ids = catalog.map(\.id)
check(Set(ids).count == ids.count, "duplicate catalog ids")

let pairs = catalog.map { "\($0.hfRepo)#\($0.pathPrefix ?? "")" }
check(Set(pairs).count == pairs.count, "duplicate repo+prefix pairs")

for m in catalog {
    let prefix = m.pathPrefix ?? ""
    check(!prefix.isEmpty, "\(m.id): no pathPrefix — would download the whole repo")
    check(!prefix.hasPrefix("/"), "\(m.id): prefix must be repo-relative")
    check(!prefix.hasSuffix("/"), "\(m.id): prefix has a trailing slash")

    check(m.approxDownloadBytes > 100_000_000, "\(m.id): size too small to be a real pack")
    check(m.approxDownloadBytes <= 6_000_000_000, "\(m.id): looks like a Mac-only tree")

    check(!m.displayName.isEmpty, "\(m.id): empty display name")
    check(!m.subtitle.isEmpty, "\(m.id): empty subtitle")
    check(!m.licenseNotice.isEmpty, "\(m.id): missing license notice")
    check(m.revision == "main", "\(m.id): unexpected revision \(m.revision)")
    check(m.contextWindow >= 448, "\(m.id): implausible context window")

    let parts = m.hfRepo.split(separator: "/")
    check(parts.count == 2, "\(m.id): repo must be owner/name")
    check(!m.hfRepo.contains(" "), "\(m.id): repo contains a space")

    check(m.hubURL.host == "huggingface.co", "\(m.id): bad hub host")
    check(m.hubURL.absoluteString.hasSuffix(m.hfRepo), "\(m.id): hub link is not the repo root")
    let tree = m.treeURL.absoluteString
    check(tree.contains("/tree/\(m.revision)"), "\(m.id): tree link missing revision")
    check(tree.hasSuffix(prefix), "\(m.id): tree link does not end at the subtree")
}

let grouped = CoreAIZooCatalog.populatedCategories.flatMap { CoreAIZooCatalog.models(in: $0) }
check(grouped.count == catalog.count, "categories do not partition the catalog")
check(Set(grouped.map(\.id)) == Set(ids), "category grouping loses entries")

for category in CoreAIZooCatalog.populatedCategories {
    let models = CoreAIZooCatalog.models(in: category)
    check(!models.isEmpty, "\(category.rawValue): shown with no entries")
    check(!category.title.isEmpty, "\(category.rawValue): no title")
    check(!category.detail.isEmpty, "\(category.rawValue): no detail copy")
    let sizes = models.map(\.approxDownloadBytes)
    check(sizes == sizes.sorted(), "\(category.rawValue): not ordered smallest-first")
}

let official = CoreAIZooCatalog.models(in: .officialRecipe)
check(!official.isEmpty, "no official-recipe entries")
for m in official {
    check(m.hfRepo.hasSuffix("-official"), "\(m.id): filed official but repo is not")
    check(m.pathPrefix == "ios", "\(m.id): official recipes ship the ios/ tree")
}

for m in CoreAIZooCatalog.models(in: .utility) {
    check(!m.supportsTools, "\(m.id): utility pack claims tools")
    check(!m.supportsThinking, "\(m.id): utility pack claims thinking")
}

let smallest = catalog.min { $0.approxDownloadBytes < $1.approxDownloadBytes }
check(smallest?.id == "zoo-qwen3-0.6b-official-ios", "unexpected smallest pack: \(smallest?.id ?? "nil")")

// Auto-load classification: non-chat packs must never enter the text runtime.
for category in [CoreAIZooModel.Category.vision, .utility] {
    for m in CoreAIZooCatalog.models(in: category) {
        check(!CoreAIZooCatalog.isTextGenerationPack(id: m.id), "\(m.id): non-chat pack would auto-load")
    }
}
for category in [CoreAIZooModel.Category.officialRecipe, .chat] {
    for m in CoreAIZooCatalog.models(in: category) {
        check(CoreAIZooCatalog.isTextGenerationPack(id: m.id), "\(m.id): chat pack would not auto-load")
    }
}
check(CoreAIZooCatalog.isTextGenerationPack(id: "hf:someone/Some-Model#"),
      "unknown ids should default to text generation")
check(CoreAIZooCatalog.model(id: "zoo-gemma4-e2b") == nil,
      "Gemma 4 static-input-provider bundle must not be advertised as drop-in chat")
check(!CoreAIZooCatalog.isTextGenerationPack(id: "zoo-gemma4-e2b"),
      "withdrawn Gemma 4 identity must not fall through to custom chat")
check(!catalog.contains { $0.pathPrefix?.contains("_tbl") == true },
      "catalog includes a static-table bundle without its required provider")
for m in catalog {
    check(CoreAIZooCatalog.model(id: m.id)?.hfRepo == m.hfRepo, "\(m.id): id lookup failed")
}

// Report
let fmt = ByteCountFormatter()
fmt.countStyle = .file
print("catalog: \(catalog.count) packs across \(CoreAIZooCatalog.populatedCategories.count) categories")
for category in CoreAIZooCatalog.populatedCategories {
    let models = CoreAIZooCatalog.models(in: category)
    let total = models.reduce(Int64(0)) { $0 + $1.approxDownloadBytes }
    print("\n\(category.title)  (\(models.count) packs, \(fmt.string(fromByteCount: total)) total)")
    for m in models {
        let caps = [m.supportsThinking ? "think" : nil, m.supportsTools ? "tools" : nil]
            .compactMap { $0 }.joined(separator: "+")
        print(String(
            format: "  %-34s %10s  %@/%@%@",
            (m.displayName as NSString).utf8String!,
            (fmt.string(fromByteCount: m.approxDownloadBytes) as NSString).utf8String!,
            m.hfRepo,
            m.pathPrefix ?? "",
            caps.isEmpty ? "" : "  [\(caps)]"
        ))
    }
}

if failures.isEmpty {
    print("\nAll catalog invariants hold.")
    exit(0)
}
print("\n\(failures.count) FAILURE(S):")
failures.forEach { print("  - \($0)") }
exit(1)
SWIFT

swiftc -O -o "$WORK/verify" "$WORK/stubs.swift" "$CATALOG" "$WORK/main.swift"
"$WORK/verify"
