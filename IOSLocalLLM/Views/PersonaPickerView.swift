import SwiftUI

// MARK: - PersonaPickerView
// Bottom-sheet picker for the active chat persona. Built-in presets at the
// top, user-created ones below, plus a "Create persona" button.

struct PersonaPickerView: View {
    @ObservedObject private var store = PersonaStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    @State private var showEditor = false
    @State private var editingPersona: Persona?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    builtInsSection
                    customSection
                    createButton
                }
                .padding(.bottom, Space.l)
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .foregroundColor(T.ink)
                }
            }
            .sheet(isPresented: $showEditor) {
                PersonaEditorView(persona: editingPersona)
                    .onDisappear { editingPersona = nil }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            KCaption(text: "ASSISTANT")
            KPageTitle(title: "personas", size: 28)
            KMono(text: "tap to switch how the assistant responds",
                   size: 11, color: T.ink3)
                .padding(.top, Space.hair)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.m)
        .padding(.top, Space.xxs)
    }

    private var builtInsSection: some View {
        KSection(title: "built-in") {
            let items = store.personas.filter { $0.isBuiltIn }
            ForEach(Array(items.enumerated()), id: \.offset) { i, persona in
                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                row(for: persona)
            }
        }
    }

    @ViewBuilder
    private var customSection: some View {
        let custom = store.personas.filter { !$0.isBuiltIn }
        if !custom.isEmpty {
            KSection(title: "custom") {
                ForEach(Array(custom.enumerated()), id: \.offset) { i, persona in
                    if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                    row(for: persona)
                        .contextMenu {
                            Button {
                                editingPersona = persona
                                showEditor = true
                            } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) {
                                store.delete(persona.id)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for persona: Persona) -> some View {
        let isActive = persona.id == store.activeID
        Button {
            store.setActive(persona.id)
            HapticManager.impact(.light)
            ToastCenter.shared.info("Switched to \(persona.name)")
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: Space.s) {
                ZStack {
                    Circle()
                        .fill(persona.accent.opacity(0.12))
                        .frame(width: Size.tile, height: Size.tile)
                    Image(systemName: persona.icon)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundColor(persona.accent)
                }

                VStack(alignment: .leading, spacing: Space.hair) {
                    HStack(spacing: Space.xs) {
                        Text(persona.name)
                            .font(T.mono(13, .semibold))
                            .foregroundColor(T.ink)
                        if isActive { KActivePill(text: "active") }
                    }
                    KMono(text: persona.subtitle, size: 10, color: T.ink3)
                        .lineLimit(2)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(persona.accent)
                        .font(.system(.callout))
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
        }
        .buttonStyle(.plain)
    }

    private var createButton: some View {
        Button {
            editingPersona = nil
            showEditor = true
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: "plus")
                    .font(.system(.caption, weight: .semibold))
                Text("create persona")
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

// MARK: - PersonaEditorView

struct PersonaEditorView: View {
    let persona: Persona?
    @ObservedObject private var store = PersonaStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    @State private var name: String = ""
    @State private var subtitle: String = ""
    @State private var systemPrompt: String = ""

    private var isNew: Bool { persona == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    KSection(title: "name") {
                        TextField("e.g. Python Tutor", text: $name)
                            .font(T.sans(14))
                            .foregroundColor(T.ink)
                            .padding(Space.s)
                    }
                    KSection(title: "subtitle") {
                        TextField("short description shown in the picker", text: $subtitle)
                            .font(T.sans(13))
                            .foregroundColor(T.ink)
                            .padding(Space.s)
                    }
                    KSection(title: "system_prompt") {
                        TextEditor(text: $systemPrompt)
                            .font(T.mono(12))
                            .foregroundColor(T.ink)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220)
                            .padding(Space.s)
                    }
                }
                .padding(.bottom, Space.l)
            }
            .background(LiquidPinkBackdrop())
            .navigationTitle(isNew ? "new persona" : "edit persona")
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
                if let p = persona {
                    name = p.name
                    subtitle = p.subtitle
                    systemPrompt = p.systemPrompt
                }
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        if let existing = persona {
            var updated = existing
            updated.name = name
            updated.subtitle = subtitle
            updated.systemPrompt = systemPrompt
            store.update(updated)
        } else {
            let new = Persona(
                id: "user-\(UUID().uuidString.prefix(8))",
                name: name,
                subtitle: subtitle.isEmpty ? "Custom persona" : subtitle,
                systemPrompt: systemPrompt,
                icon: "person.circle",
                accentName: "accent",
                isBuiltIn: false
            )
            store.add(new)
        }
        HapticManager.impact(.medium)
        dismiss()
    }
}
