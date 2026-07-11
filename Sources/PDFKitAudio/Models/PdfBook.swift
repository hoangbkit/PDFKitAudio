import Foundation

public struct AudiobookSegment: Identifiable, Sendable {
    public let id: String
    public let chapterIndex: Int
    public let chapterTitle: String
    public let text: String
    public let order: Int
    public let pageIndex: Int
    public let confidence: Double

    public var wordCount: Int { text.split { $0.isWhitespace }.count }
}

public final class PdfBook: @unchecked Sendable {
    public let metadata: PdfMetadata
    public let chapters: [PdfChapter]
    public let tableOfContents: [PdfTOCItem]
    public let coverImageData: Data?
    public let fileURL: URL?

    public init(metadata: PdfMetadata, chapters: [PdfChapter], toc: [PdfTOCItem], cover: Data?, fileURL: URL?) {
        self.metadata = metadata
        self.chapters = chapters
        self.tableOfContents = toc
        self.coverImageData = cover
        self.fileURL = fileURL
    }

    public var totalWords: Int { chapters.reduce(0) { $0 + $1.wordCount } }
    public var estimatedReadingMinutes: Int { chapters.reduce(0) { $0 + $1.readingTimeMinutes } }
    public var ocrPageCount: Int { chapters.filter { $0.isOCRSourced }.count }

    public func allPlainText(separator: String = "\n\n") -> String {
        chapters.map { $0.plainText }.joined(separator: separator)
    }

    public func audiobookScript(maxCharsPerSegment: Int = 2800) -> [AudiobookSegment] {
        var segments: [AudiobookSegment] = []
        var global = 0
        for (chapterIndex, chapter) in chapters.enumerated() {
            let chunks = chapter.ttsChunks(maxCharacters: maxCharsPerSegment)
            for chunk in chunks {
                segments.append(AudiobookSegment(
                    id: "\(chapter.id)-\(global)",
                    chapterIndex: chapterIndex,
                    chapterTitle: chapter.title,
                    text: chunk,
                    order: global,
                    pageIndex: chapter.pageRange.lowerBound,
                    confidence: chapter.confidence
                ))
                global += 1
            }
        }
        return segments
    }
}
