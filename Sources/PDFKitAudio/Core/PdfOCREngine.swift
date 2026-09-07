import AppKit
import Foundation
import PDFKit
import Vision

enum PdfOCREngine {
    struct OCRObservation {
        let text: String
        let rect: CGRect
        let confidence: Double
        let sourceOrder: Int

        init(
            text: String,
            rect: CGRect,
            confidence: Double,
            sourceOrder: Int
        ) {
            self.text = text
            self.rect = rect
            self.confidence = min(1, max(0, confidence))
            self.sourceOrder = sourceOrder
        }
    }

    struct OCRResult {
        let text: String
        let confidence: Double
        let observations: [OCRObservation]

        init(
            text: String,
            confidence: Double,
            observations: [OCRObservation] = []
        ) {
            self.text = text
            self.confidence = min(1, max(0, confidence))
            self.observations = observations
        }
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

        guard let results = request.results else {
            return OCRResult(text: "", confidence: 0)
        }

        var observations: [OCRObservation] = []
        observations.reserveCapacity(results.count)

        for (sourceOrder, observation) in results.enumerated() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            observations.append(OCRObservation(
                text: candidate.string,
                rect: PdfLayoutGeometry.normalizedVisionRect(observation.boundingBox),
                confidence: Double(candidate.confidence),
                sourceOrder: sourceOrder
            ))
        }

        let averageConfidence = observations.isEmpty
            ? 0
            : observations.reduce(0) { $0 + $1.confidence } / Double(observations.count)
        return OCRResult(
            text: observations
                .map(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: averageConfidence,
            observations: observations
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
