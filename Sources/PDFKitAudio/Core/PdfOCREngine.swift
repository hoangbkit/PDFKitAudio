import AppKit
import Foundation
import PDFKit
import Vision

enum PdfOCREngine {
    struct OCRResult {
        let text: String
        let confidence: Double
    }

    static func recognize(page: PDFPage, configuration: PdfOCRConfiguration) -> OCRResult? {
        let targetSize = renderSize(for: page)
        let thumbnail = page.thumbnail(of: targetSize, for: .mediaBox)

        if let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return recognize(cgImage: cgImage, configuration: configuration)
        }

        guard let tiff = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else {
            return nil
        }
        return recognize(cgImage: cgImage, configuration: configuration)
    }

    static func makeRequest(configuration: PdfOCRConfiguration) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        switch configuration.recognitionLevel {
        case .fast:
            request.recognitionLevel = .fast
        case .accurate:
            request.recognitionLevel = .accurate
        }
        request.usesLanguageCorrection = configuration.usesLanguageCorrection
        request.automaticallyDetectsLanguage = configuration.automaticallyDetectsLanguage

        // Leave Vision's language list untouched when callers do not supply one.
        // With automatic detection enabled this avoids hard-coding a package-level
        // English preference while still using Vision's platform defaults.
        if !configuration.recognitionLanguages.isEmpty {
            request.recognitionLanguages = configuration.recognitionLanguages
        }

        return request
    }

    private static func recognize(
        cgImage: CGImage,
        configuration: PdfOCRConfiguration
    ) -> OCRResult? {
        let request = makeRequest(configuration: configuration)
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results else {
            return OCRResult(text: "", confidence: 0)
        }

        var lines: [String] = []
        var confidences: [Float] = []
        lines.reserveCapacity(observations.count)
        confidences.reserveCapacity(observations.count)

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            lines.append(candidate.string)
            confidences.append(candidate.confidence)
        }

        let averageConfidence = confidences.isEmpty
            ? 0
            : Double(confidences.reduce(0, +) / Float(confidences.count))
        return OCRResult(
            text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: averageConfidence
        )
    }

    private static func renderSize(for page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .mediaBox).standardized
        guard bounds.width > 0, bounds.height > 0 else {
            return CGSize(width: 1700, height: 2200)
        }

        let maximumDimension: CGFloat = 2200
        let sourceMaximum = max(bounds.width, bounds.height)
        let scale = min(3.0, maximumDimension / sourceMaximum)
        return CGSize(
            width: max(1, floor(bounds.width * scale)),
            height: max(1, floor(bounds.height * scale))
        )
    }

    // Lightweight metadata hint only. Per-page OCR decisions are made separately.
    static func isScanned(document: PDFDocument, sampleCount: Int = 5) -> Bool {
        let total = document.pageCount
        guard total > 0 else { return false }
        let step = max(1, total / sampleCount)
        var emptyPages = 0
        var checked = 0

        for index in stride(from: 0, to: total, by: step).prefix(sampleCount) {
            guard let page = document.page(at: index) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count < 30 { emptyPages += 1 }
            checked += 1
        }

        return checked > 0 && Double(emptyPages) / Double(checked) >= 0.6
    }
}
