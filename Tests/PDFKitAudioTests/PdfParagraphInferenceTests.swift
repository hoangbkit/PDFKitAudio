import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfParagraphInferenceTests: XCTestCase {
    // Original prose with the same visual convention as the publisher's
    // Eloquent JavaScript 4th-edition introduction: uniform line spacing,
    // approximately one-em repeated first-line indentation, short final lines.
    private let lines = [
        "Digital documents store positioned letters rather than paragraph objects",
        "so a reader must examine the page to recover its original structure",
        "A short conclusion.",
        "Another paragraph begins at an inset while the spacing stays uniform",
        "The following line returns to the body margin with ordinary wrapping",
        "An ordinary sentence ends here. But this text stays in the same",
        "paragraph on the page.",
        "A third paragraph uses the same inset as the second to mark its start",
        "The continued prose follows the same margin used by the other lines",
        "That paragraph ends."
    ]

    private var expected: String {
        [lines[0..<3].joined(separator: "\n"), lines[3..<7].joined(separator: "\n"),
         lines[7..<10].joined(separator: "\n")].joined(separator: "\n\n")
    }

    private func rects(step: CGFloat = 0.025) -> [CGRect] {
        lines.indices.map { index in
            let inset: CGFloat = [3, 7].contains(index) ? 0.022 : 0
            let width: CGFloat = [2, 6, 9].contains(index) ? 0.34 : 0.70 - inset
            return CGRect(x: 0.15 + inset, y: 0.1 + CGFloat(index) * step, width: width, height: 0.018)
        }
    }

    func testRepeatedIndentationRestoresOnlyParagraphStartsAtUniformSpacing() {
        let text = lines.joined(separator: "\n")
        for step: CGFloat in [0.025, 0.05] {
            XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text, lines: lines, rects: rects(step: step)), expected)
        }
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: expected, lines: lines, rects: rects()), expected)
        XCTAssertTrue(expected.contains("ends here. But this"))
    }

    func testSingleIndentAndShortSentenceEndWithoutVisualEvidenceStayUnchanged() {
        var geometry = rects()
        geometry[7] = CGRect(x: 0.15, y: geometry[7].minY, width: 0.70, height: 0.018)
        let text = lines.joined(separator: "\n")
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text, lines: lines, rects: geometry), text)
        let unindented = geometry.map { CGRect(x: 0.15, y: $0.minY, width: $0.width, height: $0.height) }
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text, lines: lines, rects: unindented), text)
    }

    func testShortFinalLineNeedsIndependentModestSpacingIncrease() {
        var geometry = rects().map { CGRect(x: 0.15, y: $0.minY, width: $0.width, height: $0.height) }
        // 1.28x the normal step: below the legacy strong-gap threshold.
        for index in 3..<geometry.count { geometry[index].origin.y += 0.007 }
        let expected = lines.prefix(3).joined(separator: "\n") + "\n\n" + lines.dropFirst(3).joined(separator: "\n")
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: lines.joined(separator: "\n"),
            lines: lines, rects: geometry), expected)
    }

    func testInferredSeparatorsPreserveEachLineEndingStyleAndAreIdempotent() {
        for separator in ["\n", "\r", "\r\n"] {
            let source = lines.joined(separator: separator)
            let expected = [lines[0..<3], lines[3..<7], lines[7..<10]]
                .map { $0.joined(separator: separator) }
                .joined(separator: separator + separator)
            let restored = PdfParagraphText.restoringBoundaries(in: source, lines: lines, rects: rects())
            XCTAssertEqual(Array(restored.utf8), Array(expected.utf8))
            let repeated = PdfParagraphText.restoringBoundaries(in: restored, lines: lines, rects: rects())
            XCTAssertEqual(Array(repeated.utf8), Array(expected.utf8))
            XCTAssertEqual(restored.utf8.filter { $0 != 0x0A && $0 != 0x0D },
                source.utf8.filter { $0 != 0x0A && $0 != 0x0D })
        }
    }

    func testExplicitSeparatorsLineEndingsAndUnicodeArePreservedExactly() {
        var unicode = lines
        unicode[2] = "Café  déjà vu. Tiếng Việt đẹp. 日本語。"
        let source = unicode.prefix(3).joined(separator: "\r\n") + "\r\n\r\n\r\n"
            + unicode.dropFirst(3).joined(separator: "\r")
        let expected = unicode.prefix(3).joined(separator: "\r\n") + "\r\n\r\n\r\n"
            + unicode[3..<7].joined(separator: "\r") + "\r\r" + unicode[7..<10].joined(separator: "\r")
        let restored = PdfParagraphText.restoringBoundaries(in: source, lines: unicode, rects: rects())
        XCTAssertEqual(Array(restored.utf8), Array(expected.utf8))
        let repeated = PdfParagraphText.restoringBoundaries(in: restored, lines: unicode, rects: rects())
        XCTAssertEqual(Array(repeated.utf8), Array(expected.utf8))
        // Swift groups CRLF into one Character. Compare bytes to remove only
        // newline bytes and detect any changes to the original Unicode text.
        XCTAssertEqual(restored.utf8.filter { $0 != 0x0A && $0 != 0x0D },
            source.utf8.filter { $0 != 0x0A && $0 != 0x0D })
    }

    func testHyphenatedContinuationVetoesAnInferredIndentBoundary() {
        var hyphenated = lines
        hyphenated[2] = "A continued hyphen-"
        let expected = hyphenated.prefix(7).joined(separator: "\n") + "\n\n" + hyphenated.dropFirst(7).joined(separator: "\n")
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: hyphenated.joined(separator: "\n"),
            lines: hyphenated, rects: rects()), expected)
    }

    func testListCodeAndPoetryDoNotAcquireIndentationBasedSplits() {
        for marker in ["1. ", "• ", "- ", "a) ", "// ", "let value = { "] {
            var special = lines
            special[0] = marker + special[0]
            XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: special.joined(separator: "\n"),
                lines: special, rects: rects()), special.joined(separator: "\n"))
        }
        let poem = Array(repeating: "A short verse.", count: lines.count)
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: poem.joined(separator: "\n"),
            lines: poem, rects: rects()), poem.joined(separator: "\n"))
    }

    func testJustifiedContinuationAndOCRJitterDoNotInventExtraBoundaries() {
        var geometry = rects()
        for index in geometry.indices {
            geometry[index].origin.x += index.isMultiple(of: 2) ? 0.0003 : -0.0003
            geometry[index].origin.y += index.isMultiple(of: 2) ? 0.0002 : -0.0002
        }
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: lines.joined(separator: "\n"),
            lines: lines, rects: geometry), expected)
        let justified = rects().map { CGRect(x: 0.15, y: $0.minY, width: 0.70, height: $0.height) }
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: lines.joined(separator: "\n"),
            lines: lines, rects: justified), lines.joined(separator: "\n"))
    }

    func testReliableFontSizeTransitionButMissingHintsDoNotGuess() {
        let text = "Section title\nThe body continues here\nwith an ordinary wrapped line."
        let lines = text.components(separatedBy: "\n")
        var geometry = [CGFloat(0.1), 0.13, 0.155].map {
            CGRect(x: 0.15, y: $0, width: 0.7, height: 0.018)
        }
        geometry[0].size = CGSize(width: 0.25, height: 0.026)
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text, lines: lines, rects: geometry,
            fontSizes: [18, 12, 12]), "Section title\n\nThe body continues here\nwith an ordinary wrapped line.")
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text, lines: lines, rects: geometry), text)
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text, lines: lines, rects: geometry,
            fontSizes: [12, 12, 12]), text)
        geometry[0].size.width = 0.70
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: text, lines: lines, rects: geometry,
            fontSizes: [18, 12, 12]), text, "A larger inline font without heading geometry is insufficient")
    }

    func testRightToLeftIndentationUsesTheLeadingRightEdge() {
        let geometry = rects().map {
            CGRect(x: 1 - $0.maxX, y: $0.minY, width: $0.width, height: $0.height)
        }
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: lines.joined(separator: "\n"),
            lines: lines, rects: geometry, writingDirection: .rightToLeft), expected)
    }

    func testMismatchColumnsInvalidGeometryAndSparseEvidenceAbstain() {
        let source = lines.joined(separator: "\n")
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: source + " Extra.", lines: lines, rects: rects()), source + " Extra.")
        var columnJump = rects()
        columnJump[3].origin.x = 0.90
        var invalid = rects()
        invalid[3] = .null
        var overlap = rects()
        overlap[3].origin.y = overlap[2].minY
        for geometry in [columnJump, invalid, overlap] {
            XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: source, lines: lines, rects: geometry), source)
        }
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: source, lines: lines, rects: rects(),
            fontSizes: [12]), source)
    }

    func testAnalyzedMaterializationRepairsEachBodyColumnWithoutChangingBlocks() {
        let left = block(id: 0, geometry: rects().map {
            CGRect(x: $0.minX * 0.45, y: $0.minY, width: $0.width * 0.45, height: $0.height * 0.45)
        })
        let right = block(id: 1, geometry: rects().map {
            CGRect(x: 0.5 + $0.minX * 0.45, y: $0.minY, width: $0.width * 0.45, height: $0.height * 0.45)
        })
        let analysis = PdfSpecialStructureAnalysis(assignments: [
            .init(blockID: 0, role: .body, confidence: 1),
            .init(blockID: 1, role: .body, confidence: 1)
        ], tables: [], readingOrderHints: .init())
        XCTAssertEqual(PdfLayoutAnalyzer.materialize(blocks: [left, right], orderedBlockIDs: [0, 1],
            analysis: analysis), expected + "\n\n" + expected)
        XCTAssertEqual(left.text, lines.joined(separator: "\n"))
    }

    func testNonBodyRolesAndInlineBoldDoNotDriveParagraphInference() {
        let body = block(id: 0, geometry: rects(), bold: true)
        let analysis = PdfSpecialStructureAnalysis(assignments: [
            .init(blockID: 0, role: .body, confidence: 1)
        ], tables: [], readingOrderHints: .init())
        let noIndent = block(id: 0, geometry: rects().map {
            CGRect(x: 0.15, y: $0.minY, width: $0.width, height: $0.height)
        }, bold: true)
        XCTAssertEqual(PdfLayoutAnalyzer.materialize(blocks: [noIndent], orderedBlockIDs: [0],
            analysis: analysis), noIndent.text)
        for role: PdfLayoutRole in [.listItem, .pullQuote, .caption, .sidebar, .footnote, .tableCell, .unknown] {
            let special = PdfSpecialStructureAnalysis(assignments: [
                .init(blockID: 0, role: role, confidence: 1)
            ], tables: [], readingOrderHints: .init())
            XCTAssertEqual(PdfLayoutAnalyzer.materialize(blocks: [body], orderedBlockIDs: [0],
                analysis: special), body.text)
        }
    }

    func testTwoLineSubregionCannotInferParagraphsFromHeightAlone() {
        let textLines = ["Centered title", "First body line.", "Second body line."]
        let source = textLines.joined(separator: "\n")
        let body = [CGRect(x: 0.15, y: 0.17, width: 0.30, height: 0.018),
                    CGRect(x: 0.15, y: 0.27, width: 0.30, height: 0.018)]
        // The centered title does not overlap the body lane. Its exclusion
        // leaves two regularly spaced lines, without a local spacing baseline.
        for title: CGRect in [.null, CGRect(x: 0.49, y: 0.07, width: 0.15, height: 0.026)] {
            XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: source,
                lines: textLines, rects: [title] + body), source)
        }
        // Preserve the existing rule for a genuine standalone two-line input.
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(
            in: textLines.suffix(2).joined(separator: "\n"),
            lines: Array(textLines.suffix(2)), rects: body),
            textLines.suffix(2).joined(separator: "\n\n"))
    }

    func testCenteredTitleAndTwoBodyLinesKeepTheNativeFastPathOutput() throws {
        for name in ["short-chapter-heading-body", "full-width-title-body"] {
            let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName[name])
            let data = try TestPDFBuilder.layoutPDF(fixture)
            let document = try XCTUnwrap(PDFDocument(data: data))
            let page = try XCTUnwrap(document.page(at: 0))
            let raw = try XCTUnwrap(page.string?.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(PdfPositionedTextExtractor.nativeTextPreservingParagraphs(raw, page: page),
                raw, name)
            let parser = PdfParser(configuration: .init(ocr: .init(mode: .never),
                layout: .init(mode: .auto), cleanup: .minimal, extractCoverImage: false))
            let book = try parser.parse(data: data)
            let expectedText = PdfTextCleaner.cleanPage(raw, configuration: .minimal)
            XCTAssertEqual(book.pages.first?.text, expectedText, name)
            XCTAssertEqual(book.chapters.first?.plainText, expectedText, name)
            XCTAssertEqual(book.allPlainText(), expectedText, name)
        }
    }

    func testHeadingAndCenteredFooterDoNotVetoBodyParagraphs() {
        let textLines = ["Original section heading"] + lines + ["7"]
        let geometry = [CGRect(x: 0.15, y: 0.04, width: 0.28, height: 0.026)]
            + rects() + [CGRect(x: 0.49, y: 0.92, width: 0.015, height: 0.018)]
        let source = textLines.joined(separator: "\n")
        let expectedText = "Original section heading\n\n" + expected + "\n7"
        let repaired = PdfParagraphText.restoringBoundaries(in: source,
            lines: textLines, rects: geometry)
        XCTAssertEqual(repaired, expectedText)
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: repaired,
            lines: textLines, rects: geometry), expectedText)
    }

    func testUnsafePeripheralGeometryDoesNotDisableASeparateBodyRun() {
        for peripheral: CGRect in [.null, CGRect(x: 0.9, y: 0.04, width: 0.1, height: 0.018)] {
            let textLines = ["Running header"] + lines
            let source = textLines.joined(separator: "\n")
            XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: source,
                lines: textLines, rects: [peripheral] + rects()),
                "Running header\n" + expected)
        }
    }

    func testSeparateColumnRunsRetainSourceOrderAndDoNotSplitAcrossTheJump() {
        let left = rects().map {
            CGRect(x: $0.minX * 0.45, y: $0.minY,
                width: $0.width * 0.45, height: $0.height * 0.45)
        }
        let right = left.map {
            CGRect(x: $0.minX + 0.5, y: $0.minY, width: $0.width, height: $0.height)
        }
        let textLines = lines + lines
        let source = textLines.joined(separator: "\n")
        XCTAssertEqual(PdfParagraphText.restoringBoundaries(in: source,
            lines: textLines, rects: left + right), expected + "\n" + expected)
    }

    func testGeneratedBookPageWithHeadingAndCenteredFooterThroughNativeRepair() async throws {
        let data = try nativeFixture(includeRunningMatter: true)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let raw = try XCTUnwrap(page.string?.trimmingCharacters(in: .whitespacesAndNewlines))
        // The old whole-page edge-spread gate rejected this page because the
        // centered footer is far from the body margin.
        let repaired = PdfPositionedTextExtractor.nativeTextPreservingParagraphs(raw, page: page)
        XCTAssertTrue(repaired.contains(expected))
        XCTAssertEqual(repaired.utf8.filter { $0 != 0x0A && $0 != 0x0D },
            raw.utf8.filter { $0 != 0x0A && $0 != 0x0D })
        XCTAssertEqual(PdfPositionedTextExtractor.nativeTextPreservingParagraphs(repaired, page: page), repaired)
        for mode: PdfLayoutMode in [.auto, .always] {
            let parser = PdfParser(configuration: .init(ocr: .init(mode: .never),
                layout: .init(mode: mode), cleanup: .minimal, extractCoverImage: false))
            let book = try parser.parse(data: data)
            XCTAssertTrue(book.pages.first?.text.contains(expected) == true)
            XCTAssertTrue(book.chapters.first?.plainText.contains(expected) == true)
            XCTAssertTrue(book.allPlainText().contains(expected))
            let repeated = try await parser.parseAsync(data: data)
            XCTAssertEqual(repeated.pages, book.pages)
        }
        let legacy = try PdfParser(configuration: .init(ocr: .init(mode: .never),
            layout: .init(mode: .never), cleanup: .minimal, extractCoverImage: false)).parse(data: data)
        XCTAssertEqual(legacy.pages.first?.text, PdfTextCleaner.cleanPage(raw, configuration: .minimal))
    }

    func testGeneratedIndentedPDFThroughNativeRepairAndFinalParserModes() async throws {
        let data = try nativeFixture()
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let raw = try XCTUnwrap(page.string?.trimmingCharacters(in: .whitespacesAndNewlines))
        // Verify the eligibility fix directly: first-line insets used to veto repair.
        XCTAssertEqual(PdfPositionedTextExtractor.nativeTextPreservingParagraphs(raw, page: page), expected)
        for mode: PdfLayoutMode in [.auto, .always] {
            let parser = PdfParser(configuration: .init(ocr: .init(mode: .never),
                layout: .init(mode: mode), cleanup: .minimal, extractCoverImage: false))
            let book = try parser.parse(data: data)
            XCTAssertEqual(book.pages.first?.text, expected)
            XCTAssertEqual(book.chapters.first?.plainText, expected)
            XCTAssertEqual(book.allPlainText(), expected)
            let repeated = try await parser.parseAsync(data: data)
            XCTAssertEqual(book.pages, repeated.pages)
            XCTAssertEqual(book.chapters.first?.ttsChunks().count, 3)
            XCTAssertTrue(book.chapters.first?.htmlPreview.contains("</p><p>") == true)
        }
        let legacy = try PdfParser(configuration: .init(ocr: .init(mode: .never),
            layout: .init(mode: .never), cleanup: .minimal, extractCoverImage: false)).parse(data: data)
        XCTAssertEqual(legacy.pages.first?.text, PdfTextCleaner.cleanPage(raw, configuration: .minimal))
    }

    func testOCRFallbackAndAnalyzedModesRestoreTheSameIndentation() async throws {
        let data = try TestPDFBuilder.digitalPDF(pages: [""])
        let geometry = rects()
        let observations = lines.enumerated().map { index, text in
            PdfOCREngine.OCRObservation(text: text, rect: geometry[index], confidence: 1, sourceOrder: index)
        }
        let source = lines.joined(separator: "\n")
        for mode: PdfLayoutMode in [.auto, .always] {
            let parser = PdfParser(ocrConfiguration: .init(mode: .always), cleanupConfiguration: .minimal,
                extractCoverImage: false, layoutConfiguration: .init(mode: mode),
                ocrRecognizer: { _, _ in .init(text: source, confidence: 1, observations: observations) })
            let book = try await parser.parseAsync(data: data)
            XCTAssertEqual(book.pages.first?.text, expected)
            XCTAssertEqual(book.chapters.first?.plainText, expected)
            XCTAssertEqual(book.allPlainText(), expected)
            XCTAssertEqual(book.pages.first?.extractionSource, .ocr)
        }
    }

    private func block(id: Int, geometry: [CGRect], bold: Bool = false) -> PdfLayoutBlock {
        let reconstructed = lines.enumerated().map { index, text in
            let fragment = PdfLayoutFragment(id: id * 100 + index, text: text, rect: geometry[index],
                source: .native, confidence: 1, sourceOrder: index,
                style: .init(fontSize: 12, isBold: bold, isItalic: false))
            return PdfLayoutLine(id: index, fragments: [fragment], text: text, rect: geometry[index],
                writingDirection: .leftToRight, sourceOrder: index)
        }
        return PdfLayoutBlock(id: id, lines: reconstructed, text: lines.joined(separator: "\n"),
            rect: geometry.dropFirst().reduce(geometry[0]) { $0.union($1) }, sourceOrder: id)
    }

    private func nativeFixture(includeRunningMatter: Bool = false) throws -> Data {
        var boxes = lines.enumerated().map { index, text in
            TestLayoutTextBox("line-\(index)", text: text,
                x: 0.15 + ([3, 7].contains(index) ? 0.022 : 0),
                y: 0.1 + CGFloat(index) * 0.025, width: 0.75, height: 0.022, fontSize: 12)
        }
        if includeRunningMatter {
            boxes.insert(TestLayoutTextBox("heading", text: "Original section heading",
                x: 0.15, y: 0.04, width: 0.6, height: 0.032, fontSize: 18), at: 0)
            boxes.append(TestLayoutTextBox("footer", text: "7",
                x: 0.49, y: 0.92, width: 0.03, height: 0.022, fontSize: 12))
        }
        return try TestPDFBuilder.layoutPDF(.init(name: "uniform-spacing-first-line-indents",
            category: "simple", support: .supported, pages: [.init(boxes: boxes)],
            expectedMarkerOrder: [], notes: "Original prose; repeated first-line indents, uniform spacing"))
    }
}
