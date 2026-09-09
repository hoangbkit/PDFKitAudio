import AppKit
import Foundation

/// Internal positioned text unit shared by native PDFKit extraction and Vision OCR.
/// Rectangles use normalized page coordinates with a top-left origin.
struct PdfLayoutFragment {
    let id: Int
    let text: String
    let rect: CGRect
    let source: PdfExtractionSource
    let confidence: Double
    let sourceOrder: Int
    let style: PdfLayoutStyleHints?
    /// Exact PDFKit text ranges when available; OCR has no native character ranges.
    let sourceRanges: [NSRange]

    init(
        id: Int,
        text: String,
        rect: CGRect,
        source: PdfExtractionSource,
        confidence: Double,
        sourceOrder: Int,
        style: PdfLayoutStyleHints? = nil,
        sourceRanges: [NSRange] = []
    ) {
        self.id = id
        self.text = text
        self.rect = rect
        self.source = source
        self.confidence = min(1, max(0, confidence))
        self.sourceOrder = sourceOrder
        self.style = style
        self.sourceRanges = sourceRanges
    }
}

/// Optional hints only. Layout reconstruction must remain correct when these are nil.
struct PdfLayoutStyleHints {
    let fontSize: CGFloat?
    let isBold: Bool?
    let isItalic: Bool?
}
