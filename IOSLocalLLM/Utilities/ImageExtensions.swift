import UIKit
import CoreImage
import CoreVideo
import Vision

// MARK: - CVPixelBuffer helpers

extension CVPixelBuffer {
    /// Crops a region defined by a normalized CGRect (Vision coordinate space, bottom-left origin).
    func croppingToNormalizedBox(_ box: CGRect) -> CVPixelBuffer? {
        let w = CGFloat(CVPixelBufferGetWidth(self))
        let h = CGFloat(CVPixelBufferGetHeight(self))

        // Flip Y for CIImage (top-left origin)
        let cropRect = CGRect(
            x: box.minX * w,
            y: (1 - box.maxY) * h,
            width: box.width * w,
            height: box.height * h
        ).integral

        guard cropRect.width > 10, cropRect.height > 10 else { return nil }

        let ciImage = CIImage(cvPixelBuffer: self).cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        var output: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(cropRect.width), Int(cropRect.height),
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nil, &output
        )
        guard let out = output else { return nil }
        CIContext(options: [.useSoftwareRenderer: false]).render(ciImage, to: out)
        return out
    }

    /// Converts to UIImage for debugging / display.
    var uiImage: UIImage? {
        let ciImage = CIImage(cvPixelBuffer: self)
        let ctx = CIContext()
        guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    var width: Int { CVPixelBufferGetWidth(self) }
    var height: Int { CVPixelBufferGetHeight(self) }
}

// MARK: - CGRect helpers for Vision coordinate transforms

extension CGRect {
    /// Converts a normalized Vision rect (bottom-left origin) to a SwiftUI/UIKit rect (top-left origin)
    /// within the given container size.
    func toViewRect(in containerSize: CGSize) -> CGRect {
        CGRect(
            x: minX * containerSize.width,
            y: (1 - maxY) * containerSize.height,
            width: width * containerSize.width,
            height: height * containerSize.height
        )
    }
}

// MARK: - Color helpers

extension UIColor {
    static let terminalGreen = UIColor(red: 0.18, green: 0.87, blue: 0.45, alpha: 1)
    static let terminalAmber = UIColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 1)
}
