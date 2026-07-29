import SwiftUI

// MARK: - BenchmarkView
// Runs a short prompt suite against the currently loaded assistant model and
// displays latency, throughput, memory, and thermal results. Past results
// are persisted so users can compare across model swaps or device states.

struct BenchmarkView: View {
    @StateObject private var service = BenchmarkService.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @ObservedObject private var safety = DeviceSafetyMonitor.shared
    @Environment(\.koduTheme) private var T
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false
    @State private var showQualityEval = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    deviceCard
                    if let warning = thermalWarning { warningCard(warning) }
                    runCard
                    qualityLinkCard
                    if case .finished(let result) = service.phase {
                        resultsCard(result, isCurrent: true)
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
            .confirmationDialog("Clear all benchmark history?", isPresented: $showClearConfirm) {
                Button("Clear", role: .destructive) { service.clearHistory() }
            }
            .sheet(isPresented: $showQualityEval) {
                QualityEvalView()
            }
        }
    }

    // MARK: - Quality eval link
    // Benchmark measures speed; this card routes to the quality eval, which
    // measures how well the same model follows instructions (auto-graded,
    // on-device). Two halves of "test this model" in one place.

    private var qualityLinkCard: some View {
        KSection(title: "quality") {
            Button {
                showQualityEval = true
                HapticManager.impact(.light)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(T.accent)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 6).fill(T.accent.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("run quality eval")
                            .font(T.mono(13, .semibold))
                            .foregroundColor(T.ink)
                        KMono(text: "speed is half the story — score instruction-following too",
                              size: 10, color: T.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(T.ink3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: "PERFORMANCE")
            KPageTitle(title: "benchmark", size: 28)
            KMono(text: "measure how the active model runs on your device",
                  size: 11, color: T.ink3)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Device card

    private var deviceCard: some View {
        KSection(title: "device") {
            KSpecTable(rows: [
                ("active model", assistant.activeModel.displayName),
                ("model id",     assistant.activeModel.id),
                ("device ram",   MemoryAdvisor.deviceTotalRAM.formattedBytes),
                ("thermal",      thermalLabel(safety.thermalState)),
            ], keyWidth: 100)
            .padding(14)
        }
    }

    // MARK: - Run card

    private var runCard: some View {
        KSection(title: "run") {
            VStack(spacing: 12) {
                switch service.phase {
                case .idle, .finished, .failed:
                    runButton
                case .preparing:
                    progressRow(title: "preparing…", subtitle: "")
                    stopButton
                case .running(let i, let label):
                    progressRow(
                        title: "running \(label)…",
                        subtitle: "prompt \(i + 1) of \(BenchmarkService.defaultPrompts.count)"
                    )
                    stopButton
                    if !service.liveOutput.isEmpty {
                        Text(service.liveOutput)
                            .font(T.mono(10))
                            .foregroundColor(T.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(4)
                            .truncationMode(.head)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(T.surface2))
                    }
                }
                if case .failed(let msg) = service.phase {
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
            Task { await service.run() }
            HapticManager.impact(.medium)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 11))
                Text("run benchmark").font(T.mono(12, .semibold))
            }
            .foregroundColor(T.bg)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(T.ink))
        }
        .buttonStyle(.plain)
        .disabled(!isReadyToRun)
        .opacity(isReadyToRun ? 1 : 0.5)
    }

    // Stop control shown while a benchmark is preparing or running. Cancels
    // the in-flight prompt and discards the partial run (a half-finished
    // benchmark would record misleading numbers).
    private var stopButton: some View {
        Button {
            service.cancel()
            HapticManager.impact(.rigid)
            ToastCenter.shared.info("Benchmark stopped")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill").font(.system(size: 11))
                Text("stop").font(T.mono(12, .semibold))
            }
            .foregroundColor(T.bad)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(T.bad.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.bad.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop benchmark")
        .accessibilityHint("Cancels the run without saving partial results")
    }

    private var isReadyToRun: Bool {
        if case .ready = assistant.state, !safety.shouldStopHeavyWork {
            // Don't allow re-run while still running
            switch service.phase {
            case .preparing, .running: return false
            default: return true
            }
        }
        return false
    }

    @ViewBuilder
    private func progressRow(title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(T.accent).scaleEffect(0.8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(T.mono(12, .semibold))
                    .foregroundColor(T.ink)
                if !subtitle.isEmpty {
                    KMono(text: subtitle, size: 10, color: T.ink3)
                }
            }
            Spacer()
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultsCard(_ result: BenchmarkService.BenchmarkResult, isCurrent: Bool) -> some View {
        KSection(title: isCurrent ? "result · current run" : "result") {
            VStack(alignment: .leading, spacing: 10) {
                // Aggregates
                KSpecTable(rows: [
                    ("avg ttft",      String(format: "%.0f ms", result.avgTTFT)),
                    ("avg decode",    String(format: "%.1f tok/s", result.avgDecode)),
                    ("peak ram",      result.peakRSS.formattedBytes),
                    ("thermal Δ",     thermalDelta(start: result.thermalStart, end: result.thermalEnd)),
                ], keyWidth: 100)

                Rectangle().fill(T.rule).frame(height: 1)

                // Per-prompt rows
                ForEach(result.runs) { run in
                    perRunRow(run)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func perRunRow(_ r: BenchmarkService.PromptRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(r.label.uppercased())
                    .font(T.mono(10, .semibold))
                    .tracking(0.5)
                    .foregroundColor(T.accent)
                Spacer()
                Text("\(r.outputTokens) tok")
                    .font(T.mono(10))
                    .foregroundColor(T.ink3)
            }
            HStack(spacing: 14) {
                metric("ttft",   String(format: "%.0f ms", r.ttftMs))
                metric("decode", String(format: "%.1f t/s", r.decodeTokensPerSec))
                metric("total",  String(format: "%.1f s", r.totalWallMs / 1000))
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(T.mono(12, .semibold))
                .foregroundColor(T.ink)
            Text(label)
                .font(T.mono(9))
                .foregroundColor(T.ink3)
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historyCard: some View {
        if !service.history.isEmpty {
            KSection(title: "history") {
                VStack(spacing: 0) {
                    ForEach(Array(service.history.enumerated()), id: \.element.id) { i, h in
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
    private func historyRow(_ h: BenchmarkService.BenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(h.modelDisplayName)
                    .font(T.mono(12, .semibold))
                    .foregroundColor(T.ink)
                Spacer()
                Text(h.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(T.mono(9))
                    .foregroundColor(T.ink3)
            }
            HStack(spacing: 14) {
                metric("ttft",   String(format: "%.0f ms", h.avgTTFT))
                metric("decode", String(format: "%.1f t/s", h.avgDecode))
                metric("peak",   h.peakRSS.formattedBytes)
            }
            KMono(text: "\(h.deviceModel) · \(h.osVersion)", size: 9, color: T.ink3)
        }
        .padding(12)
        .contextMenu {
            Button(role: .destructive) {
                service.delete(h)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Thermal helpers

    private var thermalWarning: String? {
        if safety.shouldStopHeavyWork {
            return "Device is too warm — let it cool before benchmarking for accurate numbers."
        }
        if safety.shouldThrottle {
            return "Device is warming up — benchmark results may understate this model's true throughput."
        }
        return nil
    }

    @ViewBuilder
    private func warningCard(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "thermometer.medium")
                .foregroundColor(T.warn)
            Text(msg)
                .font(T.mono(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.warn.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.warn.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func thermalLabel(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    private func thermalDelta(start: Int, end: Int) -> String {
        let s = ProcessInfo.ThermalState(rawValue: start) ?? .nominal
        let e = ProcessInfo.ThermalState(rawValue: end) ?? .nominal
        return "\(thermalLabel(s)) → \(thermalLabel(e))"
    }
}
