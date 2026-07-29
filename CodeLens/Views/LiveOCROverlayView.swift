import SwiftUI

// MARK: - LiveOCROverlayView
// Draws hairline boxes over text recognised by LiveOCRService. Tap a box to
// copy its text + send it to the assistant. Toggle button lives in the
// camera HUD.

struct LiveOCROverlayView: View {
    @ObservedObject private var ocr = LiveOCRService.shared
    @Environment(\.koduTheme) private var T

    /// Container size — used to convert normalised Vision rects to screen.
    let containerSize: CGSize

    var body: some View {
        ForEach(ocr.recognised) { box in
            highlightBox(for: box)
        }
    }

    @ViewBuilder
    private func highlightBox(for box: LiveOCRService.OCRBox) -> some View {
        // Vision uses bottom-left origin; SwiftUI uses top-left.
        let r = CGRect(
            x: box.rect.minX * containerSize.width,
            y: (1 - box.rect.maxY) * containerSize.height,
            width: box.rect.width * containerSize.width,
            height: box.rect.height * containerSize.height
        )
        Rectangle()
            .stroke(T.accent.opacity(0.7), lineWidth: 1)
            .background(
                Rectangle().fill(T.accent.opacity(0.08))
            )
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .contentShape(Rectangle())
            .onTapGesture {
                UIPasteboard.general.string = box.text
                HapticManager.impact(.light)
                ToastCenter.shared.info("Copied: \(box.text.prefix(40))")
            }
            // Long-press opens an action menu so power users can fire the
            // detected text straight into the assistant without going through
            // the capture button.
            .contextMenu {
                Button {
                    UIPasteboard.general.string = box.text
                    HapticManager.impact(.light)
                    ToastCenter.shared.info("Copied")
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button {
                    // Send to assistant tab via AppBridge — same path as
                    // camera capture flow.
                    AppBridge.shared.sendToAssistant(code: box.text, source: "Live OCR")
                    HapticManager.impact(.medium)
                    ToastCenter.shared.success("Sent to assistant")
                } label: { Label("Send to Assistant", systemImage: "brain") }
            }
    }
}
