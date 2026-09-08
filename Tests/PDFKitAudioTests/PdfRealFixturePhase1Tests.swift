import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfRealFixturePhase1Tests: XCTestCase {
    private let allFixtureNames = [
        "01-single-column",
        "02-two-columns",
        "03-three-columns",
        "04-spanning-headline-two-columns",
        "05-right-sidebar",
        "06-pull-quote",
        "07-table-with-prose",
        "08-footnotes",
        "09-repeated-header-footer",
        "10-mixed-column-transitions",
        "11-landscape-dashboard",
        "12-dense-academic"
    ]

    func testAllCommittedPDFLayoutFixturesAreBundledAsRealTestResources() throws {
        for name in allFixtureNames {
            let url = try fixtureURL(name)
            let data = try Data(contentsOf: url)
            XCTAssertFalse(data.isEmpty, name)
            let document = try XCTUnwrap(PDFDocument(data: data), name)
            XCTAssertGreaterThan(document.pageCount, 0, name)
        }
    }

    func testRealTwoColumnFixtureHasExactColumnMajorReadingOrder() throws {
        let text = try parsedText("02-two-columns")
        let expected = [
            "Two Columns",
            "LEFT 1: column text.",
            "LEFT 2: column text.",
            "LEFT 3: column text.",
            "LEFT 4: column text.",
            "LEFT 5: column text.",
            "LEFT 6: column text.",
            "LEFT 7: column text.",
            "LEFT 8: column text.",
            "LEFT 9: column text.",
            "RIGHT 1: column text.",
            "RIGHT 2: column text.",
            "RIGHT 3: column text.",
            "RIGHT 4: column text.",
            "RIGHT 5: column text.",
            "RIGHT 6: column text.",
            "RIGHT 7: column text.",
            "RIGHT 8: column text.",
            "RIGHT 9: column text."
        ]
        assertUniqueOrderedMarkers(expected, in: text, fixture: "02-two-columns")
    }

    func testRealThreeColumnFixtureHasExactColumnMajorReadingOrder() throws {
        let text = try parsedText("03-three-columns")
        let expected = [
            "Three Columns",
            "C1 item 1.",
            "C1 item 2.",
            "C1 item 3.",
            "C1 item 4.",
            "C1 item 5.",
            "C1 item 6.",
            "C1 item 7.",
            "C1 item 8.",
            "C1 item 9.",
            "C1 item 10.",
            "C2 item 1.",
            "C2 item 2.",
            "C2 item 3.",
            "C2 item 4.",
            "C2 item 5.",
            "C2 item 6.",
            "C2 item 7.",
            "C2 item 8.",
            "C2 item 9.",
            "C2 item 10.",
            "C3 item 1.",
            "C3 item 2.",
            "C3 item 3.",
            "C3 item 4.",
            "C3 item 5.",
            "C3 item 6.",
            "C3 item 7.",
            "C3 item 8.",
            "C3 item 9.",
            "C3 item 10."
        ]
        assertUniqueOrderedMarkers(expected, in: text, fixture: "03-three-columns")
    }

    func testRealDenseAcademicFixtureKeepsFrontMatterThenColumnMajorBody() throws {
        let text = try parsedText("12-dense-academic")
        var expected = [
            "Dense Academic Paper",
            "Full-width abstract."
        ]
        expected.append(contentsOf: (1...18).map { "1.\($0) scholarly line" })
        expected.append(contentsOf: (1...18).map { "2.\($0) scholarly line" })
        expected.append("[7] Reference entry.")
        assertUniqueOrderedMarkers(expected, in: text, fixture: "12-dense-academic")
    }

    func testRealTwoColumnNativeFragmentsDoNotCrossThePrimaryGutterForBodyText() throws {
        let data = try fixtureData("02-two-columns")
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
        let body = fragments.filter { $0.text.contains("column text.") }

        XCTAssertEqual(body.count, 18, "Expected one native fragment per body line")
        for fragment in body {
            let crossesCenterGutter = fragment.rect.minX < 0.49 && fragment.rect.maxX > 0.51
            XCTAssertFalse(
                crossesCenterGutter,
                "Body fragment still crosses the two-column gutter: \(fragment.text) @ \(fragment.rect)"
            )
        }
    }

    private func parsedText(_ name: String) throws -> String {
        let parser = PdfParser(configuration: PdfParserConfiguration(
            ocr: PdfOCRConfiguration(mode: .never),
            layout: PdfLayoutConfiguration(mode: .auto),
            cleanup: .minimal,
            extractCoverImage: false
        ))
        let book = try parser.parse(data: fixtureData(name))
        return book.pages.map(\.text).joined(separator: "\n\n")
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let candidates = [
            Bundle.module.url(
                forResource: name,
                withExtension: "pdf",
                subdirectory: "PDFLayout"
            ),
            Bundle.module.url(
                forResource: name,
                withExtension: "pdf",
                subdirectory: "TestFixtures/PDFLayout"
            ),
            Bundle.module.url(
                forResource: name,
                withExtension: "pdf"
            )
        ]
        return try XCTUnwrap(candidates.compactMap { $0 }.first, name)
    }

    private func assertUniqueOrderedMarkers(
        _ markers: [String],
        in text: String,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var cursor = text.startIndex
        for marker in markers {
            let occurrenceCount = text.components(separatedBy: marker).count - 1
            XCTAssertEqual(
                occurrenceCount,
                1,
                "\(fixture): expected marker exactly once: \(marker)\n\n\(text)",
                file: file,
                line: line
            )
            guard let range = text.range(of: marker, range: cursor..<text.endIndex) else {
                XCTFail(
                    "\(fixture): marker missing or out of order: \(marker)\n\n\(text)",
                    file: file,
                    line: line
                )
                return
            }
            cursor = range.upperBound
        }
    }
}
