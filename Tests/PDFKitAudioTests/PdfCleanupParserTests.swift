import XCTest
@testable import PDFKitAudio

final class PdfCleanupParserTests: XCTestCase {
    func testDefaultParserAppliesDocumentCleanupWithoutMutatingNativeText() throws {
        let pages = (0..<5).map { index in
            "The Great Book\nBODY_\(index) unique source content.\n\(index + 1)"
        }
        let data = try TestPDFBuilder.digitalPDF(pages: pages)

        let book = try PdfParser(ocrMode: .never).parse(data: data)
        let spokenText = book.allPlainText()

        XCTAssertEqual(occurrences(of: "The Great Book", in: spokenText), 1)
        for index in 0..<5 {
            XCTAssertEqual(occurrences(of: "BODY_\(index)", in: spokenText), 1)
            XCTAssertTrue(book.pages[index].nativeText.contains("The Great Book"))
            XCTAssertFalse(
                book.pages[index].text.components(separatedBy: .newlines).contains(String(index + 1))
            )
        }
    }

    func testMinimalParserCleanupPreservesRunningMatter() throws {
        let pages = (0..<4).map { index in
            "Repeated Header\nBODY_\(index) source content.\n\(index + 1)"
        }
        let data = try TestPDFBuilder.digitalPDF(pages: pages)

        let book = try PdfParser(
            ocrMode: .never,
            cleanupConfiguration: .minimal
        ).parse(data: data)
        let text = book.allPlainText()

        XCTAssertEqual(occurrences(of: "Repeated Header", in: text), 4)
        for index in 0..<4 {
            XCTAssertTrue(book.pages[index].text.contains(String(index + 1)))
        }
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }
}
