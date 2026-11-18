import SwiftUI
import UniformTypeIdentifiers

// MARK: - KnowledgeBaseView
//
// Manage the on-device RAG corpus: add files / pasted text, toggle whether the
// assistant grounds answers in it, and remove documents. Everything is indexed
// and searched locally (NaturalLanguage embeddings) — nothing is uploaded.

struct KnowledgeBaseView: View {
    @ObservedObject private var kb = KnowledgeBaseService.shared
    @Environment(\.koduTheme) private var T
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var pasteName = ""
    @State private var showClearConfirm = false
    @State private var pendingDelete: KBDocument?

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidPinkBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.cardGap) {
                        if !kb.isAvailable { unavailableCard }
                        toggleCard
                        addStrip
                        if kb.isIndexing { indexingRow }
                        documentsList
                    }
                    .padding(Space.m)
                    .padding(.bottom, Space.xl)
                }
            }
            .navigationTitle("Knowledge Base")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
                if !kb.documents.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) { showClearConfirm = true } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Remove all documents")
                    }
                }
            }
            .confirmationDialog(
                "Remove all documents?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove All", role: .destructive) { kb.clear() }
            } message: {
                Text("The whole on-device index is deleted. This can't be undone.")
            }
            .confirmationDialog(
                "Remove \(pendingDelete?.name ?? "document")?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let doc = pendingDelete {
                        kb.removeDocument(doc.id)
                        HapticManager.impact(.light)
                    }
                    pendingDelete = nil
                }
            } message: {
                Text("Its indexed chunks are deleted from this device.")
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.plainText, .text, .sourceCode, .json, .pdf, .data],
                          allowsMultipleSelection: true) { result in
                handleImport(result)
            }
            .sheet(isPresented: $showPaste) { pasteSheet }
        }
    }

    // MARK: - Cards

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("On-device embeddings unavailable")
                .font(T.sans(14, .semibold)).foregroundColor(T.bad)
            Text("This device's language doesn't have a local embedding model, so the Knowledge Base can't index text here.")
                .font(T.mono(10)).foregroundColor(T.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(T.bad.opacity(0.10)))
    }

    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Toggle(isOn: $kb.isEnabled) {
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text("Use in answers")
                        .font(T.sans(15, .semibold)).foregroundColor(T.ink)
                    Text("The assistant grounds replies in your files and cites them — fully offline.")
                        .font(T.mono(9.5)).foregroundColor(T.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(T.accent)
            .disabled(!kb.isAvailable)
        }
        .padding(Space.m)
        .kGlass(cornerRadius: Radius.card, fallbackFill: T.surface)
    }

    private var addStrip: some View {
        HStack(spacing: Space.s) {
            actionButton(icon: "doc.badge.plus", label: "Add files") { showImporter = true }
            actionButton(icon: "text.cursor", label: "Paste text") {
                pasteText = ""; pasteName = ""; showPaste = true
            }
        }
        .disabled(!kb.isAvailable)
        .opacity(kb.isAvailable ? 1 : 0.5)
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); HapticManager.impact(.light) }) {
            HStack(spacing: Space.xs) {
                Image(systemName: icon)
                Text(label).font(T.display(15, .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.m)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(T.roseHi))
        }
        .buttonStyle(.plain)
    }

    private var indexingRow: some View {
        HStack(spacing: Space.s) {
            ProgressView().tint(T.accent)
            Text("Indexing…").font(T.mono(11)).foregroundColor(T.ink2)
            Spacer()
        }
        .padding(.horizontal, Space.xxs)
    }

    @ViewBuilder
    private var documentsList: some View {
        if kb.documents.isEmpty {
            VStack(spacing: Space.s) {
                Image(systemName: "books.vertical")
                    .font(.system(.title, weight: .light)).foregroundColor(T.ink4)
                Text("No documents yet")
                    .font(T.sans(14, .semibold)).foregroundColor(T.ink2)
                Text("Add files or paste text to chat with your own content.")
                    .font(T.mono(10)).foregroundColor(T.ink3)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Space.l)
        } else {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Text("DOCUMENTS").font(T.mono(10, .semibold)).foregroundColor(T.ink3).tracking(TextScale.capsTracking)
                    Spacer()
                    Text("\(kb.totalChunks) chunks").font(T.mono(9.5)).foregroundColor(T.ink3)
                }
                ForEach(kb.documents) { doc in documentRow(doc) }
            }
        }
    }

    private func documentRow(_ doc: KBDocument) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "doc.text")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundColor(T.accent2)
                .frame(width: Size.control, height: Size.control)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(T.accent2Soft))
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(doc.name).font(T.sans(14, .semibold)).foregroundColor(T.ink).lineLimit(1)
                Text("\(doc.chunkCount) chunks · \(Int64(doc.byteCount).formattedBytes)")
                    .font(T.mono(9.5)).foregroundColor(T.ink3)
            }
            Spacer(minLength: 0)
            Button {
                pendingDelete = doc
            } label: {
                Image(systemName: "trash").font(.system(.footnote)).foregroundColor(T.bad)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(doc.name)")
        }
        .padding(Space.s)
        .kGlass(cornerRadius: Radius.control, fallbackFill: T.surface)
    }

    // MARK: - Paste sheet

    private var pasteSheet: some View {
        NavigationStack {
            ZStack {
                LiquidPinkBackdrop()
                VStack(spacing: Space.s) {
                    TextField("Name (e.g. Project notes)", text: $pasteName)
                        .font(T.sans(15)).padding(Space.s)
                        .background(RoundedRectangle(cornerRadius: Radius.control).fill(T.surface))
                    TextEditor(text: $pasteText)
                        .font(T.mono(12)).scrollContentBackground(.hidden)
                        .padding(Space.s)
                        .background(RoundedRectangle(cornerRadius: Radius.control).fill(T.surface))
                        .frame(minHeight: 220)
                    Spacer()
                }
                .padding(Space.m)
            }
            .navigationTitle("Paste text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { showPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let name = pasteName.trimmingCharacters(in: .whitespaces).isEmpty
                            ? "Pasted text" : pasteName
                        let text = pasteText
                        showPaste = false
                        Task { await kb.addDocument(name: name, text: text) }
                    }
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result,
               (error as? CocoaError)?.code != .userCancelled {
                ToastCenter.shared.error("Couldn't open picker",
                                         detail: error.localizedDescription)
            }
            return
        }
        Task {
            for url in urls {
                do {
                    let attachment = try await FileAttachmentService.read(url)
                    await kb.addDocument(name: attachment.displayName, text: attachment.extractedText)
                } catch {
                    ToastCenter.shared.error("Couldn't read \(url.lastPathComponent)",
                                             detail: error.localizedDescription)
                }
            }
        }
    }
}
