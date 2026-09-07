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

    init(
        id: Int,
        text: String,
        rect: CGRect,
        source: PdfExtractionSource,
        confidence: Double,
        sourceOrder: Int,
        style: PdfLayoutStyleHints? = nil
    ) {
        self.id = id
        self.text = text
        self.rect = rect
        self.source = source
        self.confidence = min(1, max(0, confidence))
        self.sourceOrder = sourceOrder
        self.style = style
    }
}

/// Optional hints only. Layout reconstruction must remain correct when these are nil.
struct PdfLayoutStyleHints {
    let fontSize: CGFloat?
    let isBold: Bool?
    let isItalic: Bool?
}
