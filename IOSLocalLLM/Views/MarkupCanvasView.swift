import SwiftUI
import PencilKit
import UIKit

// MARK: - MarkupCanvasView
// Wraps PencilKit so the user can annotate the captured image before
// sending it to FastVLM. Output is a flattened UIImage (drawing burned in).

struct MarkupCanvasView: View {
    let baseImage: UIImage
    let onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    @State private var canvas = PKCanvasView()
    @State private var toolPicker = PKToolPicker()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                GeometryReader { geo in
                    ZStack {
                        Image(uiImage: baseImage)
                            .resizable()
                            .scaledToFit()
                        PKCanvasViewRepresentable(canvas: $canvas,
                                                  toolPicker: $toolPicker)
                            .background(Color.clear)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .navigationTitle("annotate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use") {
                        let flattened = flatten()
                        onDone(flattened)
                        dismiss()
                    }
                    .foregroundColor(.white)
                    .fontWeight(.semibold)
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    /// Renders the base image with the drawing burned on top.
    private func flatten() -> UIImage {
        let size = baseImage.size
        let scale = baseImage.scale
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        defer { UIGraphicsEndImageContext() }

        baseImage.draw(in: CGRect(origin: .zero, size: size))

        // Render the PencilKit drawing into the same space.
        let drawing = canvas.drawing
        let canvasSize = canvas.bounds.size
        guard canvasSize.width > 0 else { return baseImage }

        let scaleX = size.width / canvasSize.width
        let scaleY = size.height / canvasSize.height

        if let ctx = UIGraphicsGetCurrentContext() {
            ctx.saveGState()
            ctx.scaleBy(x: scaleX, y: scaleY)
            let drawingImage = drawing.image(from: canvas.bounds, scale: 1.0)
            drawingImage.draw(in: canvas.bounds)
            ctx.restoreGState()
        }
        return UIGraphicsGetImageFromCurrentImageContext() ?? baseImage
    }
}

// MARK: - PKCanvasViewRepresentable

private struct PKCanvasViewRepresentable: UIViewRepresentable {
    @Binding var canvas: PKCanvasView
    @Binding var toolPicker: PKToolPicker

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        toolPicker.setVisible(true, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)
        canvas.becomeFirstResponder()
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}
