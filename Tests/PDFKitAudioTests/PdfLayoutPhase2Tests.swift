import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutPhase2Tests: XCTestCase {
    func testRealSpanningHeadlinePreservesDeckThenColumnMajorBody() throws {
        let markers = ["Spanning Headline Across Page", "Full-width deck."]
            + (1...9).map { "Column 1 body \($0)." }
            + (1...9).map { "Column 2 body \($0)." }
        try assertReal("04-spanning-headline-two-columns", markers: markers)
    }

    func testRealMixedTransitionsPreserveIntroColumnsAndConclusion() throws {
        var markers = ["Mixed Column Transitions", "FULL WIDTH INTRO"]
        markers += (1...3).map { "Intro line \($0)." }
        markers += (1...6).map { "Mid 1.\($0)." }
        markers += (1...6).map { "Mid 2.\($0)." }
        markers.append("FULL WIDTH CONCLUSION")
        markers += (1...5).map { "Conclusion line \($0)." }
        try assertReal("10-mixed-column-transitions", markers: markers)
    }

    func testEveryPlannedGeneratedMixedRegionHasExactFinalParserOrder() throws {
        let names = ["full-width-title-two-columns", "full-width-abstract-two-columns",
                     "two-columns-full-width-conclusion", "title-columns-footer-note",
                     "single-two-single", "columns-interrupted-by-caption",
                     "multiple-spanning-headings", "abstract-columns-summary", "caption-between-columns"]
        for name in names {
            let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName[name])
            let data = try TestPDFBuilder.layoutPDF(fixture)
            let book = try parser().parse(data: data)
            assertOrder(fixture.expectedMarkerOrder, in: book.allPlainText(), context: name)
            try assertConservation(data: data, book: book, context: name)
        }
    }

    func testPersistentNarrowGutterSurvivesLineAndParagraphReconstruction() throws {
        let fragments = (0..<3).flatMap { row in
            [fragment(row * 2, "Left paragraph line \(row).", x: 0.08, y: 0.12 + CGFloat(row) * 0.04, width: 0.40),
             fragment(row * 2 + 1, "Right paragraph line \(row).", x: 0.50, y: 0.12 + CGFloat(row) * 0.04, width: 0.40)]
        }
        let lines = PdfLayoutLineBuilder.build(fragments: fragments)
        XCTAssertEqual(lines.count, 6)
        XCTAssertTrue(lines.allSatisfy { !($0.rect.minX < 0.49 && $0.rect.maxX > 0.49) })
        let result = try XCTUnwrap(PdfLayoutAnalyzer.analyze(fragments: fragments,
            nativeText: fragments.map(\.text).joined(separator: "\n"), nativeTextThreshold: 20,
            pageIndex: 0, mode: .auto))
        assertOrder(["Left paragraph line 0.", "Left paragraph line 1.", "Left paragraph line 2.",
                     "Right paragraph line 0.", "Right paragraph line 1.", "Right paragraph line 2."],
                    in: result.text, context: "narrow persistent gutter")
    }

    func testDefaultAsyncURLParsingMatchesVerifiedMixedRegionText() async throws {
        for name in ["04-spanning-headline-two-columns", "10-mixed-column-transitions"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "PDFLayout"))
            let expected = try parser().parse(at: url)
            let actual = try await PdfParser().parseAsync(at: url)
            XCTAssertEqual(actual.allPlainText(), expected.allPlainText(), name)
            XCTAssertEqual(actual.chapters.map(\.plainText), expected.chapters.map(\.plainText), name)
            XCTAssertTrue(actual.pages.allSatisfy { $0.extractionSource == .native }, name)
        }
    }

    private func assertReal(_ name: String, markers: [String]) throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "PDFLayout"))
        let data = try Data(contentsOf: url)
        let book = try parser().parse(data: data)
        assertOrder(markers, in: book.allPlainText(), context: name)
        try assertConservation(data: data, book: book, context: name)
        let repeated = try parser().parse(data: data)
        XCTAssertEqual(book.pages, repeated.pages, name)
        XCTAssertEqual(book.audiobookScript().map(\.id), repeated.audiobookScript().map(\.id), name)
        let document = try XCTUnwrap(PDFDocument(data: data))
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            var snapshot: PdfLayoutDiagnostics.Snapshot?
            _ = try PdfLayoutAnalyzer.analyze(fragments: PdfPositionedTextExtractor.nativeFragments(page: page),
                nativeText: page.string ?? "", nativeTextThreshold: 20, pageIndex: index, mode: .auto,
                diagnostics: { snapshot = $0 })
            XCTAssertEqual(snapshot?.decision, .accepted, name)
            XCTAssertTrue(snapshot?.readingOrderDiagnostics.contains { $0.hasPrefix("Direct") } == true, name)
            if ProcessInfo.processInfo.environment["PDFKITAUDIO_LAYOUT_DIAGNOSTICS"] == "1" {
                print("\(name)\n\(snapshot?.jsonString ?? "No diagnostics")")
            }
        }
    }

    private func assertConservation(data: Data, book: PdfBook, context: String) throws {
        let document = try XCTUnwrap(PDFDocument(data: data))
        let native = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        func words(_ text: String) -> [String: Int] {
            Dictionary(text.split(whereSeparator: \.isWhitespace).map { (String($0), 1) }, uniquingKeysWith: +)
        }
        XCTAssertEqual(words(book.allPlainText()), words(native), context)
        XCTAssertEqual(words(book.chapters.map(\.plainText).joined(separator: "\n")), words(native), context)
        XCTAssertEqual(words(book.audiobookScript(maxCharsPerSegment: 120).map(\.text).joined(separator: "\n")), words(native), context)
        XCTAssertEqual(book.pages.count, document.pageCount, context)
        XCTAssertTrue(book.pages.allSatisfy { $0.extractionSource == .native }, context)
    }

    private func assertOrder(_ markers: [String], in text: String, context: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let score = TestLayoutBaselineScorer.score(expectedMarkers: markers, in: text)
        XCTAssertEqual(score.coverage, 1, "\(context)\n\(text)", file: file, line: line)
        XCTAssertEqual(score.pairwiseAccuracy, 1, "\(context)\n\(text)", file: file, line: line)
        XCTAssertEqual(score.duplicateMarkerCount, 0, context, file: file, line: line)
    }

    private func parser() -> PdfParser {
        PdfParser(configuration: PdfParserConfiguration(ocr: PdfOCRConfiguration(mode: .never),
            layout: PdfLayoutConfiguration(mode: .auto), cleanup: .minimal, extractCoverImage: false))
    }

    private func fragment(_ id: Int, _ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> PdfLayoutFragment {
        PdfLayoutFragment(id: id, text: text, rect: CGRect(x: x, y: y, width: width, height: 0.025),
            source: .native, confidence: 1, sourceOrder: id)
    }
}
