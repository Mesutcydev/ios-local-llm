// swift-tools-version: 6.0
import PackageDescription

// App-only, local text runtime. Runtime declarations require iOS 27, while
// the package itself remains importable by the iOS 18 app and Simulator.
let package = Package(
    name: "CoreAITextRuntime",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "CoreAILM", targets: ["CoreAILanguageModels"])],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.0"),
        .package(url: "https://github.com/mlc-ai/xgrammar", revision: "4d145cc13d878c751ebeed36af1c013074be76bc"),
    ],
    targets: [
        .target(name: "CoreAILanguageModels", dependencies: ["CoreAIShared", "CXGrammar", .product(name: "Transformers", package: "swift-transformers")], path: "Sources/CoreAILanguageModels", swiftSettings: [.enableUpcomingFeature("MemberImportVisibility"), .enableExperimentalFeature("Lifetimes")], linkerSettings: [.linkedLibrary("c++")]),
        .target(name: "CoreAIShared", path: "Sources/CoreAIShared", swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
        .target(name: "CXGrammar", dependencies: [.product(name: "XGrammar", package: "xgrammar")], path: "Sources/lib/CXGrammar", publicHeadersPath: "include"),
    ],
    cxxLanguageStandard: .cxx17
)
