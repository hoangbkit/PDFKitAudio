import AppKit
import Foundation
import XCTest
@testable import PDFKitAudio

final class PdfLayoutRoleClassifierTests: XCTestCase {
    func testHeaderDetectionDoesNotInferLabelsFromSubstrings() throws {
        let strings = ["Surname", "Updated", "Totals", "Alice", "Yesterday", "42"]
        let blocks = strings.enumerated().map { index, text in
            block(index, text: text, x: 0.10 + CGFloat(index % 3) * 0.30,
                y: 0.20 + CGFloat(index / 3) * 0.10, width: 0.17, height: 0.025, font: 10)
        }
        XCTAssertNil(try XCTUnwrap(analyze(blocks).tables.first).headerRowIndex)
        let boldHeaders = blocks.enumerated().map { index, original in
            block(index, text: original.text, x: original.rect.minX, y: original.rect.minY,
                width: 0.17, height: 0.025, font: 10, bold: index < 3)
        }
        XCTAssertEqual(try XCTUnwrap(analyze(boldHeaders).tables.first).headerRowIndex, 0)
    }

    func testSmallCenteredTextWithoutPrefixIsNotACaption() {
        let blocks = [block(0, text: "Primary narrative", x: 0.10, y: 0.12),
                      block(1, text: "More narrative", x: 0.10, y: 0.30),
                      block(2, text: "An ordinary centered remark", x: 0.35, y: 0.62, width: 0.30, font: 9)]
        let result = analyze(blocks)
        XCTAssertNotEqual(result.role(for: 2), .caption)
        XCTAssertFalse(result.readingOrderHints.captionAttachments.contains { $0.blockID == 2 })
    }

    func testCaptionCannotAttachAcrossAnUnrelatedColumn() {
        let blocks = [block(0, text: "Left column narrative", x: 0.08, y: 0.40, width: 0.30),
                      block(1, text: "Right column narrative", x: 0.65, y: 0.57, width: 0.30),
                      block(2, text: "Figure 1. Left illustration", x: 0.08, y: 0.63, width: 0.30, font: 8)]
        let result = analyze(blocks)
        XCTAssertEqual(result.role(for: 2), .caption)
        XCTAssertEqual(result.readingOrderHints.captionAttachments.first?.anchorBlockID, 0)
    }

    func testNumberedSmallBottomNoteTakesPriorityOverListMarker() {
        let result = analyze([block(0, text: "Main narrative", x: 0.12, y: 0.12),
                              block(1, text: "More narrative", x: 0.12, y: 0.32),
                              block(2, text: "1. A referenced footnote", x: 0.12, y: 0.82, font: 8)])
        XCTAssertEqual(result.role(for: 2), .footnote)
        XCTAssertEqual(result.readingOrderHints.footnoteBlockIDs, [2])
    }

    func testTableMaterializationDoesNotConsumeUnmatchedTextInSameBlock() {
        let source = ["Introduction", "Cell A", "Cell B", "Unmatched row", "Conclusion"]
            .enumerated().map { block($0.offset, text: $0.element, x: 0.10, y: CGFloat($0.offset) * 0.10) }
        let lines = source.flatMap(\.lines)
        let combined = PdfLayoutBlock(id: 0, lines: lines, text: source.map(\.text).joined(separator: "\n"),
            rect: CGRect(x: 0.10, y: 0, width: 0.60, height: 0.45), sourceOrder: 0)
        let cells = [1, 2].map { index in
            PdfTableCell(blockID: 0, lineID: lines[index].id, text: lines[index].text, rect: lines[index].rect)
        }
        let table = PdfDetectedTable(cellsByRow: [cells], columnCount: 2, headerRowIndex: nil,
            confidence: 0.95, linearizedText: "Cell A. Cell B.")
        let analysis = PdfSpecialStructureAnalysis(assignments: [.init(blockID: 0, role: .tableCell, confidence: 0.95)],
            tables: [table], readingOrderHints: .init())
        XCTAssertEqual(PdfLayoutAnalyzer.materialize(blocks: [combined], orderedBlockIDs: [0], analysis: analysis),
            "Introduction\n\nCell A. Cell B.\n\nUnmatched row\nConclusion")
    }

    func testHeadingUsesRelativeStyleAndWhitespaceSignals() {
        let pipeline = pipelineForFixture(named: "short-chapter-heading-body")
        let analysis = analyze(pipeline.blocks)
        let titleID = blockID(containing: "TITLE", in: pipeline.blocks)

        XCTAssertNotNil(titleID)
        XCTAssertEqual(titleID.map { analysis.role(for: $0) }, .heading)
        XCTAssertGreaterThanOrEqual(titleID.map { analysis.confidence(for: $0) } ?? 0, 0.70)
    }

    func testBulletsAndNumberedItemsRemainDistinctListRoles() {
        let blocks = [
            block(0, text: "• First item", x: 0.12, y: 0.12),
            block(1, text: "2. Second item", x: 0.12, y: 0.24),
            block(2, text: "Ordinary paragraph", x: 0.12, y: 0.38)
        ]
        let analysis = analyze(blocks)

        XCTAssertEqual(analysis.role(for: 0), .listItem)
        XCTAssertEqual(analysis.role(for: 1), .listItem)
        XCTAssertEqual(analysis.role(for: 2), .body)
    }

    func testPhase4SidebarsRemainPreservedAsSidebarRoles() {
        for name in ["right-sidebar", "left-sidebar", "marginal-note", "multiple-small-sidebars"] {
            let pipeline = pipelineForFixture(named: name)
            let layout = PdfLayoutRegionDetector.segment(blocks: pipeline.blocks)
            let analysis = PdfLayoutRoleClassifier.analyze(blocks: pipeline.blocks, layout: layout)

            XCTAssertFalse(layout.sidebarBlockIDs.isEmpty, name)
            for id in layout.sidebarBlockIDs {
                XCTAssertEqual(analysis.role(for: id), .sidebar, name)
            }
        }
    }

    func testCenteredNarrowCalloutCanBecomePullQuoteWithoutBeingDropped() {
        let pipeline = pipelineForFixture(named: "narrow-callout-between-body-regions")
        let analysis = analyze(pipeline.blocks)
        guard let id = blockID(containing: "CALLOUT", in: pipeline.blocks) else {
            return XCTFail("Missing callout block")
        }

        XCTAssertEqual(analysis.role(for: id), .pullQuote)
        XCTAssertEqual(Set(analysis.assignments.map(\.blockID)), Set(pipeline.blocks.map(\.id)))
    }

    func testCaptionProducesNonDestructiveAnchorHint() {
        let pipeline = pipelineForFixture(named: "image-caption-below-body")
        let analysis = analyze(pipeline.blocks)
        guard let captionID = blockID(containing: "CAPTION", in: pipeline.blocks) else {
            return XCTFail("Missing caption")
        }

        XCTAssertEqual(analysis.role(for: captionID), .caption)
        XCTAssertTrue(analysis.readingOrderHints.captionAttachments.contains { $0.blockID == captionID })

        let layout = PdfLayoutRegionDetector.segment(blocks: pipeline.blocks)
        let ordered = PdfReadingOrderResolver.resolve(
            blocks: pipeline.blocks,
            layout: layout,
            hints: analysis.readingOrderHints
        )
        assertConservation(ordered, blocks: pipeline.blocks)
    }

    func testStrongBottomSmallTextBecomesFootnoteButOrdinaryBottomBodyDoesNot() {
        let fixture = pipelineForFixture(named: "one-footnote")
        let fixtureAnalysis = analyze(fixture.blocks)
        guard let footnoteID = blockID(containing: "FOOTNOTE_1", in: fixture.blocks) else {
            return XCTFail("Missing footnote")
        }
        XCTAssertEqual(fixtureAnalysis.role(for: footnoteID), .footnote)
        XCTAssertTrue(fixtureAnalysis.readingOrderHints.footnoteBlockIDs.contains(footnoteID))

        let ordinary = [
            block(0, text: "Main body", x: 0.12, y: 0.15, font: 12),
            block(1, text: "Legitimate closing paragraph", x: 0.12, y: 0.80, font: 12)
        ]
        let ordinaryAnalysis = analyze(ordinary)
        XCTAssertEqual(ordinaryAnalysis.role(for: 1), .body)
        XCTAssertFalse(ordinaryAnalysis.readingOrderHints.footnoteBlockIDs.contains(1))
    }

    func testTableFixturesDetectStableRowsWithoutTreatingProseColumnsAsTables() {
        for name in [
            "table-2x3-bordered",
            "table-borderless",
            "table-numeric",
            "table-full-page-width",
            "table-inside-single-column",
            "table-multiline-cells",
            "table-between-text-regions"
        ] {
            let pipeline = pipelineForFixture(named: name)
            let analysis = analyze(pipeline.blocks)
            XCTAssertFalse(analysis.tables.isEmpty, name)
            guard let table = analysis.tables.first else { continue }
            XCTAssertGreaterThanOrEqual(table.cellsByRow.count, 2, name)
            XCTAssertGreaterThanOrEqual(table.columnCount, 2, name)
            XCTAssertFalse(table.linearizedText.isEmpty, name)
            XCTAssertGreaterThanOrEqual(table.confidence, 0.72, name)
        }

        let prose = pipelineForFixture(named: "two-column-symmetric")
        XCTAssertTrue(analyze(prose.blocks).tables.isEmpty)
    }

    func testNaturalHeaderTableUsesHeaderAwareLinearization() {
        let rows: [[PdfTableCell]] = [
            [
                cell(blockID: 0, lineID: 0, text: "Name", x: 0.10, y: 0.10),
                cell(blockID: 1, lineID: 1, text: "Revenue", x: 0.40, y: 0.10),
                cell(blockID: 2, lineID: 2, text: "Growth", x: 0.70, y: 0.10)
            ],
            [
                cell(blockID: 3, lineID: 3, text: "Apple", x: 0.10, y: 0.20),
                cell(blockID: 4, lineID: 4, text: "100", x: 0.40, y: 0.20),
                cell(blockID: 5, lineID: 5, text: "12 percent", x: 0.70, y: 0.20)
            ]
        ]
        let text = PdfTableLinearizer.linearize(rows: rows, headerRowIndex: 0)

        XCTAssertTrue(text.contains("Name: Apple"))
        XCTAssertTrue(text.contains("Revenue: 100"))
        XCTAssertTrue(text.contains("Growth: 12 percent"))
    }

    func testAmbiguousTableLikeNumberedListStaysReadableAndIsNotATable() {
        let blocks = [
            block(0, text: "1. Install the application", x: 0.12, y: 0.12),
            block(1, text: "2. Open the document", x: 0.12, y: 0.24),
            block(2, text: "3. Start playback", x: 0.12, y: 0.36)
        ]
        let analysis = analyze(blocks)

        XCTAssertTrue(analysis.tables.isEmpty)
        XCTAssertTrue(analysis.assignments.allSatisfy { $0.role == .listItem })
        XCTAssertEqual(Set(analysis.assignments.map(\.blockID)), Set(blocks.map(\.id)))
    }

    func testClassifierNeverRemovesBlocksAcrossWholeSinglePageFixtureMatrix() {
        let fixtures = TestLayoutFixtureCatalog.all.filter { $0.pages.count == 1 }
        XCTAssertFalse(fixtures.isEmpty)

        for fixture in fixtures {
            let pipeline = pipeline(for: fixture)
            let layout = PdfLayoutRegionDetector.segment(blocks: pipeline.blocks)
            let first = PdfLayoutRoleClassifier.analyze(blocks: pipeline.blocks, layout: layout)
            let second = PdfLayoutRoleClassifier.analyze(blocks: pipeline.blocks, layout: layout)

            XCTAssertEqual(first, second, fixture.name)
            XCTAssertEqual(first.assignments.count, pipeline.blocks.count, fixture.name)
            XCTAssertEqual(Set(first.assignments.map(\.blockID)), Set(pipeline.blocks.map(\.id)), fixture.name)
        }
    }

    private struct PipelineResult {
        let blocks: [PdfLayoutBlock]
    }

    private func analyze(_ blocks: [PdfLayoutBlock]) -> PdfSpecialStructureAnalysis {
        let layout = PdfLayoutRegionDetector.segment(blocks: blocks)
        return PdfLayoutRoleClassifier.analyze(blocks: blocks, layout: layout)
    }

    private func pipelineForFixture(named name: String) -> PipelineResult {
        guard let fixture = TestLayoutFixtureCatalog.byName[name] else {
            XCTFail("Missing fixture \(name)")
            return PipelineResult(blocks: [])
        }
        return pipeline(for: fixture)
    }

    private func pipeline(for fixture: TestLayoutFixture) -> PipelineResult {
        guard let page = fixture.pages.first else { return PipelineResult(blocks: []) }
        let fragments = page.boxes.enumerated().map { index, box in
            let glyphWidth = min(
                box.rect.width,
                max(0.012, CGFloat(box.text.count) * box.fontSize * 0.50 / max(1, page.size.width))
            )
            let glyphHeight = min(
                box.rect.height,
                max(0.010, box.fontSize * 1.25 / max(1, page.size.height))
            )
            let x: CGFloat
            switch box.alignment {
            case .center: x = box.rect.midX - glyphWidth / 2
            case .right: x = box.rect.maxX - glyphWidth
            default: x = box.rect.minX
            }
            return PdfLayoutFragment(
                id: index,
                text: box.text,
                rect: CGRect(
                    x: max(0, min(1 - glyphWidth, x)),
                    y: box.rect.minY,
                    width: glyphWidth,
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
        let lines = PdfLayoutLineBuilder.build(fragments: fragments)
        return PipelineResult(blocks: PdfLayoutBlockBuilder.build(lines: lines))
    }

    private func block(
        _ id: Int,
        text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 0.60,
        height: CGFloat = 0.05,
        font: CGFloat = 12,
        bold: Bool = false
    ) -> PdfLayoutBlock {
        let fragment = PdfLayoutFragment(
            id: id,
            text: text,
            rect: CGRect(x: x, y: y, width: width, height: height),
            source: .native,
            confidence: 1,
            sourceOrder: id,
            style: PdfLayoutStyleHints(fontSize: font, isBold: bold, isItalic: false)
        )
        let line = PdfLayoutLine(
            id: id,
            fragments: [fragment],
            text: text,
            rect: fragment.rect,
            writingDirection: .leftToRight,
            sourceOrder: id
        )
        return PdfLayoutBlock(id: id, lines: [line], text: text, rect: fragment.rect, sourceOrder: id)
    }

    private func cell(
        blockID: Int,
        lineID: Int,
        text: String,
        x: CGFloat,
        y: CGFloat
    ) -> PdfTableCell {
        PdfTableCell(
            blockID: blockID,
            lineID: lineID,
            text: text,
            rect: CGRect(x: x, y: y, width: 0.20, height: 0.04)
        )
    }

    private func blockID(containing marker: String, in blocks: [PdfLayoutBlock]) -> Int? {
        blocks.first(where: { $0.text.contains(marker) })?.id
    }

    private func assertConservation(
        _ result: PdfReadingOrderResult,
        blocks: [PdfLayoutBlock],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.orderedBlockIDs.count, blocks.count, file: file, line: line)
        XCTAssertEqual(Set(result.orderedBlockIDs), Set(blocks.map(\.id)), file: file, line: line)
    }
}
