import SwiftUI
import VisionKit
import UIKit

// MARK: - DocumentScannerView
// SwiftUI wrapper around Apple's native VNDocumentCameraViewController.
// Provides 4-corner edge detection, perspective correction, and multi-page
// capture for free, no model required.
//
// Usage:
//   .sheet(isPresented: $showScanner) {
//       DocumentScannerView { images in
//           // images is one UIImage per scanned page
//       }
//   }

struct DocumentScannerView: UIViewControllerRepresentable {

    /// Called with the corrected page images when the user taps "Save",
    /// or with an empty array when they cancel or error out.
    let onCompletion: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController,
                                 context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onCompletion: ([UIImage]) -> Void
        init(onCompletion: @escaping ([UIImage]) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var pages: [UIImage] = []
            pages.reserveCapacity(scan.pageCount)
            for i in 0..<scan.pageCount {
                pages.append(scan.imageOfPage(at: i))
            }
            controller.dismiss(animated: true) {
                self.onCompletion(pages)
            }
        }

        func documentCameraViewControllerDidCancel(
            _ controller: VNDocumentCameraViewController
        ) {
            controller.dismiss(animated: true) { self.onCompletion([]) }
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            controller.dismiss(animated: true) {
                Task { @MainActor in
                    ToastCenter.shared.error("Scanner failed",
                                              detail: error.localizedDescription)
                    self.onCompletion([])
                }
            }
        }
    }
}
