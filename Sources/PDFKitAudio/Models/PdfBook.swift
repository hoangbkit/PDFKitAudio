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

/// Immutable parsed PDF result. All stored values are Sendable, so the book can
/// safely cross Swift-concurrency boundaries without unchecked conformance.
public final class PdfBook: Sendable {
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

    /// Backward-compatible convenience API. It retains page-bounded segmentation
    /// so existing callers do not silently receive wider provenance ranges.
    public func audiobookScript(maxCharsPerSegment: Int = 2_800) -> [AudiobookSegment] {
        makeAudiobookScript(
            configuration: TTSChunkingConfiguration(maxCharacters: maxCharsPerSegment),
            mergesAcrossPages: false
        )
    }

    /// Preferred engine-agnostic API. Adjacent short pieces may be packed across
    /// page boundaries inside one chapter, with the exact union source range kept.
    public func audiobookScript(
        configuration: TTSChunkingConfiguration
    ) -> [AudiobookSegment] {
        makeAudiobookScript(
            configuration: configuration,
            mergesAcrossPages: true
        )
    }

    private func makeAudiobookScript(
        configuration: TTSChunkingConfiguration,
        mergesAcrossPages: Bool
    ) -> [AudiobookSegment] {
        var segments: [AudiobookSegment] = []
        var globalOrder = 0
        let pagesByIndex = Dictionary(uniqueKeysWithValues: pages.map { ($0.pageIndex, $0) })

        for (chapterIndex, chapter) in chapters.enumerated() {
            let chapterPages = chapter.pageRange.compactMap { pagesByIndex[$0] }
            let pieces: [AttributedChunk]

            if chapterPages.isEmpty {
                pieces = TTSChunker.chunk(
                    text: chapter.plainText,
                    configuration: configuration
                ).map {
                    AttributedChunk(
                        text: $0,
                        sourcePageRange: chapter.pageRange,
                        confidence: chapter.confidence
                    )
                }
            } else {
                pieces = chapterPages.flatMap { page in
                    TTSChunker.chunk(
                        text: page.text,
                        configuration: configuration
                    ).map {
                        AttributedChunk(
                            text: $0,
                            sourcePageRange: page.pageIndex...page.pageIndex,
                            confidence: page.confidence
                        )
                    }
                }
            }

            for piece in packAdjacentPieces(
                pieces,
                maximumCharacters: configuration.maxCharacters,
                mergesAcrossPages: mergesAcrossPages
            ) {
                let id = PdfStableIdentifier.make(
                    prefix: "segment",
                    components: [
                        String(chapterIndex),
                        String(globalOrder),
                        String(piece.sourcePageRange.lowerBound),
                        String(piece.sourcePageRange.upperBound),
                        piece.text
                    ]
                )
                segments.append(AudiobookSegment(
                    id: id,
                    chapterIndex: chapterIndex,
                    chapterTitle: chapter.title,
                    text: piece.text,
                    order: globalOrder,
                    sourcePageRange: piece.sourcePageRange,
                    confidence: piece.confidence
                ))
                globalOrder += 1
            }
        }

        return segments
    }

    private func packAdjacentPieces(
        _ pieces: [AttributedChunk],
        maximumCharacters: Int,
        mergesAcrossPages: Bool
    ) -> [AttributedChunk] {
        guard !pieces.isEmpty else { return [] }

        var packed: [AttributedChunk] = []
        var current = pieces[0]

        for piece in pieces.dropFirst() {
            let candidateText = current.text + " " + piece.text
            let sameSourceRange = piece.sourcePageRange == current.sourcePageRange
            let sourceIsAdjacent = piece.sourcePageRange.lowerBound
                <= current.sourcePageRange.upperBound + 1
            let provenanceAllowsMerge = sameSourceRange
                || (mergesAcrossPages && sourceIsAdjacent)

            if provenanceAllowsMerge && candidateText.count <= maximumCharacters {
                current = current.merging(piece, joinedText: candidateText)
            } else {
                packed.append(current)
                current = piece
            }
        }

        packed.append(current)
        return packed
    }
}

private struct AttributedChunk {
    let text: String
    let sourcePageRange: ClosedRange<Int>
    let confidence: Double

    func merging(_ other: AttributedChunk, joinedText: String) -> AttributedChunk {
        let leftWeight = max(1, text.count)
        let rightWeight = max(1, other.text.count)
        let totalWeight = leftWeight + rightWeight
        let weightedConfidence = (
            confidence * Double(leftWeight)
                + other.confidence * Double(rightWeight)
        ) / Double(totalWeight)

        return AttributedChunk(
            text: joinedText,
            sourcePageRange: sourcePageRange.lowerBound...other.sourcePageRange.upperBound,
            confidence: weightedConfidence
        )
    }
}
