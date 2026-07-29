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
                .padding(.bottom, 32)
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
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
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: "ASSISTANT")
            KPageTitle(title: "personas", size: 28)
            KMono(text: "tap to switch how the assistant responds",
                   size: 11, color: T.ink3)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
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
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(persona.accent.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: persona.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(persona.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
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
                        .font(.system(size: 16))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }

    private var createButton: some View {
        Button {
            editingPersona = nil
            showEditor = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("create persona")
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
                            .padding(12)
                    }
                    KSection(title: "subtitle") {
                        TextField("short description shown in the picker", text: $subtitle)
                            .font(T.sans(13))
                            .foregroundColor(T.ink)
                            .padding(12)
                    }
                    KSection(title: "system_prompt") {
                        TextEditor(text: $systemPrompt)
                            .font(T.mono(12))
                            .foregroundColor(T.ink)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220)
                            .padding(10)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(LiquidPinkBackdrop())
            .navigationTitle(isNew ? "new persona" : "edit persona")
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
