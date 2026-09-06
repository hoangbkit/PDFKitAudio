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

    func testBookAggregatesChapterMetrics() {
        let first = PdfChapter(title: "One", pageRange: 0...0, order: 0, plainText: "one two three", htmlPreview: "")
        let second = PdfChapter(title: "Two", pageRange: 1...1, order: 1, plainText: "four five", htmlPreview: "")
        let metadata = PdfMetadata(pageCount: 2)
        let book = PdfBook(metadata: metadata, chapters: [first, second], toc: [], cover: nil, fileURL: nil)

        XCTAssertEqual(book.totalWords, 5)
        XCTAssertEqual(book.estimatedReadingMinutes, 2)
    }
}
