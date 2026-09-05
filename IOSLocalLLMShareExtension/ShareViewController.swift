import UIKit
import AppIntents
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

// MARK: - ShareViewController
// Entry point for the iOS share sheet. Accepts images, plain text, URLs, and
// Safari web pages (NSExtensionJavaScriptPreprocessingResultsKey payload) from
// any host app, stages the content into the App Group container, and opens
// the main app via a custom URL scheme.
//
// Hand-off URLs:
//   ondevice-core://share?file=<jpg-name>          → image (lens tab)
//   ondevice-core://share?text=<percent-encoded>   → text snippet (assistant tab)
//   ondevice-core://share?url=<percent-encoded>    → URL (assistant tab)
//
// Long text shares (>1500 chars) go through the file-staging path instead of
// the URL — iOS truncates open URLs around 2KB and Safari/Mail share
// selections often exceed that. The query becomes ?textfile=<txt-name>.

final class ShareViewController: UIViewController {

    // App Group identifier — must match the main app's entitlements.
    private static let appGroupID = "group.com.mesutcydev.ondevicecore.shared"
    private static let urlScheme  = "ondevice-core"

    /// Threshold above which we stash text in a file and hand the
    /// filename to the main app instead of inlining via URL query.
    /// 1500 keeps us safely below the 2048-char open-URL cap iOS
    /// enforces even after percent-encoding overhead.
    private static let inlineTextLimit = 1500
    /// Bound decoded image memory inside the extension. A 2,048² BGRA
    /// thumbnail is ~16 MB versus ~190 MB for a decoded 48 MP source.
    private static let sharedImageMaxPixelSize = 2_048
    /// Failed/abandoned hand-offs should not leave private content in the
    /// shared container indefinitely.
    private static let stagedFileMaxAge: TimeInterval = 24 * 60 * 60

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black.withAlphaComponent(0.4)
        Task { await processSharedItem() }
    }

    // MARK: - Pipeline

    private func processSharedItem() async {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            await dismiss(success: false, error: "No content to share")
            return
        }

        // Prefer a URL when present so Safari "Share page" reaches Assistant
        // instead of Lens analyzing the preview thumbnail. Image-only shares
        // still take the image path.
        let hasURL = attachments.contains {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        if !hasURL {
            for attachment in attachments {
                if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    do {
                        let imageData = try await loadImageData(from: attachment)
                        let stagedURL = try writeToAppGroup(imageData,
                                                           subdir: "SharedImages",
                                                           ext: "jpg")
                        do {
                            let openURL = try imageOpenURL(for: stagedURL)
                            await openMainApp(with: openURL)
                        } catch {
                            try? FileManager.default.removeItem(at: stagedURL)
                            throw error
                        }
                        return
                    } catch {
                        print("[ShareExtension] image load failed: \(error)")
                    }
                }
            }
        }

        for attachment in attachments {
            // Plain text (Notes selection, Messages copy, etc.)
            if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await loadText(from: attachment), !text.isEmpty {
                    await handOffText(text)
                    return
                }
            }
            // URLs (Safari link, Mail link, etc.)
            if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = try? await loadURL(from: attachment) {
                    await handOffURL(url)
                    return
                }
            }
        }

        await dismiss(success: false, error: "Unsupported content type")
    }

    // MARK: - Loaders

    private func loadImageData(from attachment: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            // Request the encoded representation instead of `loadItem`, which
            // commonly returns a full-resolution UIImage and eagerly decodes
            // hundreds of MB inside the extension's ~120 MB memory budget.
            attachment.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: Self.shareError(
                        code: -2,
                        description: "Couldn't read image"
                    ))
                    return
                }
                do {
                    continuation.resume(returning: try Self.downsampledJPEG(from: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func downsampledJPEG(from sourceData: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw shareError(code: -2, description: "Couldn't decode image")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: sharedImageMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else {
            throw shareError(code: -2, description: "Couldn't resize image")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw shareError(code: -2, description: "Couldn't prepare image")
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw shareError(code: -2, description: "Couldn't encode image")
        }
        return output as Data
    }

    private func loadText(from attachment: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                if let s = item as? String {
                    continuation.resume(returning: s); return
                }
                if let data = item as? Data,
                   let s = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: s); return
                }
                continuation.resume(throwing: NSError(
                    domain: "ShareExtension", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn't read text"]))
            }
        }
    }

    private func loadURL(from attachment: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                if let url = item as? URL {
                    continuation.resume(returning: url); return
                }
                if let s = item as? String, let url = URL(string: s) {
                    continuation.resume(returning: url); return
                }
                continuation.resume(throwing: NSError(
                    domain: "ShareExtension", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn't read URL"]))
            }
        }
    }

    // MARK: - Hand-off helpers

    private func handOffText(_ text: String) async {
        // Trim and collapse so we don't blow the URL budget on whitespace.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await dismiss(success: false, error: "Empty text")
            return
        }

        if trimmed.count <= Self.inlineTextLimit,
           let encoded = trimmed.addingPercentEncoding(
               withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "\(Self.urlScheme)://share?text=\(encoded)") {
            await openMainApp(with: url)
            return
        }

        // Too long — stage to a file and hand off the name. The main app
        // reads it back from the App Group container.
        do {
            let data = Data(trimmed.utf8)
            let stagedURL = try writeToAppGroup(data,
                                                subdir: "SharedText",
                                                ext: "txt")
            do {
                let openURL = try handOffURL(
                    queryName: "textfile",
                    value: stagedURL.lastPathComponent
                )
                await openMainApp(with: openURL)
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                throw error
            }
        } catch {
            await dismiss(success: false, error: error.localizedDescription)
        }
    }

    private func handOffURL(_ url: URL) async {
        let raw = url.absoluteString
        guard let encoded = raw.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed),
            let openURL = URL(string: "\(Self.urlScheme)://share?url=\(encoded)")
        else {
            await dismiss(success: false, error: "URL too long")
            return
        }
        await openMainApp(with: openURL)
    }

    private func imageOpenURL(for stagedURL: URL) throws -> URL {
        try handOffURL(queryName: "file", value: stagedURL.lastPathComponent)
    }

    private func handOffURL(queryName: String, value: String) throws -> URL {
        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = "share"
        components.queryItems = [URLQueryItem(name: queryName, value: value)]
        guard let url = components.url else {
            throw Self.shareError(code: -6, description: "Couldn't create hand-off URL")
        }
        return url
    }

    // MARK: - Storage

    private func writeToAppGroup(_ data: Data,
                                  subdir: String,
                                  ext: String) throws -> URL {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            throw NSError(domain: "ShareExtension", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "App Group container missing. Configure entitlements."
            ])
        }
        let stagingDir = containerURL.appendingPathComponent(subdir, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        removeExpiredStagedFiles(in: stagingDir)
        let fileURL = stagingDir.appendingPathComponent("share-\(UUID().uuidString).\(ext)")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func removeExpiredStagedFiles(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-Self.stagedFileMaxAge)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func shareError(code: Int, description: String) -> NSError {
        NSError(
            domain: "ShareExtension",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    @MainActor
    private func openMainApp(with url: URL) async {
        // UIApplication isn't directly available to extensions; reach it via
        // the responder chain. Two failure modes used to be swallowed by an
        // unconditional `success: true`, closing the share sheet while nothing
        // actually happened: (1) no UIApplication in the chain, and (2) the
        // open being refused (OnDevice not installed / scheme unhandled).
        // Surface both so the user isn't left staring at a no-op.
        var responder: UIResponder? = self
        var app: UIApplication?
        while let r = responder {
            if let found = r as? UIApplication { app = found; break }
            responder = r.next
        }
        guard let app else {
            await dismiss(success: false, error: "Couldn't reach the app to open OnDevice.")
            return
        }
        let opened: Bool = await withCheckedContinuation { cont in
            app.open(url, options: [:]) { success in cont.resume(returning: success) }
        }
        await dismiss(success: opened,
                      error: opened ? nil : "OnDevice couldn't be opened. Is it installed?")
    }

    @MainActor
    private func dismiss(success: Bool, error: String?) async {
        if !success, let error {
            print("[ShareExtension] \(error)")
        }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
