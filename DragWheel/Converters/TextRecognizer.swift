import Foundation
import Vision
import CoreGraphics

/// On-device OCR using the Vision framework.
enum TextRecognizer {
    /// Recognised text in reading order (lines top-to-bottom, words left-to-right). Empty if none.
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results ?? []).compactMap { obs -> (box: CGRect, text: String)? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return (obs.boundingBox, text)
        }
        return assemble(observations)
    }

    /// Groups observations into lines (Vision's coordinates have their origin at the bottom left).
    static func assemble(_ items: [(box: CGRect, text: String)]) -> String {
        let sorted = items.sorted { $0.box.midY > $1.box.midY }
        var lines: [[(box: CGRect, text: String)]] = []
        for item in sorted {
            if let last = lines.last?.last, abs(last.box.midY - item.box.midY) < min(last.box.height, item.box.height) / 2 {
                lines[lines.count - 1].append(item)
            } else {
                lines.append([item])
            }
        }
        return lines
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}
