import Foundation

public struct AudiobookSegment: Identifiable, Sendable {
    public let id: String
    public let chapterIndex: Int
    public let chapterTitle: String
    public let text: String
    public let order: Int
    public let sourcePageRange: ClosedRange<Int>
    public let confidence: Double

    /// Compatibility alias for callers that previously treated every segment as
    /// originating from one page. Prefer `sourcePageRange` for new code.
    public var pageIndex: Int { sourcePageRange.lowerBound }

    public var wordCount: Int { text.split { $0.isWhitespace }.count }
}

public final class PdfBook: @unchecked Sendable {
    public let metadata: PdfMetadata
    public let pages: [PdfPageContent]
    public let chapters: [PdfChapter]
    public let tableOfContents: [PdfTOCItem]
    public let coverImageData: Data?
    public let fileURL: URL?

    public init(
        metadata: PdfMetadata,
        pages: [PdfPageContent] = [],
        chapters: [PdfChapter],
        toc: [PdfTOCItem],
        cover: Data?,
        fileURL: URL?
    ) {
        self.metadata = metadata

        // Keep one canonical value per source page index even for manually-created
        // books. Parser-produced books already satisfy this invariant, but enforcing
        // it here prevents duplicate indexes from crashing provenance lookups later.
        var pagesByIndex: [Int: PdfPageContent] = [:]
        for page in pages {
            pagesByIndex[page.pageIndex] = page
        }
        self.pages = pagesByIndex.values.sorted { $0.pageIndex < $1.pageIndex }

        self.chapters = chapters
        self.tableOfContents = toc
        self.coverImageData = cover
        self.fileURL = fileURL
    }

    public var totalWords: Int {
        if !pages.isEmpty {
            return pages.reduce(0) { count, page in
                count + page.text.split { $0.isWhitespace }.count
            }
        }
        return chapters.reduce(0) { $0 + $1.wordCount }
    }

    public var estimatedReadingMinutes: Int {
        if pages.isEmpty {
            return chapters.reduce(0) { $0 + $1.readingTimeMinutes }
        }
        guard totalWords > 0 else { return 0 }
        return max(1, totalWords / 220)
    }

    /// Number of actual source pages whose selected text came from OCR.
    public var ocrPageCount: Int {
        pages.filter { $0.extractionSource == .ocr }.count
    }

    public var emptyPageCount: Int {
        pages.filter(\.isEmpty).count
    }

    /// Returns canonical selected page text exactly once and in source order.
    ///
    /// The chapter fallback is retained for compatibility with manually-created
    /// `PdfBook` values that predate page-level provenance.
    public func allPlainText(separator: String = "\n\n") -> String {
        if !pages.isEmpty {
            return pages
                .map(\.text)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: separator)
        }
        return chapters.map(\.plainText).joined(separator: separator)
    }

    public func audiobookScript(maxCharsPerSegment: Int = 2800) -> [AudiobookSegment] {
        var segments: [AudiobookSegment] = []
        var globalOrder = 0

        let pagesByIndex = Dictionary(uniqueKeysWithValues: pages.map { ($0.pageIndex, $0) })

        for (chapterIndex, chapter) in chapters.enumerated() {
            let chapterPages = chapter.pageRange.compactMap { pagesByIndex[$0] }

            if chapterPages.isEmpty {
                // Compatibility path for manually-created books without page models.
                for chunk in chapter.ttsChunks(maxCharacters: maxCharsPerSegment) {
                    segments.append(AudiobookSegment(
                        id: "\(chapter.id)-\(globalOrder)",
                        chapterIndex: chapterIndex,
                        chapterTitle: chapter.title,
                        text: chunk,
                        order: globalOrder,
                        sourcePageRange: chapter.pageRange,
                        confidence: chapter.confidence
                    ))
                    globalOrder += 1
                }
                continue
            }

            // Phase 1 intentionally chunks within source-page boundaries. This
            // gives every segment exact provenance. A later segmentation phase can
            // merge across pages while carrying the union of their source ranges.
            for page in chapterPages where !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let chunks = TTSChunker.chunk(text: page.text, maxLength: maxCharsPerSegment)
                for chunk in chunks {
                    segments.append(AudiobookSegment(
                        id: "\(chapter.id)-\(globalOrder)",
                        chapterIndex: chapterIndex,
                        chapterTitle: chapter.title,
                        text: chunk,
                        order: globalOrder,
                        sourcePageRange: page.pageIndex...page.pageIndex,
                        confidence: page.confidence
                    ))
                    globalOrder += 1
                }
            }
        }

        return segments
    }
}
