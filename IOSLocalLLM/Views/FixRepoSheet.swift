import SwiftUI

// MARK: - FixRepoSheet
// Recovery sheet shown when a built-in catalog download fails. Lets the user
// swap the repo ID (e.g. switch FastVLM to a different public mirror) without
// having to dig into Settings.

struct FixRepoSheet: View {
    let model: DownloadableModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    @State private var newRepoID: String = ""
    @State private var showSearch = false

    /// Hand-curated alternatives per category, listed in priority order.
    /// We can't HEAD-probe these from a SwiftUI view, so the picker simply
    /// lets the user try them — the actual reachability check happens when
    /// the download starts.
    private static let alternatives: [DownloadableModel.Category: [String]] = [
        .vlm: [
            "apple/FastVLM-0.5B-MLX",
            "mlx-community/llava-fastvithd_0.5b_stage3_llm.fp16",
            "apple/FastVLM-1.5B-MLX",
            "mlx-community/FastVLM-0.5B-Stage3-LLM",
        ],
        .assistant: [
            "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            "mlx-community/Qwen2.5-7B-Instruct-4bit",
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
        ],
        .voice: [
            "alexwengg/kittentts-coreml",
            "hexgrad/Kokoro-82M",
        ],
    ]

    private var candidates: [String] {
        Self.alternatives[model.category] ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    searchShortcut
                    candidatesSection
                    customSection
                }
                .padding(.bottom, 32)
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundColor(T.ink2)
                }
            }
            .sheet(isPresented: $showSearch) { HFSearchView() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            KCaption(text: "DOWNLOAD FAILED")
            KPageTitle(title: "find a working repo", size: 26)
            KMono(text: "the default mirror for \(model.displayName) didn't respond. pick an alternative below or search huggingface.",
                   size: 11, color: T.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var searchShortcut: some View {
        KSection(title: "search") {
            Button {
                showSearch = true
                HapticManager.impact(.light)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(T.accent)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 6).fill(T.accentSoft))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("search huggingface")
                            .font(T.mono(13, .semibold))
                            .foregroundColor(T.ink)
                        KMono(text: "find any \(categoryHint) model on hf.co",
                               size: 10, color: T.ink3)
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

    @ViewBuilder
    private var candidatesSection: some View {
        if !candidates.isEmpty {
            KSection(title: "known_alternatives") {
                ForEach(Array(candidates.enumerated()), id: \.offset) { i, repoID in
                    if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                    Button {
                        tryRepo(repoID)
                    } label: {
                        HStack(spacing: 10) {
                            Text("›")
                                .font(T.mono(13, .semibold))
                                .foregroundColor(T.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                KMono(text: repoID, size: 11, weight: .semibold, color: T.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 12))
                                .foregroundColor(T.ink3)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var customSection: some View {
        KSection(title: "custom_repo") {
            VStack(alignment: .leading, spacing: 8) {
                KMono(text: "paste any author/repo from huggingface.co.",
                       size: 10, color: T.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("author/repo (e.g. apple/FastVLM-0.5B-MLX)",
                          text: $newRepoID)
                    .font(T.mono(11))
                    .foregroundColor(T.ink)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(T.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule, lineWidth: 1))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    let trimmed = newRepoID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.contains("/") else {
                        ToastCenter.shared.error("Invalid repo ID",
                                                  detail: "Format: author/repo-name")
                        return
                    }
                    tryRepo(trimmed)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("try this repo")
                            .font(T.mono(11, .semibold))
                    }
                    .foregroundColor(T.bg)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(T.ink))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private var categoryHint: String {
        switch model.category {
        case .vlm:       return "vision–language"
        case .assistant: return "language"
        case .voice:     return "tts"
        case .imageGen:  return "image generation"
        }
    }

    /// Updates the relevant AppSettings key and triggers an immediate retry.
    private func tryRepo(_ repoID: String) {
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Persist the new repo so it sticks across launches
        switch model.category {
        case .vlm:
            AppSettings.shared.fastVLMRepoID = trimmed
            ToastCenter.shared.info("Trying \(trimmed)…",
                                     detail: "Catalog will rebuild on next launch.")
        default:
            ToastCenter.shared.info("Trying \(trimmed)…")
        }
        // Best-effort: kick off a fresh HFModelDownloadManager pointed at the
        // new repo. Persisted change takes effect across launches; this gives
        // immediate feedback.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent("HFModels", isDirectory: true)
            .appendingPathComponent(trimmed.replacingOccurrences(of: "/", with: "_"))
        let downloader = HFModelDownloadManager(repoID: trimmed, destination: dest)
        ModelDownloadCenter.shared.registerCustom(
            repoID: trimmed,
            displayName: trimmed.split(separator: "/").last.map(String.init) ?? trimmed,
            subtitle: "user-set · \(model.category)",
            category: model.category,
            sizeLabel: "?",
            docURL: "https://huggingface.co/\(trimmed)",
            downloader: downloader
        )
        downloader.start()
        dismiss()
    }
}
