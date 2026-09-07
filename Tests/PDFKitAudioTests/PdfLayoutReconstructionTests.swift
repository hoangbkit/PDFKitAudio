import AppKit
import Foundation
import XCTest
@testable import PDFKitAudio

final class PdfLayoutReconstructionTests: XCTestCase {
    func testSplitRunsReconstructWordsSpacesAndPunctuation() {
        let fragments = [
            fragment("frag", id: 0, x: 0.10, y: 0.10, width: 0.040),
            fragment("ment", id: 1, x: 0.142, y: 0.10, width: 0.055),
            fragment("reconstruction", id: 2, x: 0.214, y: 0.10, width: 0.115),
            fragment(",", id: 3, x: 0.330, y: 0.10, width: 0.008),
            fragment("works", id: 4, x: 0.352, y: 0.10, width: 0.050)
        ]

        let lines = PdfLayoutLineBuilder.build(fragments: fragments)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "fragment reconstruction, works")
        XCTAssertEqual(lines[0].fragments.map(\.id), [0, 1, 2, 3, 4])
    }

    func testExistingBoundaryWhitespaceCollapsesToOneSpace() {
        let fragments = [
            fragment("Hello ", id: 0, x: 0.10, y: 0.10, width: 0.060),
            fragment("world", id: 1, x: 0.162, y: 0.10, width: 0.055)
        ]

        let lines = PdfLayoutLineBuilder.build(fragments: fragments)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hello world")
    }

    func testSuperscriptStaysWithNearestCompatibleLine() {
        let fragments = [
            fragment("mc", id: 0, x: 0.10, y: 0.20, width: 0.032, height: 0.035),
            fragment("2", id: 1, x: 0.131, y: 0.188, width: 0.012, height: 0.014)
        ]

        let lines = PdfLayoutLineBuilder.build(fragments: fragments)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "mc2")
        XCTAssertEqual(Set(lines[0].fragments.map(\.id)), Set([0, 1]))
    }

    func testCJKFragmentsDoNotReceiveInappropriateASCIISpaces() {
        let fragments = [
            fragment("你", id: 0, x: 0.10, y: 0.10, width: 0.030),
            fragment("好", id: 1, x: 0.135, y: 0.10, width: 0.030),
            fragment("世", id: 2, x: 0.170, y: 0.10, width: 0.030),
            fragment("界", id: 3, x: 0.205, y: 0.10, width: 0.030)
        ]

        let lines = PdfLayoutLineBuilder.build(fragments: fragments)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "你好世界")
        XCTAssertEqual(lines[0].writingDirection, .leftToRight)
    }

    func testRTLFragmentsUseRightToLeftGeometryOrder() {
        let fragments = [
            fragment("עולם", id: 1, x: 0.43, y: 0.10, width: 0.080),
            fragment("שלום", id: 0, x: 0.55, y: 0.10, width: 0.080)
        ]

        let lines = PdfLayoutLineBuilder.build(fragments: fragments)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].writingDirection, .rightToLeft)
        XCTAssertEqual(lines[0].fragments.map(\.id), [0, 1])
        XCTAssertEqual(lines[0].text, "שלום עולם")
    }

    func testStrongGutterSplitsAlignedColumnsBeforeBlockAssembly() {
        let fragments = [
            fragment("LEFT_ONE", id: 0, x: 0.08, y: 0.10, width: 0.30),
            fragment("RIGHT_ONE", id: 1, x: 0.62, y: 0.10, width: 0.30),
            fragment("LEFT_TWO", id: 2, x: 0.08, y: 0.16, width: 0.30),
            fragment("RIGHT_TWO", id: 3, x: 0.62, y: 0.16, width: 0.30)
        ]

        let lines = PdfLayoutLineBuilder.build(fragments: fragments)
        let blocks = PdfLayoutBlockBuilder.build(lines: lines)

        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].text, "LEFT_ONE\nLEFT_TWO")
        XCTAssertEqual(blocks[1].text, "RIGHT_ONE\nRIGHT_TWO")
        XCTAssertLessThan(blocks[0].rect.maxX, blocks[1].rect.minX)
    }

    func testFirstLineIndentAndHangingIndentStayWithinParagraphBlock() {
        let firstLineIndented = [
            logicalLine("Indented first line", id: 0, x: 0.14, y: 0.10, width: 0.60),
            logicalLine("Continuation one", id: 1, x: 0.10, y: 0.15, width: 0.64),
            logicalLine("Continuation two", id: 2, x: 0.10, y: 0.20, width: 0.64)
        ]
        let hangingIndent = [
            logicalLine("Term and opening text", id: 10, x: 0.10, y: 0.35, width: 0.64),
            logicalLine("Hanging continuation", id: 11, x: 0.14, y: 0.40, width: 0.60),
            logicalLine("More continuation", id: 12, x: 0.14, y: 0.45, width: 0.60)
        ]

        let firstBlocks = PdfLayoutBlockBuilder.build(lines: firstLineIndented)
        let hangingBlocks = PdfLayoutBlockBuilder.build(lines: hangingIndent)

        XCTAssertEqual(firstBlocks.count, 1)
        XCTAssertEqual(firstBlocks[0].lines.count, 3)
        XCTAssertEqual(hangingBlocks.count, 1)
        XCTAssertEqual(hangingBlocks[0].lines.count, 3)
    }

    func testListItemsStayDistinctWhileWrappedContinuationMerges() {
        let lines = [
            logicalLine("1. First item starts here", id: 0, x: 0.10, y: 0.10, width: 0.64),
            logicalLine("and wraps onto another line", id: 1, x: 0.14, y: 0.14, width: 0.60),
            logicalLine("2. Second item starts here", id: 2, x: 0.10, y: 0.19, width: 0.64),
            logicalLine("and also wraps", id: 3, x: 0.14, y: 0.23, width: 0.60)
        ]

        let blocks = PdfLayoutBlockBuilder.build(lines: lines)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].lines.map(\.id), [0, 1])
        XCTAssertEqual(blocks[1].lines.map(\.id), [2, 3])
    }

    func testHeadingRemainsSeparateFromBody() {
        let lines = [
            logicalLine(
                "CHAPTER ONE",
                id: 0,
                x: 0.10,
                y: 0.08,
                width: 0.64,
                height: 0.035,
                fontSize: 20,
                bold: true
            ),
            logicalLine("Body line one", id: 1, x: 0.10, y: 0.13, width: 0.64, fontSize: 12),
            logicalLine("Body line two", id: 2, x: 0.10, y: 0.17, width: 0.64, fontSize: 12)
        ]

        let blocks = PdfLayoutBlockBuilder.build(lines: lines)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].text, "CHAPTER ONE")
        XCTAssertEqual(blocks[1].text, "Body line one\nBody line two")
    }

    func testFootnoteStyleTransitionDoesNotMergeIntoBody() {
        let lines = [
            logicalLine("Body line one", id: 0, x: 0.10, y: 0.10, width: 0.64, fontSize: 12),
            logicalLine("Body line two", id: 1, x: 0.10, y: 0.14, width: 0.64, fontSize: 12),
            logicalLine("1 Footnote text", id: 2, x: 0.10, y: 0.18, width: 0.50, fontSize: 8.5)
        ]

        let blocks = PdfLayoutBlockBuilder.build(lines: lines)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].lines.map(\.id), [0, 1])
        XCTAssertEqual(blocks[1].lines.map(\.id), [2])
    }

    func testNarrowSidebarDoesNotMergeIntoAdjacentBody() {
        let lines = [
            logicalLine("Body one", id: 0, x: 0.08, y: 0.10, width: 0.60),
            logicalLine("Sidebar one", id: 1, x: 0.76, y: 0.12, width: 0.16),
            logicalLine("Body two", id: 2, x: 0.08, y: 0.16, width: 0.60),
            logicalLine("Sidebar two", id: 3, x: 0.76, y: 0.18, width: 0.16)
        ]

        let blocks = PdfLayoutBlockBuilder.build(lines: lines)

        XCTAssertEqual(blocks.count, 2)
        let texts = Set(blocks.map(\.text))
        XCTAssertEqual(texts, Set(["Body one\nBody two", "Sidebar one\nSidebar two"]))
    }

    func testBlockPreservesLineBreakAndHyphenEvidenceForDownstreamCleaner() {
        let lines = [
            logicalLine("multi-", id: 0, x: 0.10, y: 0.10, width: 0.64),
            logicalLine("column", id: 1, x: 0.10, y: 0.14, width: 0.64)
        ]

        let blocks = PdfLayoutBlockBuilder.build(lines: lines)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "multi-\ncolumn")
    }

    func testSupportedFixtureMatrixIsDeterministicAndTextConserving() {
        var checkedPages = 0

        for fixture in TestLayoutFixtureCatalog.all where fixture.support == .supported {
            for (pageIndex, page) in fixture.pages.enumerated() {
                let context = "\(fixture.name) page \(pageIndex)"
                let fragments = syntheticFragments(for: page)

                let firstLines = PdfLayoutLineBuilder.build(fragments: fragments)
                let firstBlocks = PdfLayoutBlockBuilder.build(lines: firstLines)
                let secondLines = PdfLayoutLineBuilder.build(fragments: fragments)
                let secondBlocks = PdfLayoutBlockBuilder.build(lines: secondLines)

                XCTAssertEqual(lineSignatures(firstLines), lineSignatures(secondLines), context)
                XCTAssertEqual(blockSignatures(firstBlocks), blockSignatures(secondBlocks), context)
                assertConservation(
                    fragments: fragments,
                    lines: firstLines,
                    blocks: firstBlocks,
                    context: context
                )
                checkedPages += 1
            }
        }

        XCTAssertGreaterThanOrEqual(checkedPages, 50)
    }

    private func assertConservation(
        fragments: [PdfLayoutFragment],
        lines: [PdfLayoutLine],
        blocks: [PdfLayoutBlock],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectedIDs = fragments.map(\.id).sorted()
        let lineIDs = lines.flatMap { $0.fragments.map(\.id) }.sorted()
        let blockIDs = blocks.flatMap { block in
            block.lines.flatMap { $0.fragments.map(\.id) }
        }.sorted()

        XCTAssertEqual(lineIDs, expectedIDs, "line conservation: \(context)", file: file, line: line)
        XCTAssertEqual(blockIDs, expectedIDs, "block conservation: \(context)", file: file, line: line)

        for logicalLine in lines {
            XCTAssertEqual(
                canonical(logicalLine.text),
                canonical(logicalLine.fragments.map(\.text).joined()),
                "line text conservation: \(context), line \(logicalLine.id)",
                file: file,
                line: line
            )
        }

        for block in blocks {
            XCTAssertEqual(
                canonical(block.text),
                canonical(block.lines.map(\.text).joined()),
                "block text conservation: \(context), block \(block.id)",
                file: file,
                line: line
            )
        }
    }

    private func lineSignatures(_ lines: [PdfLayoutLine]) -> [String] {
        lines.map { logicalLine in
            [
                String(logicalLine.id),
                logicalLine.writingDirection.rawValue,
                canonical(logicalLine.text),
                rectSignature(logicalLine.rect),
                logicalLine.fragments.map { String($0.id) }.joined(separator: ",")
            ].joined(separator: "|")
        }
    }

    private func blockSignatures(_ blocks: [PdfLayoutBlock]) -> [String] {
        blocks.map { block in
            [
                String(block.id),
                canonical(block.text),
                rectSignature(block.rect),
                block.lines.map { String($0.id) }.joined(separator: ",")
            ].joined(separator: "|")
        }
    }

    private func rectSignature(_ rect: CGRect) -> String {
        String(
            format: "%.6f,%.6f,%.6f,%.6f",
            rect.minX,
            rect.minY,
            rect.width,
            rect.height
        )
    }

    private func canonical(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
    }

    private func syntheticFragments(for page: TestLayoutPage) -> [PdfLayoutFragment] {
        page.boxes.enumerated().map { index, box in
            let estimatedGlyphWidth = min(
                box.rect.width,
                max(
                    0.012,
                    CGFloat(box.text.count) * box.fontSize * 0.50 / max(1, page.size.width)
                )
            )
            let glyphHeight = min(
                box.rect.height,
                max(0.010, box.fontSize * 1.25 / max(1, page.size.height))
            )

            let x: CGFloat
            switch box.alignment {
            case .center:
                x = box.rect.midX - estimatedGlyphWidth / 2
            case .right:
                x = box.rect.maxX - estimatedGlyphWidth
            default:
                x = box.rect.minX
            }

            return PdfLayoutFragment(
                id: index,
                text: box.text,
                rect: CGRect(
                    x: max(0, min(1 - estimatedGlyphWidth, x)),
                    y: box.rect.minY,
                    width: estimatedGlyphWidth,
                    height: glyphHeight
                ),
                source: page.rendering == .native ? .native : .ocr,
                confidence: page.rendering == .native ? 1 : 0.90,
                sourceOrder: index,
                style: PdfLayoutStyleHints(
                    fontSize: box.fontSize,
                    isBold: box.fontWeight.rawValue >= NSFont.Weight.semibold.rawValue,
                    isItalic: false
                )
            )
        }
    }

    private func logicalLine(
        _ text: String,
        id: Int,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat = 0.025,
        fontSize: CGFloat = 12,
        bold: Bool = false,
        direction: PdfLayoutWritingDirection = .leftToRight
    ) -> PdfLayoutLine {
        let source = fragment(
            text,
            id: id,
            x: x,
            y: y,
            width: width,
            height: height,
            fontSize: fontSize,
            bold: bold
        )
        return PdfLayoutLine(
            id: id,
            fragments: [source],
            text: text,
            rect: source.rect,
            writingDirection: direction,
            sourceOrder: id
        )
    }

    private func fragment(
        _ text: String,
        id: Int,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat = 0.030,
        fontSize: CGFloat = 12,
        bold: Bool = false
    ) -> PdfLayoutFragment {
        PdfLayoutFragment(
            id: id,
            text: text,
            rect: CGRect(x: x, y: y, width: width, height: height),
            source: .native,
            confidence: 1,
            sourceOrder: id,
            style: PdfLayoutStyleHints(
                fontSize: fontSize,
                isBold: bold,
                isItalic: false
            )
        )
    }
}
