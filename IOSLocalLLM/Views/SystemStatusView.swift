import SwiftUI

// MARK: - SystemStatusView
// Visible diagnostics panel showing memory, Metal, Neural Engine, and per-model
// performance history. Reached from Settings → System Status.

struct SystemStatusView: View {

    @ObservedObject private var status = SystemStatusService.shared
    @ObservedObject private var usage  = ModelUsageTracker.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Page header
                    VStack(alignment: .leading, spacing: 4) {
                        KCaption(text: "DIAGNOSTICS")
                        KPageTitle(title: "status", size: 28)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 4)

                    memorySection
                    computeSection
                    storageSection
                    modelsSection
                    usageHistorySection
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
            .refreshable {
                status.refresh()
                HapticManager.impact(.light)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            .onAppear  { status.startObserving() }
            .onDisappear { status.stopObserving() }
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        KSection(title: "memory") {
            VStack(spacing: 0) {
                // Memory pressure bar
                memoryBar
                    .padding(14)
                Rectangle().fill(T.rule).frame(height: 1)
                spec(rows: [
                    ("total ram",     status.snapshot.totalRAM.formattedBytes),
                    ("used by app",   status.snapshot.usedByApp.formattedBytes),
                    ("model headroom", status.snapshot.availableForML.formattedBytes),
                    ("kernel reports", status.snapshot.freeRightNow.formattedBytes),
                ])
            }
        }
    }

    @ViewBuilder
    private var memoryBar: some View {
        let used = Double(status.snapshot.usedByApp)
        let total = Double(max(status.snapshot.totalRAM, 1))
        let pct = min(1.0, used / total)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                KCaption(text: "app footprint")
                Spacer()
                Text(String(format: "%.1f%%", pct * 100))
                    .font(T.mono(11, .semibold))
                    .foregroundColor(barColor(pct))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(T.surface2).frame(height: 6)
                    Rectangle().fill(barColor(pct))
                        .frame(width: geo.size.width * pct, height: 6)
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    private func barColor(_ pct: Double) -> Color {
        if pct >= 0.75 { return T.bad }
        if pct >= 0.5  { return T.warn }
        return T.good
    }

    // MARK: - Compute

    private var computeSection: some View {
        KSection(title: "compute") {
            spec(rows: [
                ("device",   status.snapshot.device),
                ("os",       status.snapshot.os),
                ("metal",    status.snapshot.metalDeviceName),
                ("ray-tracing",
                 status.snapshot.metalSupportsRayTracing ? "yes" : "no"),
                ("neural engine",
                 status.snapshot.supportsNeuralEngine ? "available" : "n/a"),
                ("framework", "MLX 0.21 · Metal · ANE"),
            ])
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        KSection(title: "storage") {
            spec(rows: [
                ("models on disk", status.snapshot.modelStorageUsed.formattedBytes),
                ("free space",     status.snapshot.diskFree.formattedBytes),
            ])
        }
    }

    // MARK: - Models loaded right now

    private var modelsSection: some View {
        KSection(title: "models_active") {
            VStack(spacing: 0) {
                statusRow(label: "qwen3-4b",
                          ready: status.snapshot.qwen3Ready,
                          extra: status.snapshot.lastQwen3TPS.map {
                              String(format: "%.1f t/s", $0)
                          })
                Rectangle().fill(T.rule).frame(height: 1)
                statusRow(label: "fastvlm",
                          ready: status.snapshot.fastVLMReady,
                          extra: status.snapshot.lastFastVLMTPS.map {
                              String(format: "%.1f t/s", $0)
                          })
                Rectangle().fill(T.rule).frame(height: 1)
                statusRow(label: "voice engine",
                          ready: status.snapshot.voiceEngineReady,
                          extra: nil)
            }
        }
    }

    @ViewBuilder
    private func statusRow(label: String, ready: Bool, extra: String?) -> some View {
        HStack(spacing: 10) {
            Text(ready ? "●" : "○")
                .font(T.mono(11))
                .foregroundColor(ready ? T.good : T.ink3)
            KMono(text: label, size: 12, color: T.ink)
            Spacer()
            if let extra {
                KMono(text: extra, size: 11, color: T.ink2)
            }
            KMono(text: ready ? "ready" : "idle",
                   size: 10, color: ready ? T.good : T.ink3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Usage history

    @ViewBuilder
    private var usageHistorySection: some View {
        let entries = usage.topRecentlyUsed
        if !entries.isEmpty {
            KSection(title: "usage_history") {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in
                        if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                KMono(text: entry.id, size: 12, weight: .semibold, color: T.ink)
                                Spacer()
                                KMono(text: entry.stat.lastUsedAt.relativeShort,
                                       size: 10, color: T.ink3)
                            }
                            HStack(spacing: 12) {
                                statChip("runs", "\(entry.stat.runCount)")
                                statChip("avg",
                                         String(format: "%.1f t/s", entry.stat.avgTPS))
                                statChip("tokens", "\(entry.stat.totalTokens)")
                                if entry.stat.avgLoadTimeMs > 0 {
                                    statChip("load",
                                             String(format: "%.1fs",
                                                    entry.stat.avgLoadTimeMs / 1000))
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }

            // Reset
            Button(role: .destructive) {
                usage.resetAll()
                ToastCenter.shared.info("Usage history cleared")
            } label: {
                Text("clear usage history")
                    .font(T.mono(11))
                    .foregroundColor(T.bad)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func statChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            KCaption(text: label)
            KMono(text: value, size: 10, weight: .semibold, color: T.ink)
        }
    }

    // MARK: - Spec helper

    @ViewBuilder
    private func spec(rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                HStack {
                    KMono(text: row.0, size: 11, color: T.ink3)
                        .frame(width: 110, alignment: .leading)
                    KMono(text: row.1, size: 11, color: T.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}
