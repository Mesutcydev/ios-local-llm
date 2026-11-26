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
                .padding(.bottom, Space.l)
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark") { dismiss() }.foregroundColor(T.ink)
                }
            }
            .sheet(isPresented: $showEditor) {
                SnippetEditorView(snippet: editing)
                    .onDisappear { editing = nil }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            KCaption(text: "COMPOSER")
            KPageTitle(title: "snippets", size: 28)
            KMono(text: "tap to insert · long-press to edit",
                   size: 11, color: T.ink3)
                .padding(.top, Space.hair)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.m)
        .padding(.top, Space.xxs)
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
        VStack(spacing: Space.s) {
            Image(systemName: "doc.text")
                .font(.system(size: Space.xl))
                .foregroundColor(T.ink3)
            VStack(spacing: Space.xxs) {
                Text("no snippets yet")
                    .font(T.mono(13, .semibold))
                    .foregroundColor(T.ink2)
                Text("Save reusable prompts you find yourself typing often — they show up here for one-tap insert.")
                    .font(T.sans(11))
                    .foregroundColor(T.ink3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.l)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                editing = nil
                showEditor = true
                HapticManager.impact(.light)
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "plus").font(.system(.caption2))
                    Text("create your first").font(T.mono(11, .semibold))
                }
            }
            .glassButton(prominent: true)
            .padding(.top, Space.xxs)
        }
        .padding(.vertical, Space.xl)
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
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(snippet.title)
                    .font(T.mono(13, .semibold))
                    .foregroundColor(T.ink)
                KMono(text: snippet.body.replacingOccurrences(of: "\n", with: " "),
                       size: 10, color: T.ink3)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
        }
        .buttonStyle(.plain)
    }

    private var createButton: some View {
        Button {
            editing = nil
            showEditor = true
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: "plus")
                    .font(.system(.caption, weight: .semibold))
                Text("new snippet")
                    .font(T.mono(12, .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .glassButton(prominent: true)
        .controlSize(.large)
        .padding(.horizontal, Space.m)
        .padding(.top, Space.m)
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
                            .padding(Space.s)
                    }
                    KSection(title: "body") {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            TextEditor(text: $bodyText)
                                .font(T.mono(12))
                                .foregroundColor(T.ink)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 220)
                            KMono(text: "tip: use {cursor} to mark where the caret should land after insertion.",
                                   size: 10, color: T.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(Space.s)
                    }
                }
                .padding(.bottom, Space.l)
            }
            .background(LiquidPinkBackdrop())
            .navigationTitle(isNew ? "new snippet" : "edit snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }.foregroundColor(T.ink2)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", systemImage: "checkmark") { save() }
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
