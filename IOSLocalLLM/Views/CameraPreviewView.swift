import SwiftUI
import AVFoundation
import UIKit

// MARK: - CameraPreviewView
// UIViewRepresentable wrapping AVCaptureVideoPreviewLayer.
//
// IMPORTANT: updateUIView is a no-op on purpose. SwiftUI calls updateUIView
// on every parent re-render — and CameraRootView re-renders multiple times
// per second while MLXVisionService is reporting download progress. Calling
// `setNeedsLayout()` here in response to those re-renders caused
// AVCaptureVideoPreviewLayer to spend ~250ms at a partial-size frame, which
// rendered as a centred Dynamic-Island-width translucent strip over the
// camera feed. The preview layer's frame is maintained by `layoutSubviews`
// on real UIView bounds changes — that's enough.

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.backgroundColor = UIColor.black.cgColor
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Intentionally empty — see top-of-file comment.
    }
}

// MARK: - PreviewUIView

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Disable implicit CALayer animation so a frame change can't render
        // a half-sized layer for ~250ms during the implicit fade.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}
