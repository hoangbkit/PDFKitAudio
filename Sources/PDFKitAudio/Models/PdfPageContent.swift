import Foundation

/// How the selected text for a PDF page was obtained.
public enum PdfExtractionSource: String, Hashable, Sendable {
    /// Selectable text extracted directly by PDFKit.
    case native
    /// Text recognized from a rendered page image by Vision OCR.
    case ocr
    /// No usable text remained after extraction and page-local cleanup.
    case empty
}

/// Canonical page-level text and provenance retained by `PdfBook`.
///
/// Page indexes are zero-based and map directly to the source `PDFDocument`.
/// Keeping a deterministic page identity prevents downstream chapter or segment
/// transforms from losing their relationship to the original PDF.
public struct PdfPageContent: Identifiable, Hashable, Sendable {
    /// Stable identity for this page. Equal to `pageIndex`.
    public var id: Int { pageIndex }

    /// Zero-based page index in the source PDF.
    public let pageIndex: Int

    /// Native PDFKit text before page-local cleanup.
    ///
    /// This is retained even when OCR is selected so callers can diagnose why
    /// native extraction was rejected. It is intentionally not used for speech.
    public let nativeText: String

    /// Selected, cleaned text used by chapters and audiobook generation.
    public let text: String

    /// Source used for `text`.
    public let extractionSource: PdfExtractionSource

    /// Confidence in the selected extraction, normalized to `0...1`.
    /// Native text uses `1`, empty pages use `0`, and OCR uses Vision confidence.
    public let confidence: Double

    public init(
        pageIndex: Int,
        nativeText: String,
        text: String,
        extractionSource: PdfExtractionSource,
        confidence: Double
    ) {
        self.pageIndex = pageIndex
        self.nativeText = nativeText
        self.text = text
        self.extractionSource = extractionSource
        self.confidence = min(1, max(0, confidence))
    }

    public var isOCRSourced: Bool { extractionSource == .ocr }
    public var isEmpty: Bool { extractionSource == .empty || text.isEmpty }
}
