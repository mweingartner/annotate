import CoreGraphics
import Foundation
import Vision

struct PDFOCRLine: Sendable {
    let text: String
    let bounds: CGRect
}

/// A separate actor keeps Vision's synchronous recognition work off the UI executor.
actor PDFOCRRecognizer {
    func recognize(image: CGImage, languages: [String]) throws -> [PDFOCRLine] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = languages.isEmpty
        if !languages.isEmpty {
            let supported = try request.supportedRecognitionLanguages()
            guard languages.allSatisfy({ supported.contains($0) }) else {
                throw NSError(domain: "AnnotateOCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected OCR language is unavailable on this Mac."])
            }
            request.recognitionLanguages = languages
        }
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return PDFOCRLine(text: candidate.string, bounds: observation.boundingBox)
        }
    }
}
