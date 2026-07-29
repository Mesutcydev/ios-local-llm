import SwiftUI

// MARK: - SnippetPickerView
// Bottom-sheet prompt-snippet picker. Tapping a snippet returns its body
// (with {cursor} resolved) so the parent can paste into the composer.

struct SnippetPickerView: View {
    @ObservedObject private var store = SnippetStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    let onPick: (String) -> Void

    @State private var showEditor = false
    @State private var editing: PromptSnippet?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    list
                    createButton
                }
                .padding(.bottom, 32)
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(T.ink)
                }
            }
            .sheet(isPresented: $showEditor) {
                SnippetEditorView(snippet: editing)
                    .onDisappear { editing = nil }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: "COMPOSER")
            KPageTitle(title: "snippets", size: 28)
            KMono(text: "tap to insert · long-press to edit",
                   size: 11, color: T.ink3)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var list: some View {
        if store.snippets.isEmpty {
            emptyState
        } else {
            KSection(title: "saved") {
                ForEach(Array(store.snippets.enumerated()), id: \.offset) { i, s in
                    if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                    row(for: s)
                        .contextMenu {
                            Button {
                                editing = s
                                showEditor = true
                            } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) {
                                store.delete(s.id)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 36))
                .foregroundColor(T.ink3)
            VStack(spacing: 4) {
                Text("no snippets yet")
                    .font(T.mono(13, .semibold))
                    .foregroundColor(T.ink2)
                Text("Save reusable prompts you find yourself typing often — they show up here for one-tap insert.")
                    .font(T.sans(11))
                    .foregroundColor(T.ink3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                editing = nil
                showEditor = true
                HapticManager.impact(.light)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 11))
                    Text("create your first").font(T.mono(11, .semibold))
                }
                .foregroundColor(T.bg)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.ink))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(for snippet: PromptSnippet) -> some View {
        Button {
            let expanded = snippet.expanded().text
            onPick(expanded)
            HapticManager.impact(.light)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(snippet.title)
                    .font(T.mono(13, .semibold))
                    .foregroundColor(T.ink)
                KMono(text: snippet.body.replacingOccurrences(of: "\n", with: " "),
                       size: 10, color: T.ink3)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }

    private var createButton: some View {
        Button {
            editing = nil
            showEditor = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("new snippet")
                    .font(T.mono(12, .semibold))
                    .tracking(0.3)
            }
            .foregroundColor(T.bg)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(T.ink))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }
}

// MARK: - SnippetEditorView

struct SnippetEditorView: View {
    let snippet: PromptSnippet?
    @ObservedObject private var store = SnippetStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    @State private var title: String = ""
    @State private var bodyText: String = ""

    private var isNew: Bool { snippet == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    KSection(title: "title") {
                        TextField("snippet title", text: $title)
                            .font(T.sans(14))
                            .foregroundColor(T.ink)
                            .padding(12)
                    }
                    KSection(title: "body") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $bodyText)
                                .font(T.mono(12))
                                .foregroundColor(T.ink)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 220)
                            KMono(text: "tip: use {cursor} to mark where the caret should land after insertion.",
                                   size: 10, color: T.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(LiquidPinkBackdrop())
            .navigationTitle(isNew ? "new snippet" : "edit snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(T.ink2)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .foregroundColor(canSave ? T.accent : T.ink3)
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if let s = snippet {
                    title = s.title
                    bodyText = s.body
                }
            }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !bodyText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        if let existing = snippet {
            var updated = existing
            updated.title = title
            updated.body = bodyText
            store.update(updated)
        } else {
            store.add(title: title, body: bodyText)
        }
        HapticManager.impact(.medium)
        dismiss()
    }
}
