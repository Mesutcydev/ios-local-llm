import SwiftUI

// DataScannerViewController (VisionKit) is unavailable on Mac Catalyst. On Mac
// the QR pairing path is hidden (isAvailable == false) and users pair via the
// manual code field instead; the #else stub below keeps callers compiling.
// The iOS build path is unchanged.
#if !targetEnvironment(macCatalyst)
import VisionKit

// MARK: - BridgeQRScannerView
// Wraps DataScannerViewController so SwiftUI can show a live camera feed that
// decodes QR codes. Fires `onScanned` exactly once with the raw payload string,
// then stops scanning so the same QR isn't processed twice.

struct BridgeQRScannerView: UIViewControllerRepresentable {

    let onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController,
                                context: Context) {}

    /// Critical: SwiftUI does NOT dispose UIViewControllerRepresentable's
    /// underlying VC automatically when the wrapping sheet dismisses. The
    /// DataScannerViewController keeps the AVCaptureSession alive AND leaves
    /// its scan-target overlay layer parented to the key window, which
    /// renders as a centered vertical white column on top of every other
    /// view in the app (including a different tab). We have to explicitly
    /// stop scanning, remove the VC from its parent, and clear delegates.
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController,
                                           coordinator: Coordinator) {
        uiViewController.stopScanning()
        uiViewController.delegate = nil
        uiViewController.willMove(toParent: nil)
        uiViewController.view.removeFromSuperview()
        uiViewController.removeFromParent()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScanned: onScanned) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScanned: (String) -> Void
        private var fired = false

        init(onScanned: @escaping (String) -> Void) {
            self.onScanned = onScanned
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !fired,
                  let item = addedItems.first,
                  case .barcode(let barcode) = item,
                  let payload = barcode.payloadStringValue else { return }
            fired = true
            dataScanner.stopScanning()
            onScanned(payload)
        }
    }
}

// MARK: - Availability check helper

extension BridgeQRScannerView {
    /// True when the current device supports DataScannerViewController.
    /// (Requires iOS 16+ and a camera — always true on physical iPhones.)
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }
}

#else

// MARK: - Mac Catalyst stub
// No live QR scanning on Mac. `isAvailable` is false so the pairing UI hides
// this path; the view itself never renders but must exist for callers to
// compile.

struct BridgeQRScannerView: View {
    let onScanned: (String) -> Void
    var body: some View { EmptyView() }
    static var isAvailable: Bool { false }
}

#endif
