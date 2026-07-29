import SwiftUI
import PhotosUI
import Vision
import CoreImage

// MARK: - PhotoPickerView
// PHPickerViewController wrapper that returns both the picked image
// and any OCR'd text. Callers decide what to do — typically render the
// image in a chat bubble for the user's eye and include the OCR text
// in the prompt for the LLM. Image-as-code (the prior code-block
// behaviour) is what `text` carries; the image itself comes back so
// the chat UI can show the actual photo.

struct PickedPhoto {
    let image: UIImage
    let ocrText: String
}

struct PhotoPickerView: UIViewControllerRepresentable {
    let onResult: (PickedPhoto) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onResult: (PickedPhoto) -> Void

        init(onResult: @escaping (PickedPhoto) -> Void) {
            self.onResult = onResult
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return }

            result.itemProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { [weak self] data, _ in
                guard let data, let image = UIImage(data: data),
                      let cgImage = image.cgImage else { return }
                self?.runOCR(on: cgImage, with: image)
            }
        }

        private func runOCR(on cgImage: CGImage, with image: UIImage) {
            let request = VNRecognizeTextRequest { [weak self] req, _ in
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                let sorted = observations.sorted {
                    if abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.01 {
                        return $0.boundingBox.minY > $1.boundingBox.minY
                    }
                    return $0.boundingBox.minX < $1.boundingBox.minX
                }
                let text = sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                DispatchQueue.main.async {
                    self?.onResult(PickedPhoto(image: image, ocrText: text))
                }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }
}
