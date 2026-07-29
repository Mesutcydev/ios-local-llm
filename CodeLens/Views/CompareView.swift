import SwiftUI

// MARK: - CompareView
// Side-by-side A/B comparison of two models against the same prompt. Sequential
// runs (not parallel — we only have one GPU and one model at a time loadable),
// but the results stay pinned so the user can scan both replies and pick a
// winner. Records TTFT + tokens/sec under each reply.
//
// Use case: "which model is best for code on my device?" — type one prompt,
// run it against any two installed models (presets OR downloaded OR custom),
// compare quality AND speed, then vote. Votes feed ModelArenaStore, which
// keeps a persisted per-device Elo leaderboard shown right below.
//
// Two testing aids on top of the raw A/B:
//   • Blind mode — hides model names and randomizes which pick lands in
//     panel A vs B, so the vote reflects output quality, not brand bias.
//     Names reveal the moment a winner is chosen.
//   • Quantization / runtime axis — the result card shows each model's
//     subtitle (e.g. "4-bit" vs "8-bit") and runtime badge, so pitting
//     Qwen3-4B 4-bit against its 8-bit sibling measures the quality↔
//     speed↔memory trade-off on the user's own hardware.

struct CompareView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    @ObservedObject private var assistant = CodingAssistantService.shared
    @ObservedObject private var center = ModelDownloadCenter.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var prompt: String = ""
    @State private var modelAID: String = AssistantModelCatalog.presets[0].id
    @State private var modelBID: String = AssistantModelCatalog.presets.count > 1
        ? AssistantModelCatalog.presets[1].id
        : AssistantModelCatalog.presets[0].id
    @State private var resultA: RunResult?
    @State private var resultB: RunResult?
    @State private var isRunning = false
    @State private var runLabel: String = ""

    /// Hide model identity while judging. When on, panels read "Model A" /
    /// "Model B" and the two picks are randomly assigned to the slots.
    @State private var blindMode = false
    /// Flips true once a winner is chosen (or the user taps reveal), at
    /// which point blind labels turn back into real model names.
    @State private var revealed = false
    /// The outcome the user voted, kept so the chosen panel can be marked.
    @State private var votedOutcome: ModelArenaStore.Outcome?

    struct RunResult: Identifiable {
        let id = UUID()
        let modelID: String
        let modelName: String
        let subtitle: String      // quant/size line, e.g. "4-bit · 2.3 GB"
        let runtimeLabel: String  // "MLX" / "GGUF"
        let text: String
        let ttftMs: Double
        let tokensPerSec: Double
        let wallMs: Double
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    promptCard
                    pickerCard
                    optionsCard
                    runButton
                    resultsGrid
                    if resultA != nil && resultB != nil { votingCard }
                    ArenaLeaderboardCard(lane: .text)
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
    }

    // MARK: - Selectable models (presets + downloaded + custom imports)

    /// Every model the chat runtime can actually load — built-in presets
    /// plus anything pulled via HF Search / custom repo / Files import.
    /// Previously the picker only offered presets, so you couldn't A/B a
    /// model you'd downloaded yourself against a built-in.
    private var selectableModels: [AssistantModel] {
        var out = AssistantModelCatalog.presets
        var seen = Set(out.map(\.repoID))
        for m in center.models where m.category == .assistant && m.isReady && !m.isRequired {
            let descriptor = LocalModelRegistry.descriptor(for: m, forcedRole: .assistant)
            guard !seen.contains(descriptor.repoID) else { continue }
            seen.insert(descriptor.repoID)
            if let assistantModel = descriptor.assistantModel {
                out.append(assistantModel)
            }
        }
        return out
    }

    /// Models that fit the same live load budget as the assistant picker.
    /// Compare runs sequentially, so the binding limit is whether each model
    /// can load by itself on this device right now.
    private var eligibleModels: [AssistantModel] {
        selectableModels.filter { model in
            switch MemoryAdvisor.fit(forFootprint: MemoryAdvisor.estimatedFootprint(for: model.id)) {
            case .fits:  return true
            case .tight: return settings.showEdgeModels
            case .over:  return false
            }
        }
    }

    private func model(forID id: String) -> AssistantModel? {
        selectableModels.first { $0.id == id }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: "COMPARE")
            KPageTitle(title: "a/b models", size: 28)
            KMono(text: "one prompt · two models · pick a winner · build a leaderboard",
                  size: 11, color: T.ink3)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var promptCard: some View {
        KSection(title: "prompt") {
            TextEditor(text: $prompt)
                .font(T.mono(12))
                .frame(minHeight: 80, maxHeight: 180)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.surface2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule, lineWidth: 1))
                .padding(12)
        }
    }

    private var pickerCard: some View {
        KSection(title: "contestants") {
            VStack(spacing: 8) {
                modelPickerRow(label: "model a", binding: $modelAID)
                modelPickerRow(label: "model b", binding: $modelBID)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func modelPickerRow(label: String, binding: Binding<String>) -> some View {
        HStack {
            KMono(text: label, size: 11, color: T.ink3)
                .frame(width: 70, alignment: .leading)
            Menu {
                ForEach(eligibleModels, id: \.id) { m in
                    Button(m.displayName) { binding.wrappedValue = m.id }
                }
            } label: {
                HStack {
                    Text(displayName(for: binding.wrappedValue))
                        .font(T.mono(12, .semibold))
                        .foregroundColor(T.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(T.ink3)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.surface2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule, lineWidth: 1))
            }
        }
    }

    private func displayName(for id: String) -> String {
        model(forID: id)?.displayName ?? id
    }

    private var optionsCard: some View {
        KSection(title: "options") {
            Toggle(isOn: $blindMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("blind mode")
                        .font(T.mono(12, .semibold))
                        .foregroundColor(T.ink)
                    KMono(text: "hide names + randomize panels so you judge output, not brand",
                          size: 9, color: T.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(T.accent)
            .padding(12)
        }
    }

    private var runButton: some View {
        VStack(spacing: 8) {
            Button {
                Task { await runCompare() }
                HapticManager.impact(.medium)
            } label: {
                HStack(spacing: 6) {
                    if isRunning {
                        ProgressView().tint(T.bg).scaleEffect(0.7)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 11))
                    }
                    Text(isRunning ? "running \(runLabel)…" : "run both")
                        .font(T.mono(12, .semibold))
                }
                .foregroundColor(T.bg)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.ink))
            }
            .buttonStyle(.plain)
            .disabled(!canRun)
            .opacity(canRun ? 1 : 0.5)
            if modelAID == modelBID {
                Text("pick two different models to compare").font(T.mono(10)).foregroundColor(T.warn)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var canRun: Bool {
        !isRunning && !prompt.trimmingCharacters(in: .whitespaces).isEmpty && modelAID != modelBID
    }

    @ViewBuilder
    private var resultsGrid: some View {
        if resultA != nil || resultB != nil {
            KSection(title: "results") {
                VStack(spacing: 0) {
                    if let a = resultA { resultPanel(a, slot: "A") }
                    if resultA != nil && resultB != nil {
                        Rectangle().fill(T.rule).frame(height: 1)
                    }
                    if let b = resultB { resultPanel(b, slot: "B") }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func resultPanel(_ r: RunResult, slot: String) -> some View {
        // While blind and unrevealed, show the neutral slot label; otherwise
        // the real model name + its quant/runtime metadata.
        let hideIdentity = blindMode && !revealed
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(hideIdentity ? "Model \(slot)" : r.modelName)
                    .font(T.mono(12, .semibold))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !hideIdentity {
                    Text(r.runtimeLabel)
                        .font(T.mono(8, .semibold))
                        .tracking(0.5)
                        .foregroundColor(T.ink2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(T.ink2.opacity(0.10)))
                }
                if votedOutcome != nil, isWinnerSlot(slot) {
                    Text("WINNER")
                        .font(T.mono(8, .bold)).tracking(0.6)
                        .foregroundColor(T.accent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(T.accent.opacity(0.14)))
                }
                Spacer()
                HStack(spacing: 12) {
                    KMono(text: String(format: "%.0f ms", r.ttftMs), size: 10, color: T.accent)
                    KMono(text: String(format: "%.1f t/s", r.tokensPerSec), size: 10, color: T.accent)
                }
            }
            if !hideIdentity, !r.subtitle.isEmpty {
                KMono(text: r.subtitle, size: 9, color: T.ink3)
            }
            Text(r.text)
                .font(T.sans(13))
                .foregroundColor(T.ink2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    /// True when `slot` ("A"/"B") corresponds to the model the user voted for.
    private func isWinnerSlot(_ slot: String) -> Bool {
        switch votedOutcome {
        case .aWins: return slot == "A"
        case .bWins: return slot == "B"
        default:     return false   // ties / no vote → no crown
        }
    }

    // MARK: - Voting

    @ViewBuilder
    private var votingCard: some View {
        KSection(title: "verdict") {
            VStack(spacing: 10) {
                if let outcome = votedOutcome {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").foregroundColor(T.accent)
                        Text(verdictLabel(outcome))
                            .font(T.mono(11, .semibold))
                            .foregroundColor(T.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    KMono(text: blindMode ? "which answer is better? names reveal after you choose"
                                          : "which model answered better?",
                          size: 10, color: T.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        voteButton(title: blindMode ? "A wins" : "← A wins", outcome: .aWins)
                        voteButton(title: "tie", outcome: .tie)
                        voteButton(title: blindMode ? "B wins" : "B wins →", outcome: .bWins)
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func voteButton(title: String, outcome: ModelArenaStore.Outcome) -> some View {
        Button {
            castVote(outcome)
            HapticManager.impact(.medium)
        } label: {
            Text(title)
                .font(T.mono(11, .semibold))
                .foregroundColor(T.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.surface2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func verdictLabel(_ outcome: ModelArenaStore.Outcome) -> String {
        guard let a = resultA, let b = resultB else { return "recorded" }
        switch outcome {
        case .aWins: return "\(a.modelName) wins — recorded to standings"
        case .bWins: return "\(b.modelName) wins — recorded to standings"
        case .tie:   return "tie — recorded to standings"
        }
    }

    private func castVote(_ outcome: ModelArenaStore.Outcome) {
        guard let a = resultA, let b = resultB else { return }
        ModelArenaStore.shared.record(
            lane: .text,
            a: (id: a.modelID, name: a.modelName),
            b: (id: b.modelID, name: b.modelName),
            outcome: outcome
        )
        votedOutcome = outcome
        revealed = true   // unmask names now that the vote is in
    }

    // MARK: - Run

    private func runCompare() async {
        guard let pickA = model(forID: modelAID),
              let pickB = model(forID: modelBID)
        else { return }
        isRunning = true
        defer { isRunning = false }
        resultA = nil
        resultB = nil
        votedOutcome = nil
        revealed = !blindMode   // non-blind reveals immediately

        // In blind mode, randomly map the two picks onto slots A/B so the
        // user can't infer identity from panel position.
        let (slotA, slotB) = blindMode && Bool.random()
            ? (pickB, pickA)
            : (pickA, pickB)

        // Remember chat model so we restore after.
        let original = assistant.activeModel

        runLabel = "model a"
        await assistant.switchTo(slotA, persistAsDefault: false)
        if case .ready = assistant.state {
            resultA = await runOne(model: slotA)
        }
        runLabel = "model b"
        await assistant.switchTo(slotB, persistAsDefault: false)
        if case .ready = assistant.state {
            resultB = await runOne(model: slotB)
        }
        // Restore — best effort.
        await assistant.switchTo(original, persistAsDefault: false)
    }

    private func runOne(model: AssistantModel) async -> RunResult {
        let start = Date()
        // Use a reference box so concurrent closures can mutate safely.
        final class Box: @unchecked Sendable {
            var ttft: Double = 0
            var rate: Double = 0
            var text: String = ""
        }
        let b = Box()
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are concise. No filler."),
            ChatMessage(role: .user, content: prompt)
        ]
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            assistant.generate(
                messages: messages,
                onToken: { token in
                    if b.ttft == 0 { b.ttft = Date().timeIntervalSince(start) * 1000 }
                    b.text += token
                },
                onComplete: { r in
                    b.rate = r
                    cont.resume()
                }
            )
        }
        let wall = Date().timeIntervalSince(start) * 1000
        return RunResult(
            modelID: model.id,
            modelName: model.displayName,
            subtitle: model.subtitle,
            runtimeLabel: model.runtime.label,
            text: b.text,
            ttftMs: b.ttft, tokensPerSec: b.rate, wallMs: wall
        )
    }
}
