import Foundation

public enum PdfError: Error, LocalizedError {
    case fileNotFound
    case invalidPDF
    case passwordProtected
    case pageOutOfRange
    case ocrFailed(String)
    case extractionFailed

    public var errorDescription: String? {
        switch self {
        case .fileNotFound: return "PDF file not found"
        case .invalidPDF: return "File is not a valid PDF"
        case .passwordProtected: return "PDF is password protected"
        case .pageOutOfRange: return "Page index out of range"
        case .ocrFailed(let msg): return "OCR failed: \(msg)"
        case .extractionFailed: return "Failed to extract text from PDF"
        }
    }
}
