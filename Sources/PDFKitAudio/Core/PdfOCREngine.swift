import Foundation
import PDFKit
import AppKit
import Vision

enum PdfOCREngine {
    struct OCRResult {
        let text: String
        let confidence: Double
    }

    static func recognize(page: PDFPage) -> OCRResult? {
        // Render PDFPage to high-res image for Vision
        let targetSize = CGSize(width: 1700, height: 2200) // ~200 DPI for US Letter
        let thumb = page.thumbnail(of: targetSize, for: .mediaBox)

        guard let cgImage = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // Fallback: draw via NSImage representation
            guard let tiff = thumb.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let cg = bitmap.cgImage else { return nil }
            return recognize(cgImage: cg)
        }
        return recognize(cgImage: cgImage)
    }

    private static func recognize(cgImage: CGImage) -> OCRResult? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results else { return OCRResult(text: "", confidence: 0) }

        var fullText = ""
        var confidences: [Float] = []

        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            fullText += candidate.string + "\n"
            confidences.append(candidate.confidence)
        }
        let avgConfidence = confidences.isEmpty ? 0 : Double(confidences.reduce(0, +) / Float(confidences.count))
        return OCRResult(text: fullText.trimmingCharacters(in: .whitespacesAndNewlines), confidence: avgConfidence)
    }

    // Batch check to decide if PDF is scanned
    static func isScanned(document: PDFDocument, sampleCount: Int = 5) -> Bool {
        let total = document.pageCount
        guard total > 0 else { return false }
        let step = max(1, total / sampleCount)
        var emptyPages = 0
        var checked = 0
        for i in stride(from: 0, to: total, by: step).prefix(sampleCount) {
            guard let page = document.page(at: i) else { continue }
            let s = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if s.count < 30 { emptyPages += 1 }
            checked += 1
        }
        return checked > 0 && Double(emptyPages) / Double(checked) >= 0.6
    }
}
