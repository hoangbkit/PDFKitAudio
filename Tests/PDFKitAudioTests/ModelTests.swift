import XCTest
@testable import PDFKitAudio

final class ModelTests: XCTestCase {
    func testChapterDerivedMetrics() {
        let text = Array(repeating: "word", count: 440).joined(separator: " ")
        let chapter = PdfChapter(
            title: "Chapter",
            pageRange: 3...7,
            order: 0,
            plainText: text,
            htmlPreview: ""
        )

        XCTAssertEqual(chapter.wordCount, 440)
        XCTAssertEqual(chapter.readingTimeMinutes, 2)
    }

    func testBookAggregatesChapterMetricsWithoutPageModelsForCompatibility() {
        let first = PdfChapter(title: "One", pageRange: 0...0, order: 0, plainText: "one two three", htmlPreview: "")
        let second = PdfChapter(title: "Two", pageRange: 1...1, order: 1, plainText: "four five", htmlPreview: "")
        let metadata = PdfMetadata(pageCount: 2)
        let book = PdfBook(metadata: metadata, chapters: [first, second], toc: [], cover: nil, fileURL: nil)

        XCTAssertEqual(book.totalWords, 5)
        XCTAssertEqual(book.estimatedReadingMinutes, 2)
        XCTAssertEqual(book.ocrPageCount, 0)
    }

    func testPageIdentityIsDeterministicAndConfidenceIsClamped() {
        let page = PdfPageContent(
            pageIndex: 7,
            nativeText: "native",
            text: "selected",
            extractionSource: .native,
            confidence: 3
        )

        XCTAssertEqual(page.id, 7)
        XCTAssertEqual(page.pageIndex, 7)
        XCTAssertEqual(page.confidence, 1)
        XCTAssertFalse(page.isOCRSourced)
    }

    func testBookCanonicalizesDuplicatePageIndexes() {
        let first = PdfPageContent(
            pageIndex: 0,
            nativeText: "first",
            text: "first",
            extractionSource: .native,
            confidence: 1
        )
        let replacement = PdfPageContent(
            pageIndex: 0,
            nativeText: "replacement",
            text: "replacement",
            extractionSource: .native,
            confidence: 1
        )
        let book = PdfBook(
            metadata: PdfMetadata(pageCount: 1),
            pages: [first, replacement],
            chapters: [],
            toc: [],
            cover: nil,
            fileURL: nil
        )

        XCTAssertEqual(book.pages.count, 1)
        XCTAssertEqual(book.pages[0].pageIndex, 0)
        XCTAssertEqual(book.pages[0].text, "replacement")
    }

    func testOCRAndEmptyPageCountsUseCanonicalPagesNotChapterFlags() {
        let pages = [
            PdfPageContent(pageIndex: 0, nativeText: "one", text: "one", extractionSource: .native, confidence: 1),
            PdfPageContent(pageIndex: 1, nativeText: "", text: "two", extractionSource: .ocr, confidence: 0.9),
            PdfPageContent(pageIndex: 2, nativeText: "", text: "", extractionSource: .empty, confidence: 0)
        ]
        let chapter = PdfChapter(
            title: "One",
            pageRange: 0...2,
            order: 0,
            plainText: "one\n\ntwo",
            htmlPreview: "",
            confidence: 0.5,
            isOCRSourced: true
        )
        let book = PdfBook(
            metadata: PdfMetadata(pageCount: 3),
            pages: pages,
            chapters: [chapter],
            toc: [],
            cover: nil,
            fileURL: nil
        )

        XCTAssertEqual(book.ocrPageCount, 1)
        XCTAssertEqual(book.emptyPageCount, 1)
        XCTAssertEqual(book.totalWords, 2)
        XCTAssertEqual(book.estimatedReadingMinutes, 1)
    }

    func testAllPlainTextUsesPagesAsCanonicalSource() {
        let pages = [
            PdfPageContent(pageIndex: 0, nativeText: "first", text: "first", extractionSource: .native, confidence: 1),
            PdfPageContent(pageIndex: 1, nativeText: "second", text: "second", extractionSource: .native, confidence: 1)
        ]
        let duplicatedChapter = PdfChapter(
            title: "Duplicated legacy chapter",
            pageRange: 0...1,
            order: 0,
            plainText: "first\n\nsecond\n\nfirst",
            htmlPreview: ""
        )
        let book = PdfBook(
            metadata: PdfMetadata(pageCount: 2),
            pages: pages,
            chapters: [duplicatedChapter],
            toc: [],
            cover: nil,
            fileURL: nil
        )

        XCTAssertEqual(book.allPlainText(), "first\n\nsecond")
    }

    func testAudiobookScriptMergesAdjacentPagesWithExactUnionRange() {
        let pages = [
            PdfPageContent(pageIndex: 0, nativeText: "Page zero sentence.", text: "Page zero sentence.", extractionSource: .native, confidence: 1),
            PdfPageContent(pageIndex: 1, nativeText: "Page one sentence.", text: "Page one sentence.", extractionSource: .native, confidence: 0.8)
        ]
        let chapter = PdfChapter(
            id: "chapter-0",
            title: "One",
            pageRange: 0...1,
            order: 0,
            plainText: "Page zero sentence.\n\nPage one sentence.",
            htmlPreview: ""
        )
        let book = PdfBook(
            metadata: PdfMetadata(pageCount: 2),
            pages: pages,
            chapters: [chapter],
            toc: [],
            cover: nil,
            fileURL: nil
        )

        let segments = book.audiobookScript(configuration: TTSChunkingConfiguration(
            maxCharacters: 100,
            preferredMinimumCharacters: 20,
            preserveParagraphs: true
        ))

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].sourcePageRange, 0...1)
        XCTAssertEqual(segments[0].pageIndex, 0)
        XCTAssertEqual(normalized(segments[0].text), "Page zero sentence. Page one sentence.")
        XCTAssertGreaterThan(segments[0].confidence, 0.8)
        XCTAssertLessThan(segments[0].confidence, 1)
    }

    func testAudiobookScriptNeverMergesAcrossChapterBoundary() {
        let pages = [
            PdfPageContent(pageIndex: 0, nativeText: "First chapter.", text: "First chapter.", extractionSource: .native, confidence: 1),
            PdfPageContent(pageIndex: 1, nativeText: "Second chapter.", text: "Second chapter.", extractionSource: .native, confidence: 1)
        ]
        let chapters = [
            PdfChapter(id: "chapter-0", title: "One", pageRange: 0...0, order: 0, plainText: "First chapter.", htmlPreview: ""),
            PdfChapter(id: "chapter-1", title: "Two", pageRange: 1...1, order: 1, plainText: "Second chapter.", htmlPreview: "")
        ]
        let book = PdfBook(
            metadata: PdfMetadata(pageCount: 2),
            pages: pages,
            chapters: chapters,
            toc: [],
            cover: nil,
            fileURL: nil
        )

        let segments = book.audiobookScript(configuration: TTSChunkingConfiguration(
            maxCharacters: 100,
            preferredMinimumCharacters: 20,
            preserveParagraphs: false
        ))

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.sourcePageRange), [0...0, 1...1])
        XCTAssertEqual(segments.map(\.chapterIndex), [0, 1])
    }

    func testAudiobookGeneratedSegmentIDsAreStableAcrossCalls() {
        let page = PdfPageContent(
            pageIndex: 0,
            nativeText: "Stable segment identity text.",
            text: "Stable segment identity text.",
            extractionSource: .native,
            confidence: 1
        )
        let chapter = PdfChapter(
            title: "One",
            pageRange: 0...0,
            order: 0,
            plainText: page.text,
            htmlPreview: ""
        )
        let book = PdfBook(
            metadata: PdfMetadata(pageCount: 1),
            pages: [page],
            chapters: [chapter],
            toc: [],
            cover: nil,
            fileURL: nil
        )

        let first = book.audiobookScript().map(\.id)
        let second = book.audiobookScript().map(\.id)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.hasPrefix("segment-") })
    }

    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
