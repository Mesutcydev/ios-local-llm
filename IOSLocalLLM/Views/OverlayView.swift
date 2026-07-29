import SwiftUI

// MARK: - OverlayView
// Draws YOLO bounding boxes, confidence labels, and tap targets
// over the live camera feed. Coordinates are normalized (0–1).

struct OverlayView: View {
    let detections: [Detection]
    let frameSize: CGSize
    let onTap: (Detection) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(detections) { detection in
                    DetectionBoxView(
                        detection: detection,
                        containerSize: geo.size,
                        onTap: onTap
                    )
                }
            }
        }
    }
}

// MARK: - DetectionBoxView

struct DetectionBoxView: View {
    let detection: Detection
    let containerSize: CGSize
    let onTap: (Detection) -> Void

    @State private var isPressed = false
    @Environment(\.koduTheme) private var T

    private var rect: CGRect {
        // Vision boxes: origin bottom-left, y-flipped for SwiftUI
        let box = detection.boundingBox
        return CGRect(
            x: box.minX * containerSize.width,
            y: (1 - box.maxY) * containerSize.height,
            width: box.width * containerSize.width,
            height: box.height * containerSize.height
        )
    }

    private var boxColor: Color {
        detection.confidence >= 0.75 ? T.accent : T.warn
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Bounding box — clean 1px stroke, subtle accent fill
            RoundedRectangle(cornerRadius: 4)
                .stroke(boxColor, lineWidth: isPressed ? 2 : 1.5)
                .frame(width: rect.width, height: rect.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(boxColor.opacity(isPressed ? 0.12 : 0.05))
                )

            // Label chip — flat rectangle in the surface color
            HStack(spacing: 4) {
                Text(detection.label.lowercased())
                    .font(T.mono(10, .semibold))
                    .tracking(0.3)
                Text(String(format: "%.0f%%", detection.confidence * 100))
                    .font(T.mono(10))
                    .foregroundColor(T.ink3)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.15), value: detection.confidence)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3).fill(T.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3).stroke(boxColor, lineWidth: 1)
            )
            .foregroundColor(boxColor)
            .offset(y: -22)
        }
        .position(x: rect.midX, y: rect.midY)
        .onTapGesture {
            withAnimation(.easeIn(duration: 0.1)) { isPressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeOut(duration: 0.1)) { isPressed = false }
                onTap(detection)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: detection.confidence)
    }
}

