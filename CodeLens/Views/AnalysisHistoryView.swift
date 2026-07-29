import SwiftUI

// MARK: - AnalysisHistoryView
// Browses the last N analysis results stored in AnalysisService.
// Each card shows the thumbnail, mode badge, timestamp, and a snippet of
// the extracted text. Tap to re-open in the AnalysisPanelView.

struct AnalysisHistoryView: View {
    @ObservedObject var analysis: AnalysisService
    @Binding var openPanel: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    KCaption(text: "RESULTS")
                    KPageTitle(title: "history", size: 28)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 6)

                if analysis.analysisResults.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !analysis.analysisResults.isEmpty {
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(T.bad)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(T.ink)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .confirmationDialog("Clear all results?",
                                isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) { analysis.clearHistory() }
                Button("Cancel", role: .cancel) {}
            }
            .background(LiquidPinkBackdrop())
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 36))
                .foregroundColor(T.ink3)
            KMono(text: "no captures yet", size: 12, color: T.ink2)
            Text("Capture & analyze a screen to start your history. Last 10 results are kept in memory.")
                .font(T.sans(11))
                .foregroundColor(T.ink3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(analysis.analysisResults) { result in
                    // HeroCardButton wraps the card so the tap can play a
                    // press-scale + radial pulse BEFORE the sheet dismisses.
                    // The history sheet and the AnalysisPanel sheet live in
                    // different presentation contexts (top-level .sheet on
                    // ContentView), so a true matchedGeometryEffect across
                    // them isn't possible without restructuring both into a
                    // shared NavigationStack. The press effect here gives
                    // the eye something to track during the sheet swap so
                    // the navigation reads as deliberate rather than abrupt.
                    HeroCardButton {
                        analysis.reopen(result)
                        openPanel = true
                        HapticManager.impact(.light)
                        dismiss()
                    } content: {
                        AnalysisHistoryCard(result: result)
                    }
                    // Cards fade and lift in as they enter the viewport.
                    // Subtle (0.95 → 1 scale, 0 → 1 opacity) so it reads
                    // as a depth cue rather than a flashy transition.
                    .scrollTransition(.animated.threshold(.visible(0.1))) { content, phase in
                        content
                            .opacity(phase.isIdentity ? 1 : 0)
                            .scaleEffect(phase.isIdentity ? 1 : 0.94)
                    }
                    // Native long-press context menu with preview
                    .contextMenu {
                        Button {
                            analysis.reopen(result)
                            openPanel = true
                            dismiss()
                        } label: {
                            Label("Open", systemImage: "arrow.up.right.square")
                        }
                        Button {
                            UIPasteboard.general.string = result.extractedCode
                            HapticManager.impact(.light)
                            ToastCenter.shared.info("Copied to clipboard")
                        } label: {
                            Label("Copy text", systemImage: "doc.on.doc")
                        }
                        Button {
                            AppBridge.shared.sendToAssistant(
                                code: result.extractedCode,
                                source: result.mode == .visual ? "FastVLM Vision" : "FastVLM"
                            )
                            dismiss()
                        } label: {
                            Label("Send to Assistant", systemImage: "brain")
                        }
                        Divider()
                        Button(role: .destructive) {
                            withAnimation { analysis.deleteResult(result.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } preview: {
                        // System-rendered preview while pressing
                        AnalysisHistoryCard(result: result)
                            .padding()
                            .frame(width: 320)
                    }
                    // Swipe-to-delete on the parent button (uses iOS native
                    // swipe gesture even inside a LazyVGrid)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            withAnimation { analysis.deleteResult(result.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .refreshable {
            // Pull-to-refresh — actually does nothing here since data is
            // in-memory, but the gesture itself feels native and adds a
            // moment for the user to dismiss.
            HapticManager.impact(.light)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}

// MARK: - HeroCardButton
//
// Press-feedback wrapper for history cards. Plays a quick scale-down
// (0.94) + accent pulse ring on tap, holds for ~120ms, then fires the
// real action. The brief animation reads as "opening" — bridges the
// dead air between the history sheet dismissing and the panel sheet
// presenting.
//
// Lives here rather than in a shared Components file because we'd need
// to register the file in project.pbxproj. Localised; not yet
// general-purpose enough to lift out.

private struct HeroCardButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.koduTheme) private var T

    @State private var pressed = false
    @State private var pulse = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
                pressed = true
                pulse = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                action()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pressed = false
                pulse = false
            }
        } label: {
            content()
                .overlay {
                    if pulse {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(T.accent, lineWidth: 2)
                            .scaleEffect(pulse ? 1.06 : 0.98)
                            .opacity(pulse ? 0 : 0.85)
                            .animation(.easeOut(duration: 0.35), value: pulse)
                            .allowsHitTesting(false)
                    }
                }
                .scaleEffect(pressed ? 0.94 : 1.0)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AnalysisHistoryCard

struct AnalysisHistoryCard: View {
    let result: AnalysisResult
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let thumb = result.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 110)
                        .clipped()
                } else {
                    ZStack {
                        T.surface2
                        Image(systemName: "photo")
                            .foregroundColor(T.ink3)
                    }
                    .frame(height: 110)
                }

                modeBadge
                    .padding(6)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(T.rule).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                KMono(text: result.detection.label, size: 10, weight: .medium, color: T.ink)
                    .lineLimit(1)
                Text(snippet)
                    .font(T.sans(11))
                    .foregroundColor(T.ink2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    KMono(text: result.timestamp.formatted(date: .omitted, time: .shortened),
                           size: 9, color: T.ink3)
                    Spacer()
                    if !result.questionAnswers.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 9))
                            Text("\(result.questionAnswers.count)")
                                .font(T.mono(9))
                        }
                        .foregroundColor(T.accent)
                    }
                }
            }
            .padding(10)
        }
        .kGlass(cornerRadius: 8, fallbackFill: T.surface)
    }

    private var snippet: String {
        let raw = result.extractedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return result.fallbackReason ?? "—"
        }
        return raw
    }

    private var modeBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: result.mode.systemImage)
                .font(.system(size: 8, weight: .bold))
            Text(result.mode.displayName.lowercased())
                .font(T.mono(9, .semibold))
                .tracking(0.4)
        }
        .foregroundColor(result.mode == .visual ? T.accent : T.good)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3)
            .fill((result.mode == .visual ? T.accent : T.good).opacity(0.15)))
    }
}
