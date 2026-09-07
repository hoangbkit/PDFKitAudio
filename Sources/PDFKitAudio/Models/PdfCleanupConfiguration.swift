import Foundation

/// Controls lightweight text cleanup after PDF text extraction.
///
/// The defaults are designed for audiobook preparation: safe page-local
/// normalization plus conservative document-level suppression of running matter.
/// Heuristic thresholds intentionally remain package-owned so callers configure
/// behavior rather than implementation details.
public struct PdfCleanupConfiguration: Hashable, Sendable {
    /// Suppress short header/footer lines that recur near the same page edge.
    /// The first semantic occurrence is retained to avoid deleting real headings.
    public var removesRepeatedHeadersAndFooters: Bool

    /// Remove numeric pagination only when multiple pages establish a sequential
    /// page-number pattern at a page edge.
    public var removesSequentialPageNumbers: Bool

    /// Join obvious words split by a discretionary line-wrap hyphen.
    public var dehyphenatesLineWraps: Bool

    public init(
        removesRepeatedHeadersAndFooters: Bool = true,
        removesSequentialPageNumbers: Bool = true,
        dehyphenatesLineWraps: Bool = true
    ) {
        self.removesRepeatedHeadersAndFooters = removesRepeatedHeadersAndFooters
        self.removesSequentialPageNumbers = removesSequentialPageNumbers
        self.dehyphenatesLineWraps = dehyphenatesLineWraps
    }

    /// Recommended cleanup for text that will be spoken aloud.
    public static let audiobookDefault = PdfCleanupConfiguration()

    /// Safe page-local normalization only. Useful when callers need source text
    /// with line structure preserved and want no document-level suppression.
    public static let minimal = PdfCleanupConfiguration(
        removesRepeatedHeadersAndFooters: false,
        removesSequentialPageNumbers: false,
        dehyphenatesLineWraps: false
    )
}
