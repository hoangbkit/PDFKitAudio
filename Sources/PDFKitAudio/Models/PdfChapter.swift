import Foundation

public struct PdfChapter: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let pageRange: ClosedRange<Int>
    public let order: Int
    public var plainText: String
    public var htmlPreview: String
    public var wordCount: Int
    public var readingTimeMinutes: Int
    public var confidence: Double // 0..1, average OCR confidence if applicable
    public var isOCRSourced: Bool

    public init(
        id: String = UUID().uuidString,
        title: String,
        pageRange: ClosedRange<Int>,
        order: Int,
        plainText: String,
        htmlPreview: String,
        confidence: Double = 1.0,
        isOCRSourced: Bool = false
    ) {
        self.id = id
        self.title = title
        self.pageRange = pageRange
        self.order = order
        self.plainText = plainText
        self.htmlPreview = htmlPreview
        self.confidence = confidence
        self.isOCRSourced = isOCRSourced
        self.wordCount = plainText.split { $0.isWhitespace }.count
        self.readingTimeMinutes = max(1, wordCount / 220)
    }

    public static func == (lhs: PdfChapter, rhs: PdfChapter) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public func ttsChunks(maxCharacters: Int = 2800) -> [String] {
        TTSChunker.chunk(text: plainText, maxLength: maxCharacters)
    }
}

public struct PdfResource: Sendable {
    public let pageIndex: Int
    public let imageData: Data?
}
