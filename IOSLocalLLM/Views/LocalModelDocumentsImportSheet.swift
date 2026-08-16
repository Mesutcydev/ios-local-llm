import SwiftUI
import UIKit

/// Sideload-proof folder/file import: pick model content already inside the
/// app sandbox (copied via Files / Finder with UIFileSharingEnabled).
struct LocalModelDocumentsImportSheet: View {
    /// Display name shown in the empty-state copy (Files → On My iPhone → …).
    var appDocumentsName: String = "OnDevice LLM"
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [URL] = []
    @State private var files: [URL] = []

    private var isEmpty: Bool { folders.isEmpty && files.isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
                    ContentUnavailableView(
                        "No model files found",
                        systemImage: "folder",
                        description: Text(
                            "In the Files app, copy your model folder or model file into \(appDocumentsName) (On My iPhone), then return here."
                        )
                    )
                } else {
                    List {
                        if !folders.isEmpty {
                            Section("Model folders") {
                                ForEach(folders, id: \.path) { url in
                                    row(for: url, symbol: "folder.fill")
                                }
                            }
                        }
                        if !files.isEmpty {
                            Section("Model files") {
                                ForEach(files, id: \.path) { url in
                                    row(for: url, symbol: "doc.fill")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("App Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh app documents")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    openDocumentsInFiles()
                } label: {
                    Label("Show in Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
            .onAppear {
                refresh()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification
                )
            ) { _ in
                // The user just returned from the Files app after copying
                // model content in — re-scan before they tap anything.
                refresh()
            }
        }
    }

    private func refresh() {
        folders = LocalModelDocumentsScanner.candidateModelFolders()
        files = LocalModelDocumentsScanner.candidateModelFiles()
    }

    private func row(for url: URL, symbol: String) -> some View {
        Button {
            onPick(url)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
            }
        }
        .tint(.primary)
    }

    /// Deep-links into the Files app scoped to this app's shared Documents
    /// folder (UIFileSharingEnabled), so the user can paste model content in
    /// without hunting for "On My iPhone".
    private func openDocumentsInFiles() {
        guard let url = URL(string: "shareddocuments:///") else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - App Documents browser (sideload-proof folder import)

/// Lists model-looking folders already inside the app sandbox (Files /
/// Finder sharing via `UIFileSharingEnabled`). Does not use
/// `UIDocumentPicker`, so it keeps working after common resign/sideload
/// tooling that breaks open-in-place folder picks.
enum LocalModelDocumentsScanner {
    static func candidateModelFolders() -> [URL] {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let skipNames: Set<String> = [
            "HFModels", "LLMModels", "huggingface", "FastVLMModels",
            "VoiceModels", "BundledVoiceModels", "conversations",
            "Inbox", ".Trash", "CoreAIModels"
        ]

        var results: [URL] = []
        func consider(_ dir: URL) {
            if isModelRoot(dir) {
                results.append(dir)
                return
            }
            // One level of nesting (AirDrop / Finder wrappers / ios/).
            guard let kids = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for kid in kids {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: kid.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                if isModelRoot(kid) {
                    results.append(kid)
                } else if isModelRoot(kid.appendingPathComponent("resources", isDirectory: true)) {
                    results.append(kid.appendingPathComponent("resources", isDirectory: true))
                } else if isModelRoot(kid.appendingPathComponent("ios", isDirectory: true)) {
                    results.append(kid.appendingPathComponent("ios", isDirectory: true))
                }
            }
            // Also accept `<dir>/resources` or `<dir>/ios` directly.
            let resources = dir.appendingPathComponent("resources", isDirectory: true)
            if isModelRoot(resources) { results.append(resources) }
            let ios = dir.appendingPathComponent("ios", isDirectory: true)
            if isModelRoot(ios) { results.append(ios) }
        }

        // Top-level Documents entries
        if let entries = try? fm.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                if skipNames.contains(entry.lastPathComponent) { continue }
                consider(entry)
            }
        }

        // Inbox (Files "Copy to …")
        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                    consider(entry)
                }
            }
        }

        var seen = Set<String>()
        return results
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }

    /// Extensions for complete single model files the App Documents flow can
    /// import without any document-picker interaction.
    static let looseModelFileExtensions: Set<String> = [
        "gguf", "safetensors", "bin", "onnx", "npz", "aimodel", "mlmodel"
    ]

    /// Loose model files already inside the app sandbox (Documents or the
    /// Files "Copy to …" Inbox). Complements `candidateModelFolders()` so
    /// App Documents can serve both import kinds on sideload builds where
    /// the system picker is unusable.
    static func candidateModelFiles() -> [URL] {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let roots = [docs, docs.appendingPathComponent("Inbox", isDirectory: true)]
        var results: [URL] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                guard looseModelFileExtensions.contains(
                    entry.pathExtension.lowercased()
                ) else { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir),
                      !isDir.boolValue else { continue }
                results.append(entry)
            }
        }
        var seen = Set<String>()
        return results
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }

    private static func isModelRoot(_ dir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // Directory-bundle packages are model roots themselves.
        let packageExtensions: Set<String> = ["aimodel", "aimodelc", "mlpackage", "mlmodelc"]
        if packageExtensions.contains(dir.pathExtension.lowercased()) {
            return true
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) {
            return true
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("metadata.json").path) {
            return true
        }
        // Any .gguf / .aimodel at this level counts as a complete artifact folder.
        guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return false
        }
        return kids.contains {
            let ext = $0.pathExtension.lowercased()
            return ext == "gguf" || ext == "aimodel" || ext == "aimodelc"
                || ext == "mlpackage" || ext == "mlmodelc"
        }
    }
}
