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

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidPinkBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !kb.isAvailable { unavailableCard }
                        toggleCard
                        addStrip
                        if kb.isIndexing { indexingRow }
                        documentsList
                    }
                    .padding(16)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Knowledge Base")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !kb.documents.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) { kb.clear() } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
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
        VStack(alignment: .leading, spacing: 6) {
            Text("On-device embeddings unavailable")
                .font(T.sans(14, .semibold)).foregroundColor(T.bad)
            Text("This device's language doesn't have a local embedding model, so the Knowledge Base can't index text here.")
                .font(T.mono(10)).foregroundColor(T.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(T.bad.opacity(0.10)))
    }

    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $kb.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
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
        .padding(14)
        .kGlass(cornerRadius: 16, fallbackFill: T.surface)
    }

    private var addStrip: some View {
        HStack(spacing: 10) {
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
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label).font(T.display(15, .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.roseHi))
        }
        .buttonStyle(.plain)
    }

    private var indexingRow: some View {
        HStack(spacing: 10) {
            ProgressView().tint(T.accent)
            Text("Indexing…").font(T.mono(11)).foregroundColor(T.ink2)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var documentsList: some View {
        if kb.documents.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 30, weight: .light)).foregroundColor(T.ink4)
                Text("No documents yet")
                    .font(T.sans(14, .semibold)).foregroundColor(T.ink2)
                Text("Add files or paste text to chat with your own content.")
                    .font(T.mono(10)).foregroundColor(T.ink3)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("DOCUMENTS").font(T.mono(10, .semibold)).foregroundColor(T.ink3).tracking(0.6)
                    Spacer()
                    Text("\(kb.totalChunks) chunks").font(T.mono(9.5)).foregroundColor(T.ink3)
                }
                ForEach(kb.documents) { doc in documentRow(doc) }
            }
        }
    }

    private func documentRow(_ doc: KBDocument) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(T.accent2)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(T.accent2Soft))
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.name).font(T.sans(14, .semibold)).foregroundColor(T.ink).lineLimit(1)
                Text("\(doc.chunkCount) chunks · \(Int64(doc.byteCount).formattedBytes)")
                    .font(T.mono(9.5)).foregroundColor(T.ink3)
            }
            Spacer(minLength: 0)
            Button {
                kb.removeDocument(doc.id); HapticManager.impact(.light)
            } label: {
                Image(systemName: "trash").font(.system(size: 13)).foregroundColor(T.bad)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .kGlass(cornerRadius: 14, fallbackFill: T.surface)
    }

    // MARK: - Paste sheet

    private var pasteSheet: some View {
        NavigationStack {
            ZStack {
                LiquidPinkBackdrop()
                VStack(spacing: 12) {
                    TextField("Name (e.g. Project notes)", text: $pasteName)
                        .font(T.sans(15)).padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(T.surface))
                    TextEditor(text: $pasteText)
                        .font(T.mono(12)).scrollContentBackground(.hidden)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(T.surface))
                        .frame(minHeight: 220)
                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("Paste text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPaste = false }
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
        guard case .success(let urls) = result else { return }
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
