import Foundation

/// Controls when Vision OCR is attempted.
public enum OCROptions: Hashable, Sendable {
    /// OCR only pages whose native PDF text is missing, too short, or suspicious.
    case auto
    /// Attempt OCR for every page, while still keeping native text when it is better.
    case always
    /// Never run OCR.
    case never
}

/// Package-owned recognition level so callers do not need to import Vision.
public enum PdfOCRRecognitionLevel: Hashable, Sendable {
    case fast
    case accurate
}

/// Lightweight OCR configuration used by `PdfParser`.
///
/// The default configuration keeps native PDFKit extraction as the fast path,
/// enables Vision's automatic language detection, and does not hard-code English.
public struct PdfOCRConfiguration: Hashable, Sendable {
    public var mode: OCROptions
    public var nativeTextThreshold: Int
    public var recognitionLanguages: [String]
    public var automaticallyDetectsLanguage: Bool
    public var recognitionLevel: PdfOCRRecognitionLevel
    public var usesLanguageCorrection: Bool

    public init(
        mode: OCROptions = .auto,
        nativeTextThreshold: Int = 20,
        recognitionLanguages: [String] = [],
        automaticallyDetectsLanguage: Bool = true,
        recognitionLevel: PdfOCRRecognitionLevel = .accurate,
        usesLanguageCorrection: Bool = true
    ) {
        self.mode = mode
        self.nativeTextThreshold = max(0, nativeTextThreshold)
        self.recognitionLanguages = Self.normalizedLanguages(recognitionLanguages)
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    private static func normalizedLanguages(_ languages: [String]) -> [String] {
        var seen: Set<String> = []
        return languages.compactMap { language in
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}
