import SwiftUI
import UniformTypeIdentifiers

// MARK: - FileAttachmentPicker
// UIDocumentPickerViewController wrapped for SwiftUI. Caller passes the
// existing attachments so we can refuse on cap overflow. The picker allows
// multi-select but we trim to the remaining slot count.

struct FileAttachmentPicker: UIViewControllerRepresentable {

    /// Currently attached files — used to compute the remaining slot count.
    let existing: [FileAttachmentService.Attachment]
    /// Called with successfully-decoded attachments and a list of human-
    /// readable error messages (one per failed file).
    let onPick: ([FileAttachmentService.Attachment], [String]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Allow text, code, markdown, JSON, PDF, and plain-text fallbacks.
        let types: [UTType] = [
            .plainText, .utf8PlainText, .text, .sourceCode, .pdf,
            .json, .xml, .yaml, .commaSeparatedText, .tabSeparatedText,
            // Common code types iOS reports as conforming to .sourceCode
            // but they sometimes also report as their own UTI.
            UTType(filenameExtension: "swift") ?? .sourceCode,
            UTType(filenameExtension: "py") ?? .sourceCode,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "ts") ?? .sourceCode,
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(existing: existing, onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let existing: [FileAttachmentService.Attachment]
        let onPick: ([FileAttachmentService.Attachment], [String]) -> Void
        let onCancel: () -> Void

        init(existing: [FileAttachmentService.Attachment],
             onPick: @escaping ([FileAttachmentService.Attachment], [String]) -> Void,
             onCancel: @escaping () -> Void) {
            self.existing = existing
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                             didPickDocumentsAt urls: [URL]) {
            let remaining = max(0,
                FileAttachmentService.maxAttachmentsPerSend - existing.count)
            let toRead = Array(urls.prefix(remaining))

            Task { @MainActor in
                var ok: [FileAttachmentService.Attachment] = []
                var errors: [String] = []
                var running = existing
                for url in toRead {
                    do {
                        let att = try await FileAttachmentService.read(url)
                        switch FileAttachmentService.canAttach(att, to: running) {
                        case .success:
                            ok.append(att)
                            running.append(att)
                        case .failure(let e):
                            errors.append("\(url.lastPathComponent): \(e.localizedDescription)")
                        }
                    } catch let e as AttachmentError {
                        errors.append("\(url.lastPathComponent): \(e.localizedDescription)")
                    } catch {
                        errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                if urls.count > remaining {
                    errors.append("Skipped \(urls.count - remaining) — limit is \(FileAttachmentService.maxAttachmentsPerSend) files per message.")
                }
                self.onPick(ok, errors)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
