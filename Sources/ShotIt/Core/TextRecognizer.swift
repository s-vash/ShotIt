import AppKit
import Vision

/// OCR + QR/barcode detection using Vision.
enum TextRecognizer {
    struct Result {
        var text: String
        var isBarcode: Bool
    }

    static func recognize(_ image: CGImage, completion: @escaping (Result?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])

            let barcode = VNDetectBarcodesRequest()
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = true

            do {
                try handler.perform([barcode, text])
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let payloads = (barcode.results ?? []).compactMap { $0.payloadStringValue }
            if !payloads.isEmpty {
                DispatchQueue.main.async { completion(Result(text: payloads.joined(separator: "\n"), isBarcode: true)) }
                return
            }

            // Top-to-bottom, then left-to-right (Vision uses bottom-left origin).
            let observations: [VNRecognizedTextObservation] = (text.results ?? []).sorted { a, b in
                let ra: CGRect = a.boundingBox, rb: CGRect = b.boundingBox
                let sameLine = abs(ra.midY - rb.midY) <= min(ra.height, rb.height) / 2
                return sameLine ? ra.minX < rb.minX : ra.midY > rb.midY
            }
            let lines: [String] = observations.compactMap { $0.topCandidates(1).first?.string }
            let joined = lines.joined(separator: AppSettings.shared.ocrRemoveLineBreaks ? " " : "\n")
            DispatchQueue.main.async {
                completion(joined.isEmpty ? nil : Result(text: joined, isBarcode: false))
            }
        }
    }

    /// Recognizes text in `image`, copies it, and reports through a toast.
    static func recognizeAndCopy(_ image: CGImage) {
        recognize(image) { result in
            guard let result else {
                Toast.show("No text detected", style: .error)
                return
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(result.text, forType: .string)
            let preview = result.text.count > 80 ? String(result.text.prefix(80)) + "…" : result.text
            Toast.show(result.isBarcode ? "QR code copied:\n\(preview)" : "Text copied to the clipboard:\n\(preview)")
        }
    }
}
