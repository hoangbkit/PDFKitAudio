import Foundation

/// High-level stages emitted while asynchronously parsing a PDF.
///
/// Page extraction is the only stage with incremental page counts. Later
/// document-wide stages report the full page count so callers can update status
/// text without treating those stages as additional pages of work.
public enum PdfParseStage: String, Sendable, Equatable, CaseIterable {
    case loading
    case extracting
    case cleaning
    case buildingChapters
    case finishing
    case finished
}

/// Lightweight progress snapshot for long-running PDF imports.
public struct PdfParseProgress: Sendable, Equatable {
    public let stage: PdfParseStage
    public let completedPages: Int
    public let totalPages: Int

    public init(
        stage: PdfParseStage,
        completedPages: Int,
        totalPages: Int
    ) {
        let normalizedTotal = max(0, totalPages)
        self.stage = stage
        self.totalPages = normalizedTotal
        self.completedPages = normalizedTotal == 0
            ? 0
            : min(max(0, completedPages), normalizedTotal)
    }

    /// Fraction of source pages extracted so far when the total is known.
    ///
    /// This is intentionally page progress rather than an invented weighted
    /// estimate for cleanup/chapter/cover work.
    public var pageFractionCompleted: Double? {
        guard totalPages > 0 else { return nil }
        return Double(completedPages) / Double(totalPages)
    }
}
