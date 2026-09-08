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
            "Two Column Article",
            "Column 1 — Item 1",
            "Column 1 — Item 2",
            "Column 1 — Item 3",
            "Column 1 — Item 4",
            "Column 1 — Item 5",
            "Column 1 — Item 6",
            "Column 2 — Item 1",
            "Column 2 — Item 2",
            "Column 2 — Item 3",
            "Column 2 — Item 4",
            "Column 2 — Item 5",
            "Column 2 — Item 6"
        ]
        assertUniqueOrderedMarkers(expected, in: text, fixture: "02-two-columns")
    }

    func testRealThreeColumnFixtureHasExactColumnMajorReadingOrder() throws {
        let text = try parsedText("03-three-columns")
        let expected = [
            "Three Column Newsletter",
            "Story 1.1",
            "Story 1.2",
            "Story 1.3",
            "Story 1.4",
            "Story 2.1",
            "Story 2.2",
            "Story 2.3",
            "Story 2.4",
            "Story 3.1",
            "Story 3.2",
            "Story 3.3",
            "Story 3.4"
        ]
        assertUniqueOrderedMarkers(expected, in: text, fixture: "03-three-columns")
    }

    func testRealDenseAcademicFixtureKeepsFrontMatterThenColumnMajorBody() throws {
        let text = try parsedText("12-dense-academic")
        let expected = [
            "Geometry-First Reading Order in Native PDFs",
            "Abstract",
            "1.1 Section heading",
            "1.2 Section heading",
            "1.3 Section heading",
            "1.4 Section heading",
            "1.5 Section heading",
            "1.6 Section heading",
            "2.1 Section heading",
            "2.2 Section heading",
            "2.3 Section heading",
            "2.4 Section heading",
            "2.5 Section heading",
            "2.6 Section heading"
        ]
        assertUniqueOrderedMarkers(expected, in: text, fixture: "12-dense-academic")
    }

    func testRealTwoColumnNativeFragmentsDoNotCrossThePrimaryGutterForBodyText() throws {
        let data = try fixtureData("02-two-columns")
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
        let body = fragments.filter { $0.text.contains("Layout-aware PDF parsing") }

        XCTAssertFalse(body.isEmpty)
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
