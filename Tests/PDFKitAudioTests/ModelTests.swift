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
}
