import Foundation

/// Whole-document failures surfaced by `PdfParser`.
///
/// Page-level OCR misses are intentionally resilient: the parser keeps native text
/// when possible or records an empty page instead of exposing dead/unused throw
/// cases for recoverable extraction details.
public enum PdfError: Error, LocalizedError, Equatable, Sendable {
    case fileNotFound
    case invalidPDF
    case passwordProtected

    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "PDF file not found"
        case .invalidPDF:
            return "File is not a valid PDF"
        case .passwordProtected:
            return "PDF is password protected"
        }
    }
}
