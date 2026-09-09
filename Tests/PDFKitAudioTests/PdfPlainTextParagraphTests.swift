import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

/// Plain-text contracts for callers that own their paragraph caching/chunking.
/// These tests deliberately do not call audiobookScript or TTSChunker.
final class PdfPlainTextParagraphTests: XCTestCase {
    func testRealSingleColumnFixtureSeparatesTitleHeadingsAndParagraphs() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "01-single-column",
            withExtension: "pdf", subdirectory: "PDFLayout"))
        let data = try Data(contentsOf: url)
        let body = """
        Layout aware parsing should preserve natural reading order.
        Each region contains selectable native text for deterministic tests.
        The analyzer should avoid omission, duplication, and interleaving.
        Geometry provides strong evidence for columns, sidebars, and roles.
        """
        let expected = ["Single Column Article", "Section One", body,
                        "Section Two", body, "Section Three", body].joined(separator: "\n\n")
        let parser = PdfParser(configuration: .init(ocr: .init(mode: .never), extractCoverImage: false))
        let book = try parser.parse(data: data)
        XCTAssertEqual(book.pages.map(\.text), [expected])
        XCTAssertEqual(book.chapters.map(\.plainText), [expected])
        XCTAssertEqual(book.allPlainText(), expected)
        let repeated = try await parser.parseAsync(data: data)
        XCTAssertEqual(repeated.pages, book.pages)
        XCTAssertEqual(repeated.allPlainText(), expected)

        let legacy = try PdfParser(configuration: .init(ocr: .init(mode: .never),
            layout: .init(mode: .never), extractCoverImage: false)).parse(data: data)
        XCTAssertEqual(legacy.allPlainText(), expected.replacingOccurrences(of: "\n\n", with: "\n"))
    }

    func testExplicitParagraphsAndLineBreaksSurviveCleanupPagesAndChapters() throws {
        let source = "First   line.\r\nSecond line.\r\n\r\n\r\nNext paragraph.\r\nIts continuation."
        let expected = "First line.\nSecond line.\n\nNext paragraph.\nIts continuation."
        let data = try TestPDFBuilder.digitalPDF(pages: ["", ""])
        let parser = PdfParser(ocrConfiguration: .init(mode: .always), extractCoverImage: false,
            ocrRecognizer: { _, _ in .init(text: source, confidence: 1) })
        let book = try parser.parse(data: data)
        XCTAssertEqual(book.pages.map(\.text), [expected, expected])
        XCTAssertEqual(book.chapters.map(\.plainText), [expected + "\n\n" + expected])
        XCTAssertEqual(book.allPlainText(), expected + "\n\n" + expected)
        XCTAssertEqual(book.pages, try parser.parse(data: data).pages)
    }

    func testAutoPreservesVisualParagraphsInPagesChaptersAndWholeBook() throws {
        let paragraphs = [["First paragraph starts here.", "A continued line of prose.", "First paragraph ends here."],
                          ["Second paragraph starts here.", "Another continued line.", "Second paragraph ends here."]]
        let boxes = paragraphs.enumerated().flatMap { paragraph, lines in
            lines.enumerated().map { line, text in
                TestLayoutTextBox("P\(paragraph)L\(line)", text: text, x: 0.12,
                    y: 0.12 + CGFloat(paragraph) * 0.16 + CGFloat(line) * 0.025,
                    width: 0.75, height: 0.022, fontSize: 12)
            }
        }
        let fixture = TestLayoutFixture(name: "plain-text-paragraphs", category: "simple", support: .supported,
            pages: [.init(boxes: boxes)], expectedMarkerOrder: [], notes: "Two three-line paragraphs separated by whitespace")
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let raw = try XCTUnwrap(document.page(at: 0)?.string)
        let expected = paragraphs.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
        func parser(_ mode: PdfLayoutMode) -> PdfParser {
            PdfParser(configuration: .init(ocr: .init(mode: .never), layout: .init(mode: mode),
                cleanup: .minimal, extractCoverImage: false))
        }
        let automatic = try parser(.auto).parse(data: data)
        XCTAssertEqual(automatic.pages.first?.text, expected)
        XCTAssertEqual(automatic.chapters.first?.plainText, expected)
        XCTAssertEqual(automatic.allPlainText(), expected)
        XCTAssertEqual(automatic.pages, try parser(.auto).parse(data: data).pages)
        XCTAssertEqual(try parser(.never).parse(data: data).pages.first?.text,
            PdfTextCleaner.cleanPage(raw, configuration: .minimal))
        let analyzed = try parser(.always).parse(data: data)
        XCTAssertEqual(analyzed.pages.first?.text, expected)
        XCTAssertEqual(analyzed.chapters.first?.plainText, expected)
        XCTAssertEqual(analyzed.pages, try parser(.always).parse(data: data).pages)
    }

    func testOCRGeometryRestoresParagraphsThroughAsyncParser() async throws {
        let lines = ["First paragraph begins.", "Its second line.", "Its final line.",
                     "Next paragraph begins.", "Another line.", "Its final sentence."]
        let observations = lines.enumerated().map { index, text in
            PdfOCREngine.OCRObservation(text: text,
                rect: rect(y: 0.1 + CGFloat(index) * 0.025 + (index >= 3 ? 0.025 : 0)),
                confidence: 1, sourceOrder: index)
        }
        let parser = PdfParser(ocrConfiguration: .init(mode: .always), extractCoverImage: false,
            ocrRecognizer: { _, _ in .init(text: lines.joined(separator: "\n"), confidence: 1,
                observations: observations) })
        let data = try TestPDFBuilder.digitalPDF(pages: [""])
        let expected = lines.prefix(3).joined(separator: "\n") + "\n\n" + lines.suffix(3).joined(separator: "\n")
        let book = try await parser.parseAsync(data: data)
        XCTAssertEqual(book.pages.first?.text, expected)
        XCTAssertEqual(book.pages.first?.extractionSource, .ocr)
        XCTAssertEqual(book.chapters.first?.plainText, expected)
        XCTAssertEqual(book.allPlainText(), expected)
    }

    func testSpacingCheckPreservesExplicitBlankLinesAndExactUnicodeText() {
        let lines = ["Café  déjà vu.", "Tiếng Việt đẹp.", "日本語の段落。", "Final line."]
        let text = lines[0] + "\n\n" + lines[1] + "\n" + lines[2] + "\n" + lines[3]
        let expected = lines[0] + "\n\n" + lines[1] + "\n\n" + lines[2] + "\n" + lines[3]
        let rects = [0.1, 0.125, 0.18, 0.205].map { rect(y: $0) }
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text, lines: lines, rects: rects), expected)
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: expected, lines: lines, rects: rects), expected)
    }

    func testUniformAndDoubleSpacedLinesDoNotBecomeSeparateParagraphs() {
        let lines = ["First line.", "Second line.", "Third line.", "Fourth line."]
        let text = lines.joined(separator: "\n")
        for spacing: CGFloat in [0.025, 0.05, 0.09] {
            let rects = lines.indices.map { rect(y: 0.1 + CGFloat($0) * spacing) }
            XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text, lines: lines, rects: rects), text)
        }
    }

    func testTwoWidelySeparatedLinesBecomeParagraphsButCloseLinesDoNot() {
        let lines = ["One paragraph.", "Another paragraph."]
        let text = lines.joined(separator: "\n")
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text, lines: lines,
            rects: [rect(y: 0.1), rect(y: 0.2)]), lines.joined(separator: "\n\n"))
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text, lines: lines,
            rects: [rect(y: 0.1), rect(y: 0.125)]), text)
    }

    func testMismatchedTextOverlapsColumnsAndInvalidGeometryKeepSourceUntouched() {
        let lines = ["First.", "Second.", "Third."]
        let text = lines.joined(separator: "\n")
        let valid = [rect(y: 0.1), rect(y: 0.125), rect(y: 0.2)]
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text + " Extra.", lines: lines, rects: valid), text + " Extra.")
        let invalidCases = [
            [rect(y: 0.1), rect(y: 0.1), rect(y: 0.2)],
            [rect(y: 0.2), rect(y: 0.125), rect(y: 0.1)],
            [rect(y: 0.1), CGRect(x: 0.8, y: 0.125, width: 0.1, height: 0.02), rect(y: 0.2)],
            [rect(y: 0.1), CGRect.null, rect(y: 0.2)],
            [rect(y: 0.1)]
        ]
        for rects in invalidCases {
            XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text, lines: lines, rects: rects), text)
        }
    }

    private func rect(y: CGFloat) -> CGRect {
        CGRect(x: 0.1, y: y, width: 0.7, height: 0.02)
    }
}
