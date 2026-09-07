import Foundation

/// Immutable audiobook chapter derived from canonical PDF pages.
public struct PdfChapter: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let pageRange: ClosedRange<Int>
    public let order: Int
    public let plainText: String
    public let htmlPreview: String
    public let confidence: Double
    public let isOCRSourced: Bool

    /// Derived from immutable `plainText`, so the value can never become stale.
    public var wordCount: Int {
        plainText.split { $0.isWhitespace }.count
    }

    /// Estimated reading time at 220 words/minute, preserving the legacy minimum
    /// of one minute for a chapter value.
    public var readingTimeMinutes: Int {
        max(1, wordCount / 220)
    }

    public init(
        id: String? = nil,
        title: String,
        pageRange: ClosedRange<Int>,
        order: Int,
        plainText: String,
        htmlPreview: String,
        confidence: Double = 1.0,
        isOCRSourced: Bool = false
    ) {
        self.title = title
        self.pageRange = pageRange
        self.order = order
        self.plainText = plainText
        self.htmlPreview = htmlPreview
        self.confidence = min(1, max(0, confidence))
        self.isOCRSourced = isOCRSourced
        self.id = id ?? PdfStableIdentifier.make(
            prefix: "chapter",
            components: [
                String(order),
                String(pageRange.lowerBound),
                String(pageRange.upperBound),
                title,
                plainText
            ]
        )
    }

    /// Chapter identity intentionally defines equality, preserving the package's
    /// pre-hardening semantics while making generated identity deterministic.
    public static func == (lhs: PdfChapter, rhs: PdfChapter) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public func ttsChunks(maxCharacters: Int = 2_800) -> [String] {
        TTSChunker.chunk(text: plainText, maxLength: maxCharacters)
    }

    public func ttsChunks(configuration: TTSChunkingConfiguration) -> [String] {
        TTSChunker.chunk(text: plainText, configuration: configuration)
    }
}

public struct PdfResource: Sendable {
    public let pageIndex: Int
    public let imageData: Data?
}
