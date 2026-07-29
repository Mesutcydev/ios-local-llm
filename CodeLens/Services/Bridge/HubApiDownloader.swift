//
//  HubApiDownloader.swift
//  CodeLens
//
//  mlx-swift-lm 3.x severed its built-in HuggingFace Hub dependency: model
//  loading now requires the app to supply a `Downloader` (see the upgrade
//  notes in MLXLMCommon/Documentation.docc/upgrade.md). The tokenizer side
//  is handled by the official `MLXLMTransformers` adapter (`TransformersLoader`,
//  wired via the convenience `loadContainer(from:configuration:)` overload);
//  this is the matching download side.
//
//  It bridges MLXLMCommon's `Downloader` protocol onto swift-transformers'
//  `HubApi.snapshot(...)` — the exact same client the app already uses for
//  Stable-Diffusion weight downloads (see ImageGenerationService), so gated
//  repos and the user's HF token behave identically across the app.
//
//  In practice the app pre-stages models to local directories via
//  HFModelDownloadManager, so `loadContainer` is usually handed a
//  directory-based `ModelConfiguration` and this downloader is only the
//  fallback for id-based loads.

import Foundation
import Hub
import MLXLMCommon

struct HubApiDownloader: Downloader {

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        // HFTokenStore is @MainActor; hop to the main actor to read the
        // active token, then build a HubApi carrying it (matches
        // ImageGenerationService.hub so auth behaviour stays consistent).
        let token = await MainActor.run {
            HFTokenStore.shared.isActive ? HFTokenStore.shared.currentToken() : nil
        }
        return try await HubApi(hfToken: token).snapshot(
            from: Hub.Repo(id: id),
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}
