import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutPhase3Tests: XCTestCase {
    func testRealRunningMatterMeetsFourPageConservativeContract() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "09-repeated-header-footer", withExtension: "pdf", subdirectory: "PDFLayout"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 4)
        let book = try PdfParser().parse(at: url)
        if ProcessInfo.processInfo.environment["PDFKITAUDIO_LAYOUT_DIAGNOSTICS"] == "1" {
            print("RUNNING MATTER OUTPUT\n\(book.allPlainText())")
            let page = try XCTUnwrap(document.page(at: 0))
            _ = try PdfLayoutAnalyzer.analyze(fragments: PdfPositionedTextExtractor.nativeFragments(page: page),
                nativeText: page.string ?? "", nativeTextThreshold: 20, pageIndex: 0, mode: .auto,
                diagnostics: { print($0.jsonString ?? "") })
        }
        let minimal = try PdfParser(configuration: PdfParserConfiguration(cleanup: .minimal)).parse(at: url)
        func count(_ needle: String, _ text: String) -> Int { text.components(separatedBy: needle).count - 1 }
        for output in [book.allPlainText(), book.chapters.map(\.plainText).joined(separator: "\n"),
                       book.audiobookScript(maxCharsPerSegment: 120).map(\.text).joined(separator: "\n")] {
            XCTAssertEqual(count("REPEATED JOURNAL HEADER", output), 1)
            XCTAssertEqual(count("Repeated footer - Journal 2026", output), 1)
            for page in 1...4 {
                XCTAssertFalse(output.contains("Page \(page)"))
                for row in 1...12 { XCTAssertEqual(count("Unique page \(page) body \(row).", output), 1) }
            }
        }
        XCTAssertEqual(count("REPEATED JOURNAL HEADER", minimal.allPlainText()), 4)
        XCTAssertEqual(count("Repeated footer - Journal 2026", minimal.allPlainText()), 4)
        XCTAssertTrue(book.pages.allSatisfy { $0.nativeText.contains("REPEATED JOURNAL HEADER") })
        XCTAssertEqual(book.pages, try PdfParser().parse(at: url).pages)
    }

    func testRealSidebarFollowsPrimaryNarrative() throws {
        try verify("05-right-sidebar", markers: ["Main Article + Sidebar"]
            + (1...12).map { "Main body \($0): primary story." }
            + ["SIDEBAR"] + (1...8).map { "Note \($0)." })
    }

    func testRealPullQuoteDoesNotInterruptNarrative() throws {
        try verify("06-pull-quote", markers: ["Pull Quote Layout"]
            + (1...5).map { "Opening body \($0)." }
            + (1...7).map { "Closing body \($0)." }
            + ["Visually isolated pull quote"])
    }

    func testRealTablePreservesCellsAndSurroundingProse() throws {
        try verify("07-table-with-prose", markers: ["Table With Prose", "Intro prose before table.",
            "Metric", "Base", "New", "Delta", "Accuracy", "82", "95", "+13",
            "Errors", "14", "3", "-11", "Omit", "7", "1", "-6", "Dupes", "5", "0", "-5",
            "Conclusion prose after table."])
    }

    func testRealFootnotesFollowBody() throws {
        try verify("08-footnotes", markers: ["Body + Footnotes"]
            + (1...11).map { "Main body \($0) with citation" }
            + ["FOOTNOTES"] + (1...5).map { "\($0). Footnote text." })
    }

    func testRealFootnotesHaveExplicitNoteRolesWhenAnalyzed() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "08-footnotes", withExtension: "pdf", subdirectory: "PDFLayout"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        defer { withExtendedLifetime(document) {} }
        let page = try XCTUnwrap(document.page(at: 0))
        let lines = PdfLayoutLineBuilder.build(fragments: PdfPositionedTextExtractor.nativeFragments(page: page))
        let blocks = PdfLayoutBlockBuilder.build(lines: lines)
        let analysis = PdfLayoutRoleClassifier.analyze(blocks: blocks, layout: PdfLayoutRegionDetector.segment(blocks: blocks))
        let notes = blocks.filter { $0.text.contains("Footnote text.") }
        XCTAssertEqual(notes.count, 5)
        for note in notes { XCTAssertEqual(analysis.role(for: note.id), .footnote, note.text) }
    }

    func testDefaultAsyncParsingMatchesAllPhase3RealFixtures() async throws {
        for name in ["05-right-sidebar", "06-pull-quote", "07-table-with-prose", "08-footnotes", "09-repeated-header-footer"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "PDFLayout"))
            let synchronous = try PdfParser().parse(at: url)
            let asynchronous = try await PdfParser().parseAsync(at: url)
            XCTAssertEqual(synchronous.pages, asynchronous.pages, name)
            XCTAssertEqual(synchronous.chapters.map(\.plainText), asynchronous.chapters.map(\.plainText), name)
            XCTAssertEqual(synchronous.audiobookScript().map(\.text), asynchronous.audiobookScript().map(\.text), name)
            XCTAssertEqual(synchronous.audiobookScript().map(\.id), asynchronous.audiobookScript().map(\.id), name)
        }
    }

    private func verify(_ name: String, markers: [String]) throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "PDFLayout"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let parser = PdfParser(configuration: PdfParserConfiguration(ocr: .init(mode: .never),
            layout: .init(mode: .auto), cleanup: .minimal, extractCoverImage: false))
        let book = try parser.parse(at: url)
        let text = book.allPlainText()
        var cursor = text.startIndex
        for marker in markers {
            guard let range = text.range(of: marker, range: cursor..<text.endIndex) else {
                XCTFail("\(name): missing/out-of-order \(marker)\n\(text)"); break
            }
            cursor = range.upperBound
        }
        func words(_ value: String) -> [String: Int] {
            Dictionary(value.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.map { ($0, 1) }, uniquingKeysWith: +)
        }
        let native = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        for output in [text, book.chapters.map(\.plainText).joined(separator: "\n"),
                       book.audiobookScript(maxCharsPerSegment: 120).map(\.text).joined(separator: "\n")] {
            XCTAssertEqual(words(output), words(native), name)
        }
        XCTAssertTrue(book.pages.allSatisfy { $0.extractionSource == .native })
        XCTAssertEqual(book.pages, try parser.parse(at: url).pages)
        if ProcessInfo.processInfo.environment["PDFKITAUDIO_LAYOUT_DIAGNOSTICS"] == "1" {
            let page = try XCTUnwrap(document.page(at: 0))
            let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
            _ = try PdfLayoutAnalyzer.analyze(fragments: fragments, nativeText: native,
                nativeTextThreshold: 20, pageIndex: 0, mode: .always,
                diagnostics: { print("\(name)\n\($0.jsonString ?? "")") })
        }
    }
}
