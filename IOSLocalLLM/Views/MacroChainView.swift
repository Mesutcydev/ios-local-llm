import SwiftUI

// MARK: - MacroChainView
// Picker + runner for multi-step prompt chains. User selects a Macro from the
// list, types an input, and runs — the chain executes each step against the
// active model, threading outputs through the templates.

struct MacroChainView: View {
    @ObservedObject private var store = MacroStore.shared
    @StateObject private var runner = MacroRunner()
    @Environment(\.koduTheme) private var T
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMacroID: UUID?
    @State private var input: String = ""

    private var selectedMacro: Macro? {
        store.macros.first { $0.id == selectedMacroID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    macroList
                    if let m = selectedMacro {
                        runCard(macro: m)
                        if !runner.intermediates.isEmpty {
                            intermediatesCard
                        }
                        if case .finished(let final) = runner.phase {
                            finalCard(text: final)
                        }
                    }
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
        }
        .onAppear { if selectedMacroID == nil { selectedMacroID = store.macros.first?.id } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: "WORKFLOWS")
            KPageTitle(title: "macros", size: 28)
            KMono(text: "multi-step prompts · output of step N feeds step N+1",
                  size: 11, color: T.ink3)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var macroList: some View {
        KSection(title: "available") {
            ForEach(Array(store.macros.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                Button {
                    selectedMacroID = m.id
                    HapticManager.impact(.light)
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .stroke(selectedMacroID == m.id ? T.accent : T.rule2, lineWidth: 1.5)
                                .frame(width: 16, height: 16)
                            if selectedMacroID == m.id {
                                Circle().fill(T.accent).frame(width: 9, height: 9)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title)
                                .font(T.mono(13, .semibold))
                                .foregroundColor(T.ink)
                            KMono(text: m.subtitle, size: 10, color: T.ink3)
                        }
                        Spacer()
                        Text("\(m.steps.count) steps")
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func runCard(macro: Macro) -> some View {
        KSection(title: "input") {
            VStack(spacing: 10) {
                TextEditor(text: $input)
                    .font(T.mono(12))
                    .frame(minHeight: 100, maxHeight: 200)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(T.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule, lineWidth: 1))
                runButton(macro: macro)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func runButton(macro: Macro) -> some View {
        let isRunning: Bool = {
            if case .running = runner.phase { return true } else { return false }
        }()
        if isRunning {
            // While the chain runs, the primary control becomes a live
            // progress label plus a Stop button so the user is never stuck
            // waiting on a long multi-step run with no way out.
            HStack(spacing: 10) {
                ProgressView().tint(T.accent).scaleEffect(0.8)
                if case .running(let i, let n) = runner.phase {
                    Text("step \(i + 1)/\(macro.steps.count): \(n)")
                        .font(T.mono(12, .semibold))
                        .foregroundColor(T.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Button {
                    runner.cancel()
                    HapticManager.impact(.rigid)
                    ToastCenter.shared.info("Macro stopped")
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                        Text("stop").font(T.mono(11, .semibold))
                    }
                    .foregroundColor(T.bad)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(T.bad.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.bad.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop macro")
                .accessibilityHint("Cancels the running multi-step chain")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let disabled = input.trimmingCharacters(in: .whitespaces).isEmpty
            Button {
                Task { await runner.run(macro: macro, input: input) }
                HapticManager.impact(.medium)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 11))
                    Text("run macro").font(T.mono(12, .semibold))
                }
                .foregroundColor(T.bg)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.ink))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)
            .accessibilityLabel("Run macro")
            .accessibilityHint(disabled ? "Enter input text first" : "Runs all steps of the selected macro")
        }
    }

    private var intermediatesCard: some View {
        KSection(title: "intermediate") {
            VStack(spacing: 12) {
                ForEach(Array(runner.intermediates.enumerated()), id: \.offset) { i, out in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("step \(i + 1)")
                            .font(T.mono(10, .semibold))
                            .tracking(0.5)
                            .foregroundColor(T.accent)
                        Text(out)
                            .font(T.sans(12))
                            .foregroundColor(T.ink2)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func finalCard(text: String) -> some View {
        KSection(title: "result") {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(T.sans(13))
                    .foregroundColor(T.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = text
                    HapticManager.impact(.light)
                    ToastCenter.shared.info("Copied")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                        Text("copy").font(T.mono(11, .semibold))
                    }
                    .foregroundColor(T.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
    }
}
