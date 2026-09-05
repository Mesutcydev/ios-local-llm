import XCTest
@testable import IOSLocalLLM

/// Guards the shipped model catalog. Every entry drives a multi-gigabyte
/// download, so the invariants that make a pack loadable — a subtree prefix,
/// a real measured size, a resolvable direct URL — are checked here rather
/// than discovered on device after the bytes are already spent.
///
/// These are pure checks against the compiled catalog; no network access.
final class CoreAIZooCatalogTests: XCTestCase {

    private var catalog: [CoreAIZooModel] { CoreAIZooCatalog.iphoneLanguageModels }

    func testCatalogIsNotEmpty() {
        XCTAssertGreaterThanOrEqual(catalog.count, 20)
    }

    func testIdentifiersAreUnique() {
        let ids = catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate catalog id would collide in the download center")
    }

    /// A download manager is keyed by id, and the repo+prefix pair is what it
    /// actually fetches. Two entries pointing at the same tree would show two
    /// cards installing identical bytes.
    func testRepoAndPrefixPairsAreUnique() {
        let pairs = catalog.map { "\($0.hfRepo)#\($0.pathPrefix ?? "")" }
        XCTAssertEqual(Set(pairs).count, pairs.count)
    }

    /// Every one of these repos ships several platform trees side by side.
    /// A nil prefix would enumerate the whole repo and pull tens of gigabytes.
    func testEveryEntryScopesToASubtree() {
        for model in catalog {
            let prefix = model.pathPrefix ?? ""
            XCTAssertFalse(
                prefix.isEmpty,
                "\(model.id) has no pathPrefix and would download the entire repo"
            )
            XCTAssertFalse(prefix.hasPrefix("/"), "\(model.id) prefix must be repo-relative")
            XCTAssertFalse(prefix.hasSuffix("/"), "\(model.id) prefix must not carry a trailing slash")
        }
    }

    /// Sizes are measured subtree byte counts, not estimates. A zero or
    /// obviously-rounded value means the entry was not audited.
    func testSizesAreMeasuredAndPlausible() {
        for model in catalog {
            XCTAssertGreaterThan(
                model.approxDownloadBytes, 100_000_000,
                "\(model.id) size is too small to be a real Core AI pack"
            )
            XCTAssertLessThan(
                model.approxDownloadBytes, 8_000_000_000,
                "\(model.id) is too large for an iPhone install"
            )
        }
    }

    func testMacOnlySizedPacksAreExcluded() {
        // The zoo's Mac-only ports (27B dense, 35B MoE) all exceed this bound;
        // catching the size is how an accidental paste of a macOS tree is caught.
        for model in catalog {
            XCTAssertLessThanOrEqual(
                model.approxDownloadBytes, 6_000_000_000,
                "\(model.id) looks like a Mac-only tree"
            )
        }
    }

    func testMetadataFieldsArePopulated() {
        for model in catalog {
            XCTAssertFalse(model.displayName.isEmpty, "\(model.id) needs a display name")
            XCTAssertFalse(model.subtitle.isEmpty, "\(model.id) needs a subtitle")
            XCTAssertFalse(model.licenseNotice.isEmpty, "\(model.id) must carry a license notice")
            XCTAssertEqual(model.revision, "main", "\(model.id): pin revisions deliberately, not by accident")
            XCTAssertGreaterThanOrEqual(model.contextWindow, 448, "\(model.id) context window looks wrong")
        }
    }

    /// The repo id is interpolated into a Hugging Face URL by the downloader.
    /// A value with a space or a second slash silently produces a 404 later.
    func testRepoIDsAreWellFormed() {
        for model in catalog {
            let parts = model.hfRepo.split(separator: "/")
            XCTAssertEqual(parts.count, 2, "\(model.id) repo must be owner/name")
            XCTAssertFalse(model.hfRepo.contains(" "), "\(model.id) repo contains a space")
        }
    }

    /// `hubURL` and `treeURL` are force-unwrap-free but still must resolve to
    /// the real Hub host, and the tree URL must include the subtree.
    func testLinksResolveToTheExactSubtree() {
        for model in catalog {
            XCTAssertEqual(model.hubURL.host, "huggingface.co", "\(model.id) hub link")
            XCTAssertTrue(
                model.hubURL.absoluteString.hasSuffix(model.hfRepo),
                "\(model.id) hub link should point at the repo root"
            )
            let tree = model.treeURL.absoluteString
            XCTAssertTrue(tree.contains("/tree/\(model.revision)"), "\(model.id) tree link")
            if let prefix = model.pathPrefix, !prefix.isEmpty {
                XCTAssertTrue(tree.hasSuffix(prefix), "\(model.id) tree link must end at the subtree")
            }
        }
    }

    func testCategoriesPartitionTheCatalog() {
        let grouped = CoreAIZooCatalog.populatedCategories
            .flatMap { CoreAIZooCatalog.models(in: $0) }
        XCTAssertEqual(grouped.count, catalog.count, "Every entry must fall in exactly one shown category")
        XCTAssertEqual(Set(grouped.map(\.id)), Set(catalog.map(\.id)))
    }

    func testEachCategoryHasEntriesAndCopy() {
        for category in CoreAIZooCatalog.populatedCategories {
            XCTAssertFalse(CoreAIZooCatalog.models(in: category).isEmpty)
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.detail.isEmpty)
        }
    }

    /// Within a category the list is offered smallest-first so the cheapest
    /// working download is the first thing a new operator sees.
    func testEachCategoryIsOrderedSmallestFirst() {
        for category in CoreAIZooCatalog.populatedCategories {
            let sizes = CoreAIZooCatalog.models(in: category).map(\.approxDownloadBytes)
            XCTAssertEqual(sizes, sizes.sorted(), "\(category.rawValue) is not smallest-first")
        }
    }

    func testOfficialRecipeEntriesUseTheIOSTree() {
        let official = CoreAIZooCatalog.models(in: .officialRecipe)
        XCTAssertFalse(official.isEmpty)
        for model in official {
            XCTAssertTrue(
                model.hfRepo.hasSuffix("-official"),
                "\(model.id) is filed as an official recipe but the repo is not"
            )
            XCTAssertEqual(model.pathPrefix, "ios", "\(model.id) official recipes ship the ios/ tree")
        }
    }

    /// The utility packs are embedding / transcription models. Advertising
    /// tools or thinking on them would misreport them to API clients.
    func testUtilityPacksDoNotClaimChatCapabilities() {
        for model in CoreAIZooCatalog.models(in: .utility) {
            XCTAssertFalse(model.supportsTools, "\(model.id) is not a chat model")
            XCTAssertFalse(model.supportsThinking, "\(model.id) is not a chat model")
        }
    }

    func testSmallestOfferedPackIsTheOfficialQwen3() {
        let smallest = catalog.min { $0.approxDownloadBytes < $1.approxDownloadBytes }
        XCTAssertEqual(smallest?.id, "zoo-qwen3-0.6b-official-ios")
    }

    // MARK: - Workbench Assistant integration

    func testChatPacksAdaptToTheCoreAIRuntime() {
        for source in catalog where source.category == .officialRecipe || source.category == .chat {
            let model = source.assistantModel
            XCTAssertEqual(model.id, "coreai:\(source.id)")
            XCTAssertEqual(model.repoID, source.hfRepo)
            XCTAssertEqual(model.runtime, .coreAI)
            XCTAssertEqual(model.downloadSizeBytes, source.approxDownloadBytes)
            XCTAssertEqual(model.contextWindowTokens, source.contextWindow)
            XCTAssertEqual(
                ModelExecutionLocation.of(assistantModelID: model.id),
                .localCoreAI
            )
        }
    }

    func testAssistantCatalogResolvesCoreAISelectionIDs() {
        for source in catalog where source.category == .officialRecipe || source.category == .chat {
            let resolved = AssistantModelCatalog.model(forID: source.assistantSelectionID)
            XCTAssertEqual(resolved?.id, source.assistantSelectionID)
            XCTAssertEqual(resolved?.runtime, .coreAI)
        }
    }

    func testUtilityAndVisionPacksAreNotAssistantChoices() {
        for source in catalog where source.category == .utility || source.category == .vision {
            XCTAssertNil(
                CoreAIZooCatalog.assistantModel(forSelectionID: source.assistantSelectionID)
            )
        }
    }

    // MARK: - Text-generation classification

    /// Auto-load after install must only fire for packs the text runtime can
    /// actually serve; an embedding/ASR pack would land in `.failed` and read
    /// as a broken download.
    func testUtilityPacksAreNotClassifiedAsTextGeneration() {
        for model in catalog where model.category == .utility || model.category == .vision {
            XCTAssertFalse(
                CoreAIZooCatalog.isTextGenerationPack(id: model.id),
                "\(model.id) must not auto-load into the text runtime"
            )
        }
    }

    func testModelsRequiringStaticInputProvidersAreNotAdvertised() {
        XCTAssertNil(CoreAIZooCatalog.model(id: "zoo-gemma4-e2b"))
        XCTAssertFalse(CoreAIZooCatalog.isTextGenerationPack(id: "zoo-gemma4-e2b"))
        XCTAssertFalse(CoreAIZooCatalog.isTextGenerationPack(id: "coreai:zoo-gemma4-e2b"))
        XCTAssertFalse(catalog.contains { $0.pathPrefix?.contains("_tbl") == true })
    }

    func testChatAndOfficialPacksAreClassifiedAsTextGeneration() {
        for category in [CoreAIZooModel.Category.officialRecipe, .chat] {
            for model in CoreAIZooCatalog.models(in: category) {
                XCTAssertTrue(
                    CoreAIZooCatalog.isTextGenerationPack(id: model.id),
                    "\(model.id) should auto-load"
                )
            }
        }
    }

    /// A hand-entered Hub repo has no catalog entry; assuming chat is the
    /// useful default and matches what the search row downloads.
    func testUnknownIDsDefaultToTextGeneration() {
        XCTAssertTrue(CoreAIZooCatalog.isTextGenerationPack(id: "hf:someone/Some-Model#"))
        XCTAssertNil(CoreAIZooCatalog.model(id: "hf:someone/Some-Model#"))
    }

    func testModelLookupByIDResolvesEveryEntry() {
        for model in catalog {
            XCTAssertEqual(CoreAIZooCatalog.model(id: model.id)?.hfRepo, model.hfRepo)
        }
    }
}
