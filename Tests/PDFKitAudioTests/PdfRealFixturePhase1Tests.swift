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

    func testPhase1FixturesPreserveAllNativeWordsThroughPagesChaptersAndSpeech() throws {
        for name in ["02-two-columns", "03-three-columns", "12-dense-academic"] {
            let data = try fixtureData(name)
            let document = try XCTUnwrap(PDFDocument(data: data), name)
            let book = try parser().parse(data: data)
            let original = (0..<document.pageCount).compactMap {
                document.page(at: $0)?.string
            }.joined(separator: "\n")

            // Count every word, including repeated prose and punctuation. Marker
            // order alone cannot detect dropped or duplicated non-marker text.
            let expected = wordCounts(original)
            XCTAssertEqual(wordCounts(book.allPlainText()), expected, name)
            XCTAssertEqual(wordCounts(book.chapters.map(\.plainText).joined(separator: "\n")), expected, name)
            let segments = book.audiobookScript(maxCharsPerSegment: 120)
            XCTAssertEqual(wordCounts(segments.map(\.text).joined(separator: "\n")), expected, name)
            XCTAssertEqual(book.pages.count, document.pageCount, name)
            XCTAssertEqual(book.pages.map(\.pageIndex), Array(0..<document.pageCount), name)
            XCTAssertTrue(book.pages.allSatisfy { $0.extractionSource == .native }, name)
            XCTAssertEqual(book.ocrPageCount, 0, name)
            XCTAssertTrue(segments.allSatisfy {
                $0.sourcePageRange.lowerBound >= 0
                    && $0.sourcePageRange.upperBound < document.pageCount
            }, name)
        }
    }

    func testDemoDefaultAsyncURLParsingMatchesVerifiedPhase1Output() async throws {
        for name in ["02-two-columns", "03-three-columns", "12-dense-academic"] {
            let expected = try parsedText(name)
            // Match BookViewModel: default OCR, cleanup, layout, and cover options,
            // with the same asynchronous URL API used when opening a PDF.
            let book = try await PdfParser(configuration: PdfParserConfiguration())
                .parseAsync(at: fixtureURL(name))
            XCTAssertEqual(book.allPlainText(), expected, name)
            XCTAssertEqual(book.chapters.map(\.plainText).joined(separator: "\n\n"), expected, name)
            XCTAssertTrue(book.pages.allSatisfy { $0.extractionSource == .native }, name)
        }
    }

    func testAllRealFixturesProduceDeterministicNonemptyNativeOutput() throws {
        for name in allFixtureNames {
            let data = try fixtureData(name)
            let first = try parser().parse(data: data)
            let second = try parser().parse(data: data)
            XCTAssertFalse(first.allPlainText().isEmpty, name)
            XCTAssertEqual(first.pages.map(\.text), second.pages.map(\.text), name)
            XCTAssertEqual(first.audiobookScript().map(\.id), second.audiobookScript().map(\.id), name)
            XCTAssertTrue(first.pages.allSatisfy { $0.extractionSource == .native }, name)
        }
    }

    func testRealExtractionDiagnosticsPreserveNativeRangesAndSelectedText() throws {
        for name in allFixtureNames {
            let document = try XCTUnwrap(PDFDocument(data: fixtureData(name)))
            for index in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: index))
                var snapshot: PdfPositionedTextExtractor.ExtractionSnapshot?
                let fragments = PdfPositionedTextExtractor.nativeFragments(page: page, diagnostics: { snapshot = $0 })
                let capture = try XCTUnwrap(snapshot, name)
                XCTAssertEqual(capture.nativeText, page.string, name)
                XCTAssertFalse(capture.selections.isEmpty, name)
                let visibleSelections = capture.selections.filter {
                    !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                for selection in visibleSelections {
                    XCTAssertFalse(selection.ranges.isEmpty, "\(name): \(selection.text)")
                    XCTAssertEqual(selection.glyphs.count, selection.ranges.reduce(0) { $0 + $1.length }, name)
                }
                XCTAssertEqual(capture.fragments.map(\.text), fragments.map(\.text), name)
                for fragment in fragments {
                    XCTAssertFalse(fragment.sourceRanges.isEmpty, name)
                    let selected = fragment.sourceRanges.compactMap { page.selection(for: $0)?.string }.joined()
                    XCTAssertEqual(selected.trimmingCharacters(in: .newlines), fragment.text, name)
                }
                if ProcessInfo.processInfo.environment["PDFKITAUDIO_LAYOUT_DIAGNOSTICS"] == "1" {
                    print("\(name) page \(index)\n\(capture.textDescription)")
                }
            }
        }
    }

    func testRealSingleColumnKeepsSourceOrderAndAnalyzerFastPathWhileRestoringParagraphs() throws {
        let data = try fixtureData("01-single-column")
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        var snapshot: PdfLayoutDiagnostics.Snapshot?
        let analyzed = try PdfLayoutAnalyzer.analyze(
            fragments: PdfPositionedTextExtractor.nativeFragments(page: page),
            nativeText: page.string ?? "",
            nativeTextThreshold: 20,
            pageIndex: 0,
            mode: .auto,
            diagnostics: { snapshot = $0 }
        )
        XCTAssertNil(analyzed)
        XCTAssertEqual(snapshot?.decision, .fastPath)
        let automatic = try parser().parse(data: data).allPlainText()
        let legacy = try parser(layout: .never).parse(data: data).allPlainText()
        // Paragraph whitespace is an intentional repair even when full reading-
        // order analysis is unnecessary. Do not lock in the old missing breaks.
        XCTAssertTrue(automatic.contains("\n\nSection Two\n\n"))
        XCTAssertEqual(automatic.replacingOccurrences(of: "\n\n", with: "\n"), legacy)
    }

    func testPhase1RealColumnsAreAcceptedWithoutFallback() throws {
        for name in ["02-two-columns", "03-three-columns", "12-dense-academic"] {
            let document = try XCTUnwrap(PDFDocument(data: fixtureData(name)))
            for pageIndex in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: pageIndex))
                var snapshot: PdfLayoutDiagnostics.Snapshot?
                let result = try PdfLayoutAnalyzer.analyze(
                    fragments: PdfPositionedTextExtractor.nativeFragments(page: page),
                    nativeText: page.string ?? "",
                    nativeTextThreshold: 20,
                    pageIndex: pageIndex,
                    mode: .auto,
                    diagnostics: { snapshot = $0 }
                )
                XCTAssertNotNil(result, "\(name): \(snapshot?.textDescription ?? "No diagnostics")")
                XCTAssertEqual(snapshot?.decision, .accepted, name)
                XCTAssertEqual(snapshot?.readingOrderUsedFallback, false, name)
                if ProcessInfo.processInfo.environment["PDFKITAUDIO_LAYOUT_DIAGNOSTICS"] == "1" {
                    print("\(name)\n\(snapshot?.jsonString ?? "No diagnostics")\nNative text:\n\(page.string ?? "")")
                }
            }
        }
    }

    private func wordCounts(_ text: String) -> [String: Int] {
        Dictionary(text.split(whereSeparator: \.isWhitespace).map { (String($0), 1) }, uniquingKeysWith: +)
    }

    private func parsedText(_ name: String) throws -> String {
        let book = try parser().parse(data: fixtureData(name))
        return book.pages.map(\.text).joined(separator: "\n\n")
    }

    private func parser(layout: PdfLayoutMode = .auto) -> PdfParser {
        PdfParser(configuration: PdfParserConfiguration(
            ocr: PdfOCRConfiguration(mode: .never),
            layout: PdfLayoutConfiguration(mode: layout),
            cleanup: .minimal,
            extractCoverImage: false
        ))
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
