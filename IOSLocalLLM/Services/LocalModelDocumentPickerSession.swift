import UIKit
import UniformTypeIdentifiers

/// Strongly retained document picker for local model import.
///
/// Why this exists (AltServer works, ForgeSign/sideload often doesn't):
/// 1. SwiftUI representable coordinators are deallocated while Files is up —
///    `delegate` is weak, so Open looks enabled then does nothing. This
///    singleton owns the picker + delegate for the whole presentation.
/// 2. Folder and file modes must stay separate — mixing folder UTIs with
///    file UTIs greys out selection on many providers.
/// 3. Folders **cannot** use `asCopy: true` — UIDocumentPicker aborts when
///    asked to copy a directory (build 100 crash). Folders use open-in-place
///    (`asCopy: false`) + security-scoped access. Complete model files use
///    `asCopy: true` (BellLink sideload path).
/// 4. Hold the security scope across the async import handoff — clearing the
///    picker immediately used to invalidate folder URLs before copy started.
@MainActor
final class LocalModelDocumentPickerSession: NSObject, UIDocumentPickerDelegate {
    static let shared = LocalModelDocumentPickerSession()

    /// True when open-in-place folder picking is expected to work on this
    /// install. Open-in-place hands the app a security-scoped URL to content
    /// *outside* its sandbox, which iOS only reliably grants to App Store /
    /// TestFlight signatures. A concrete `application-identifier` is necessary
    /// but NOT sufficient: resigned/sideloaded builds (AltStore, ForgeSign,
    /// dev, ad-hoc, enterprise) can still have the File Provider deny the grant
    /// even with a concrete identity — the folder looks selectable but "Open"
    /// does nothing. Route folder imports through the in-sandbox App Documents
    /// browser (`LocalModelDocumentsImportSheet`) on those builds; single-file
    /// (`asCopy: true`) imports are unaffected and keep using the picker.
    static var openInPlacePickingIsUsable: Bool {
        LASAppIdentity.hasConcreteApplicationIdentifier
            && LASAppIdentity.openInPlaceFileProviderGrantsAreReliable
    }

    enum Kind: Equatable {
        case folder
        case file
    }

    private var onPick: ((URL) -> Void)?
    private var onCancel: (() -> Void)?
    private var picker: UIDocumentPickerViewController?
    private var presentationToken = UUID()
    /// Kept alive so folder security-scoped URLs survive until import finishes.
    private var activeSecurityURL: URL?

    private override init() {
        super.init()
    }

    func present(
        kind: Kind,
        onPick: @escaping (URL) async -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        if let existing = picker {
            existing.delegate = nil
            if existing.presentingViewController != nil {
                existing.dismiss(animated: false)
            }
        }
        picker = nil
        releaseSecurityScope()

        // Keep the security scope open for the whole async copy, then release.
        self.onPick = { url in
            Task { @MainActor in
                defer { self.finishPick(url) }
                await onPick(url)
            }
        }
        self.onCancel = onCancel

        let picker = makePicker(kind: kind)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = self
        self.picker = picker

        let token = UUID()
        presentationToken = token
        presentWhenReady(picker, token: token, attempt: 0)
    }

    private func makePicker(kind: Kind) -> UIDocumentPickerViewController {
        switch kind {
        case .folder:
            // Directory access requires open-in-place. asCopy:true crashes.
            return UIDocumentPickerViewController(
                forOpeningContentTypes: [.folder, .directory],
                asCopy: false
            )
        case .file:
            // Copy into the app sandbox — BellLink's proven sideload path.
            return UIDocumentPickerViewController(
                forOpeningContentTypes: LocalModelImportService.acceptedTypes(for: .file),
                asCopy: true
            )
        }
    }

    private func presentWhenReady(
        _ picker: UIDocumentPickerViewController,
        token: UUID,
        attempt: Int
    ) {
        // Wait out SwiftUI Menu / popover dismissal before presenting.
        let delay: TimeInterval = attempt == 0 ? 0.45 : 0.12
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.presentationToken == token, self.picker === picker else { return }
            picker.delegate = self

            guard let presenter = Self.topPresenter() else {
                if attempt < 20 {
                    self.presentWhenReady(picker, token: token, attempt: attempt + 1)
                } else {
                    self.finishCancel()
                }
                return
            }

            if presenter.presentedViewController != nil
                || presenter.isBeingDismissed
                || presenter.isBeingPresented {
                if attempt < 20 {
                    self.presentWhenReady(picker, token: token, attempt: attempt + 1)
                } else {
                    self.finishCancel()
                }
                return
            }

            presenter.present(picker, animated: true)
        }
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else {
            finishCancel()
            return
        }

        releaseSecurityScope()
        if url.startAccessingSecurityScopedResource() {
            activeSecurityURL = url
        }

        let pick = onPick
        onPick = nil
        onCancel = nil
        pick?(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishCancel()
    }

    /// Call when an import started from ``present`` has finished (success or failure).
    func finishPick(_ url: URL) {
        if activeSecurityURL == url {
            releaseSecurityScope()
        }
        clearPickerUI()
    }

    private func finishCancel() {
        let cancel = onCancel
        onPick = nil
        onCancel = nil
        releaseSecurityScope()
        clearPickerUI()
        cancel?()
    }

    private func releaseSecurityScope() {
        if let url = activeSecurityURL {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityURL = nil
    }

    private func clearPickerUI() {
        picker?.delegate = nil
        picker = nil
    }

    private static func topPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        if top.isBeingDismissed {
            return top.presentingViewController ?? top
        }
        return top
    }
}
