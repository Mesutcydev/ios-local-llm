import SwiftUI
import UIKit

/// Sideload-proof folder/file import: pick model content already inside the
/// app sandbox (copied via Files / Finder with UIFileSharingEnabled).
struct LocalModelDocumentsImportSheet: View {
    /// Display name shown in the empty-state copy (Files → On My iPhone → …).
    var appDocumentsName: String = "On Device: LAS"
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
