import SwiftUI
import Combine

// MARK: - DiagnosticsView
//
// The in-app debug surface. One screen to answer "what just happened / why did
// it crash": a prior-crash banner with the breadcrumb trail, the live system
// snapshot (memory + thermal that decide on-device survival), the rolling log,
// and MetricKit reports — all exportable to share when filing an issue.

struct DiagnosticsView: View {
    @Environment(\.koduTheme) private var T
    @ObservedObject private var metric = MetricKitHandler.shared

    @State private var entries: [DiagEntry] = []
    @State private var minLevel: DiagLevel = .info
    @State private var snapshot = SystemSnapshot.header()

    @StateObject private var analyzer = DiagnosticsAnalyzer()

    private let crash = CrashReporter.shared.lastCrash
    private let refreshTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            if let crash { crashSection(crash) }
            analysisSection
            snapshotSection
            logSection
            if !metric.entries.isEmpty { metricSection }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: Diagnostics.shared.exportText()) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button(role: .destructive) {
                        Diagnostics.shared.clear(); refresh()
                    } label: { Label("Clear log", systemImage: "trash") }
                    Button(role: .destructive) {
                        metric.clear()
                    } label: { Label("Clear MetricKit", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(refreshTimer) { _ in refresh() }
    }

    private func refresh() {
        entries = Diagnostics.shared.recentEntries(minLevel: minLevel).reversed()
        snapshot = SystemSnapshot.header()
    }

    // MARK: - Sections

    private func crashSection(_ c: CrashReporter.CrashInfo) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Previous session ended in a \(c.kind)", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(c.detail)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !c.trail.isEmpty {
                    DisclosureGroup("Breadcrumb trail (\(c.trail.count))") {
                        ForEach(Array(c.trail.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: { Text("Last crash") }
    }

    // MARK: - On-device AI analysis

    /// Feeds the crash trail + recent warnings/errors + system snapshot to the
    /// selected assistant model and streams back a plain-English diagnosis —
    /// entirely on-device.
    private var analysisSection: some View {
        Section {
            if analyzer.running {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(analyzer.output.isEmpty ? "Analyzing on-device…" : "Analyzing…")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { analyzer.stop() }
                        .font(.footnote)
                }
            } else {
                Button {
                    analyzer.analyze(buildDiagnosticsPrompt())
                } label: {
                    Label(analyzer.output.isEmpty ? "Analyze with on-device AI" : "Re-analyze",
                          systemImage: "sparkles")
                }
            }
            if !analyzer.output.isEmpty {
                Text(analyzer.output)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }
            if let err = analyzer.error {
                Text(err).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("On-device analysis")
        } footer: {
            Text("Runs the selected assistant model locally — nothing leaves your device.")
                .font(.caption2)
        }
    }

    /// Diagnostics context handed to the model — shared with the chat
    /// "Diagnose app errors" action (see Diagnostics.analysisContext()).
    private func buildDiagnosticsPrompt() -> String {
        Diagnostics.shared.analysisContext()
    }

    private var snapshotSection: some View {
        Section {
            Text(snapshot)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        } header: { Text("System") }
    }

    private var logSection: some View {
        Section {
            Picker("Level", selection: $minLevel) {
                ForEach(DiagLevel.allCases, id: \.self) { lvl in
                    Text(lvl.label).tag(lvl)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: minLevel) { _, _ in refresh() }

            if entries.isEmpty {
                Text("No log entries at this level.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(e.level.label)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(color(for: e.level))
                            Text(e.category)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Text(e.message)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        } header: { Text("Log · \(entries.count)") }
    }

    private var metricSection: some View {
        Section {
            ForEach(metric.entries) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.kind.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(e.kind == "crash" ? .red : .secondary)
                    Text(e.summary)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
        } header: { Text("MetricKit reports") }
    }

    private func color(for level: DiagLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .notice: return .teal
        case .warning: return .orange
        case .error, .fault: return .red
        }
    }
}

// MARK: - DiagnosticsAnalyzer
//
// Drives a one-shot analysis through SafeOnDeviceAnalysisCoordinator. It never
// uses a heavyweight chat selection: Apple's on-device system model is preferred
// and a temporary lightweight local model is the offline fallback.

@MainActor
final class DiagnosticsAnalyzer: ObservableObject {
    @Published var output = ""
    @Published var running = false
    @Published var error: String?

    private let systemPrompt = """
    You are an on-device diagnostics analyst for OnDevice, an iOS app that runs \
    local AI models (MLX / Core ML) fully offline. You are given a system \
    snapshot (memory, thermal, device), the last crash if any, and recent \
    warnings/errors from the app's log. Respond with: (1) the most likely root \
    cause(s), ranked; (2) concrete fixes or user actions (e.g. free memory, \
    re-download a model, pick a smaller model, let the device cool). Be concise \
    and specific. If nothing looks wrong, say the device looks healthy. Do not \
    invent log lines that aren't present.
    """

    func analyze(_ diagnostics: String) {
        guard !running else { return }
        output = ""
        error = nil
        running = true
        SafeOnDeviceAnalysisCoordinator.shared.analyze(
            prompt: diagnostics,
            instructions: systemPrompt,
            maxTokens: 700,
            onToken: { [weak self] chunk in
                Task { @MainActor in self?.output += chunk }
            },
            onComplete: { [weak self] routeError in
                Task { @MainActor in
                    guard let self else { return }
                    self.running = false
                    if let routeError, !routeError.isEmpty {
                        self.error = routeError
                    } else if self.output.isEmpty {
                        self.error = "The analysis model returned no response — try again in a moment."
                    }
                }
            }
        )
    }

    func stop() {
        SafeOnDeviceAnalysisCoordinator.shared.cancel()
        running = false
    }
}
