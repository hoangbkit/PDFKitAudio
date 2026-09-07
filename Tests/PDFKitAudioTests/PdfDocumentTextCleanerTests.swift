import XCTest
@testable import PDFKitAudio

final class PdfDocumentTextCleanerTests: XCTestCase {
    func testRepeatedHeaderIsSpokenOnceAndSequentialPageNumbersAreRemoved() {
        let pages = (0..<6).map { index in
            page(
                index,
                text: "The Great Book\nBODY_\(index) unique content.\n\(index + 1)"
            )
        }

        let cleaned = PdfDocumentTextCleaner.clean(
            pages,
            configuration: .audiobookDefault
        )
        let combined = cleaned.map(\.text).joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "The Great Book", in: combined), 1)
        for index in 0..<6 {
            XCTAssertEqual(occurrences(of: "BODY_\(index)", in: combined), 1)
            XCTAssertFalse(cleaned[index].text.components(separatedBy: .newlines).contains(String(index + 1)))
            XCTAssertTrue(cleaned[index].nativeText.contains("The Great Book"))
        }
    }

    func testAlternatingHeadersAreEachRetainedOnce() {
        let pages = (0..<8).map { index in
            let header = index.isMultiple(of: 2) ? "The Great Book" : "Fixture Author"
            return page(index, text: "\(header)\nBODY_\(index) unique content.")
        }

        let cleaned = PdfDocumentTextCleaner.clean(
            pages,
            configuration: .audiobookDefault
        )
        let combined = cleaned.map(\.text).joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "The Great Book", in: combined), 1)
        XCTAssertEqual(occurrences(of: "Fixture Author", in: combined), 1)
        for index in 0..<8 {
            XCTAssertEqual(occurrences(of: "BODY_\(index)", in: combined), 1)
        }
    }

    func testShortDocumentDoesNotOverDeleteRepeatedEdgeText() {
        let pages = [
            page(0, text: "Important Notice\nFirst body."),
            page(1, text: "Important Notice\nSecond body.")
        ]

        let cleaned = PdfDocumentTextCleaner.clean(
            pages,
            configuration: .audiobookDefault
        )
        let combined = cleaned.map(\.text).joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "Important Notice", in: combined), 2)
    }

    func testTwoPageConsecutiveYearsAreNotMistakenForPagination() {
        let pages = [
            page(0, text: "2024\nFirst year body."),
            page(1, text: "2025\nSecond year body.")
        ]

        let cleaned = PdfDocumentTextCleaner.clean(
            pages,
            configuration: .audiobookDefault
        )

        XCTAssertTrue(cleaned[0].text.contains("2024"))
        XCTAssertTrue(cleaned[1].text.contains("2025"))
    }

    func testLegitimateStandaloneYearsAndNumbersArePreserved() {
        let pages = (0..<5).map { index in
            page(
                index,
                text: "BODY_\(index)\n2024\n42\nEnd marker \(index)"
            )
        }

        let cleaned = PdfDocumentTextCleaner.clean(
            pages,
            configuration: .audiobookDefault
        )
        let combined = cleaned.map(\.text).joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "2024", in: combined), 5)
        XCTAssertEqual(occurrences(of: "\n42\n", in: "\n" + combined + "\n"), 5)
    }

    func testDecoratedRunningHeaderWithSequentialSuffixIsSuppressedAfterFirst() {
        let pages = (0..<6).map { index in
            page(
                index,
                text: "Some Book • \(40 + index)\nBODY_\(index) unique content."
            )
        }

        let cleaned = PdfDocumentTextCleaner.clean(
            pages,
            configuration: .audiobookDefault
        )
        let combined = cleaned.map(\.text).joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "Some Book •", in: combined), 1)
        for index in 0..<6 {
            XCTAssertEqual(occurrences(of: "BODY_\(index)", in: combined), 1)
        }
    }

    func testMinimalConfigurationLeavesDocumentLevelContentUntouched() {
        let pages = (0..<4).map { index in
            page(index, text: "Repeated Header\nBODY_\(index)\n\(index + 1)")
        }

        let cleaned = PdfDocumentTextCleaner.clean(pages, configuration: .minimal)
        let combined = cleaned.map(\.text).joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "Repeated Header", in: combined), 4)
        for index in 0..<4 {
            XCTAssertTrue(cleaned[index].text.components(separatedBy: .newlines).contains(String(index + 1)))
        }
    }

    func testPageContainingOnlyProvenPaginationBecomesEmpty() {
        let pages = (0..<3).map { index in
            page(index, text: String(index + 1))
        }

        let cleaned = PdfDocumentTextCleaner.clean(
            pages,
            configuration: .audiobookDefault
        )

        XCTAssertTrue(cleaned.allSatisfy(\.isEmpty))
        XCTAssertTrue(cleaned.allSatisfy { $0.extractionSource == .empty })
        XCTAssertTrue(cleaned.allSatisfy { $0.confidence == 0 })
    }

    private func page(_ index: Int, text: String) -> PdfPageContent {
        PdfPageContent(
            pageIndex: index,
            nativeText: text,
            text: text,
            extractionSource: .native,
            confidence: 1
        )
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
