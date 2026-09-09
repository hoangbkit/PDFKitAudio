import Foundation

/// Consolidated configuration for `PdfParser`.
///
/// PDFKitAudio is intentionally macOS-only. The defaults are tuned for long-lived
/// document-to-audio workflows: native PDF text first, selective Vision OCR,
/// conservative automatic layout reconstruction, audiobook cleanup, bounded
/// cover generation, and retained native text for diagnostics.
public struct PdfParserConfiguration: Hashable, Sendable {
    public var ocr: PdfOCRConfiguration
    public var layout: PdfLayoutConfiguration
    public var cleanup: PdfCleanupConfiguration
    public var extractCoverImage: Bool

    /// Retains the raw PDFKit text in each `PdfPageContent.nativeText` value.
    /// Disable this for large/bulk imports when downstream diagnostics do not need
    /// the rejected native source. Selected spoken text and provenance are kept.
    public var retainNativeText: Bool

    public init(
        ocr: PdfOCRConfiguration = PdfOCRConfiguration(),
        layout: PdfLayoutConfiguration = PdfLayoutConfiguration(),
        cleanup: PdfCleanupConfiguration = .audiobookDefault,
        extractCoverImage: Bool = true,
        retainNativeText: Bool = true
    ) {
        self.ocr = ocr
        self.layout = layout
        self.cleanup = cleanup
        self.extractCoverImage = extractCoverImage
        self.retainNativeText = retainNativeText
    }
}
