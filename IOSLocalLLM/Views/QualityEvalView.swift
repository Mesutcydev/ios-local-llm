import SwiftUI

// MARK: - QualityEvalView
// Runs the deterministic, auto-graded quality pack (ModelQualityEval)
// against the currently loaded assistant model and shows a quality score
// next to a per-task pass/fail breakdown. This is the "how good", not the
// "how fast" — the complement to BenchmarkView. Past results persist so a
// model / quantization swap's effect on quality is visible at a glance.

struct QualityEvalView: View {
    @StateObject private var eval = ModelQualityEval.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @ObservedObject private var safety = DeviceSafetyMonitor.shared
    @Environment(\.koduTheme) private var T
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    deviceCard
                    runCard
                    if case .finished(let result) = eval.phase {
                        resultsCard(result)
                    }
                    historyCard
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
            .confirmationDialog("Clear all quality history?", isPresented: $showClearConfirm) {
                Button("Clear", role: .destructive) { eval.clearHistory() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: "QUALITY")
            KPageTitle(title: "quality eval", size: 28)
            KMono(text: "auto-graded instruction-following · json · math · format · code",
                  size: 11, color: T.ink3)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Device card

    private var deviceCard: some View {
        KSection(title: "model") {
            KSpecTable(rows: [
                ("active model", assistant.activeModel.displayName),
                ("model id",     assistant.activeModel.id),
                ("tasks",        "\(ModelQualityEval.tasks.count) graded checks"),
            ], keyWidth: 100)
            .padding(14)
        }
    }

    // MARK: - Run card

    private var runCard: some View {
        KSection(title: "run") {
            VStack(spacing: 12) {
                switch eval.phase {
                case .idle, .finished, .failed:
                    runButton
                case .running(let i, let title):
                    progressRow(
                        title: "running \(title)…",
                        subtitle: "task \(i + 1) of \(ModelQualityEval.tasks.count)"
                    )
                    if !eval.liveOutput.isEmpty {
                        Text(eval.liveOutput)
                            .font(T.mono(10))
                            .foregroundColor(T.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(4)
                            .truncationMode(.head)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(T.surface2))
                    }
                }
                if case .failed(let msg) = eval.phase {
                    Text(msg)
                        .font(T.mono(11))
                        .foregroundColor(T.bad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(T.bad.opacity(0.10)))
                }
            }
            .padding(14)
        }
    }

    private var runButton: some View {
        Button {
            Task { await eval.run() }
            HapticManager.impact(.medium)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 11))
                Text("run quality eval").font(T.mono(12, .semibold))
            }
            .foregroundColor(T.bg)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(T.ink))
        }
        .buttonStyle(.plain)
        .disabled(!isReadyToRun)
        .opacity(isReadyToRun ? 1 : 0.5)
    }

    private var isReadyToRun: Bool {
        if case .ready = assistant.state, !safety.shouldStopHeavyWork {
            switch eval.phase {
            case .running: return false
            default:       return true
            }
        }
        return false
    }

    @ViewBuilder
    private func progressRow(title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(T.accent).scaleEffect(0.8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(T.mono(12, .semibold)).foregroundColor(T.ink)
                KMono(text: subtitle, size: 10, color: T.ink3)
            }
            Spacer()
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultsCard(_ result: ModelQualityEval.EvalResult) -> some View {
        KSection(title: "result · current run") {
            VStack(alignment: .leading, spacing: 10) {
                scoreHeadline(result)
                Rectangle().fill(T.rule).frame(height: 1)
                ForEach(result.tasks) { taskRow($0) }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func scoreHeadline(_ result: ModelQualityEval.EvalResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(format: "%.0f%%", result.score * 100))
                .font(T.mono(30, .bold))
                .foregroundColor(scoreColor(result.score))
            VStack(alignment: .leading, spacing: 2) {
                Text("quality score")
                    .font(T.mono(11, .semibold))
                    .foregroundColor(T.ink)
                KMono(text: "\(result.passedCount)/\(result.totalCount) tasks passed",
                      size: 10, color: T.ink3)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func taskRow(_ t: ModelQualityEval.TaskResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: t.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(t.passed ? T.good : T.bad)
                Text(t.title)
                    .font(T.mono(11, .semibold))
                    .foregroundColor(T.ink)
                Spacer()
                Text(String(format: "%.0f%%", t.score * 100))
                    .font(T.mono(11, .semibold))
                    .foregroundColor(scoreColor(t.score))
            }
            KMono(text: t.detail, size: 9, color: T.ink3)
            if !t.output.isEmpty {
                Text(t.output)
                    .font(T.mono(9))
                    .foregroundColor(T.ink2)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(T.surface2))
            }
        }
        .padding(.vertical, 6)
    }

    private func scoreColor(_ s: Double) -> Color {
        if s >= 0.8 { return T.good }
        if s >= 0.5 { return T.warn }
        return T.bad
    }

    // MARK: - History

    @ViewBuilder
    private var historyCard: some View {
        if !eval.history.isEmpty {
            KSection(title: "history") {
                VStack(spacing: 0) {
                    ForEach(Array(eval.history.enumerated()), id: \.element.id) { i, h in
                        if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                        historyRow(h)
                    }
                    Rectangle().fill(T.rule).frame(height: 1)
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text("clear history")
                            .font(T.mono(11, .semibold))
                            .foregroundColor(T.bad)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ h: ModelQualityEval.EvalResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(h.modelDisplayName)
                    .font(T.mono(12, .semibold))
                    .foregroundColor(T.ink)
                KMono(text: "\(h.passedCount)/\(h.totalCount) passed · \(h.timestamp.formatted(date: .abbreviated, time: .shortened))",
                      size: 9, color: T.ink3)
            }
            Spacer()
            Text(String(format: "%.0f%%", h.score * 100))
                .font(T.mono(15, .bold))
                .foregroundColor(scoreColor(h.score))
        }
        .padding(12)
        .contextMenu {
            Button(role: .destructive) {
                eval.delete(h)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
