import UIKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

// MARK: - ShareViewController
// Entry point for the iOS share sheet. Accepts images, plain text, URLs, and
// Safari web pages (NSExtensionJavaScriptPreprocessingResultsKey payload) from
// any host app and stages the content into the App Group container for the
// next time the user opens the main app.
//
// Hand-off URLs:
//   ios-local-llm://share?file=<jpg-name>          → image (lens tab)
//   ios-local-llm://share?text=<percent-encoded>   → text snippet (assistant tab)
//   ios-local-llm://share?url=<percent-encoded>    → URL (assistant tab)
//
// Long text shares (>1500 chars) use file staging to keep the hand-off
// envelope small. The query becomes ?textfile=<txt-name>.

final class ShareViewController: UIViewController {

    // App Group identifier — must match the main app's entitlements.
    private static let appGroupID = "group.com.codelens.shared"

    /// Threshold above which we stash text in a file and hand the
    /// filename to the main app instead of inlining via URL query.
    /// Keep inline encoding work and envelope size small.
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

        // Two passes: first look for an image (highest-fidelity payload),
        // then for text/URL fallbacks. Some share sheets attach BOTH an
        // image and a URL (e.g. Safari's "share page"), and the user
        // almost always wants the image when one is present.
        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                do {
                    let imageData = try await loadImageData(from: attachment)
                    let stagedURL = try writeToAppGroup(imageData,
                                                       subdir: "SharedImages",
                                                       ext: "jpg")
                    do {
                        let openURL = try imageOpenURL(for: stagedURL)
                        await saveForMainApp(openURL, stagedFile: stagedURL)
                    } catch {
                        try? FileManager.default.removeItem(at: stagedURL)
                        throw error
                    }
                    return
                } catch {
                    // Don't dismiss on image failure — fall through to
                    // text/URL handling so a Safari "share page" still
                    // works when the page screenshot can't be decoded.
                    print("[ShareExtension] image load failed")
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
        // Avoid staging empty content or unnecessary surrounding whitespace.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await dismiss(success: false, error: "Empty text")
            return
        }

        if trimmed.count <= Self.inlineTextLimit,
           let url = try? handOffURL(queryName: "text", value: trimmed) {
            await saveForMainApp(url)
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
                await saveForMainApp(openURL, stagedFile: stagedURL)
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                throw error
            }
        } catch {
            await dismiss(success: false, error: error.localizedDescription)
        }
    }

    private func handOffURL(_ url: URL) async {
        guard let openURL = try? handOffURL(queryName: "url", value: url.absoluteString) else {
            await dismiss(success: false, error: "Couldn't save the shared link")
            return
        }
        await saveForMainApp(openURL)
    }

    private func imageOpenURL(for stagedURL: URL) throws -> URL {
        try handOffURL(queryName: "file", value: stagedURL.lastPathComponent)
    }

    private func handOffURL(queryName: String, value: String) throws -> URL {
        try SharedContentInbox.handOffURL(queryName: queryName, value: value)
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
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
    private func saveForMainApp(_ url: URL, stagedFile: URL? = nil) async {
        var saved = false
        defer {
            if !saved, let stagedFile { try? FileManager.default.removeItem(at: stagedFile) }
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            await dismiss(success: false, error: "Shared storage is unavailable. Try opening OnDevice LLM first.")
            return
        }
        do {
            try SharedContentInbox.save(url, in: container)
            saved = true
            showResult(saved: true, message: "Open OnDevice LLM to use your shared content. It is saved on this device.")
        } catch {
            showResult(saved: false, message: "Your content could not be saved. Try sharing it again.")
        }
    }

    @MainActor
    private func dismiss(success: Bool, error: String?) async {
        if success {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        } else {
            showResult(saved: false, message: error ?? "Your content could not be saved.")
        }
    }

    private static var shareLocale: Locale {
        let choice = UserDefaults(suiteName: appGroupID)?.string(forKey: "uiLanguage") ?? "system"
        return choice == "system" ? .current : Locale(identifier: choice)
    }

    @MainActor
    private func showResult(saved: Bool, message: String) {
        let result = UIHostingController(rootView: ShareResultView(saved: saved, message: message) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        .environment(\.locale, Self.shareLocale)
        .environment(\.layoutDirection, Self.shareLocale.language.languageCode?.identifier == "ar" ? .rightToLeft : .leftToRight))
        addChild(result)
        result.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(result.view)
        NSLayoutConstraint.activate([
            result.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            result.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            result.view.topAnchor.constraint(equalTo: view.topAnchor),
            result.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        result.didMove(toParent: self)
    }
}

private struct ShareResultView: View {
    let saved: Bool
    let message: String
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: saved ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(saved ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(saved ? "Saved to OnDevice LLM" : "Couldn't save share"))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(LocalizedStringKey(message))
                    .multilineTextAlignment(.center)
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("share.done")
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}
