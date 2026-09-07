import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfReadingOrderResolverTests: XCTestCase {
    func testSupportedColumnFixturesMatchExactExpectedMarkerOrder() {
        let fixtures = TestLayoutFixtureCatalog.all.filter {
            $0.support == .supported && $0.category == "columns"
        }
        XCTAssertFalse(fixtures.isEmpty)

        for fixture in fixtures {
            let pipeline = pipeline(for: fixture)
            let layout = PdfLayoutRegionDetector.segment(blocks: pipeline.blocks)
            let result = PdfReadingOrderResolver.resolve(blocks: pipeline.blocks, layout: layout)

            XCTAssertFalse(result.usedFallback, fixture.name)
            XCTAssertEqual(
                observedMarkers(result: result, blocks: pipeline.blocks, expected: fixture.expectedMarkerOrder),
                fixture.expectedMarkerOrder,
                fixture.name
            )
            assertExactConservation(result, blocks: pipeline.blocks, context: fixture.name)
        }
    }

    func testSupportedMixedRegionFixturesMatchExactExpectedMarkerOrder() {
        let fixtures = TestLayoutFixtureCatalog.all.filter {
            $0.support == .supported && $0.category == "mixed-regions"
        }
        XCTAssertFalse(fixtures.isEmpty)

        for fixture in fixtures {
            let pipeline = pipeline(for: fixture)
            let layout = PdfLayoutRegionDetector.segment(blocks: pipeline.blocks)
            let result = PdfReadingOrderResolver.resolve(blocks: pipeline.blocks, layout: layout)

            XCTAssertFalse(result.usedFallback, fixture.name)
            XCTAssertEqual(
                observedMarkers(result: result, blocks: pipeline.blocks, expected: fixture.expectedMarkerOrder),
                fixture.expectedMarkerOrder,
                fixture.name
            )
            assertExactConservation(result, blocks: pipeline.blocks, context: fixture.name)
        }
    }

    func testRepeatedResolutionIsDeterministicAcrossComplexFixtures() {
        let fixtures = TestLayoutFixtureCatalog.all.filter {
            $0.pages.count == 1
                && ($0.category == "columns" || $0.category == "mixed-regions" || $0.category == "side-content")
        }

        for fixture in fixtures {
            let pipeline = pipeline(for: fixture)
            let layout = PdfLayoutRegionDetector.segment(blocks: pipeline.blocks)
            let first = PdfReadingOrderResolver.resolve(blocks: pipeline.blocks, layout: layout)
            let second = PdfReadingOrderResolver.resolve(blocks: pipeline.blocks, layout: layout)
            XCTAssertEqual(first, second, fixture.name)
            assertExactConservation(first, blocks: pipeline.blocks, context: fixture.name)
        }
    }

    func testLTRAndRTLColumnSequencingUseOppositeHorizontalOrder() {
        let blocks = [
            block(0, text: "LEFT_TOP", x: 0.08, y: 0.10, direction: .leftToRight),
            block(1, text: "LEFT_BOTTOM", x: 0.08, y: 0.30, direction: .leftToRight),
            block(2, text: "RIGHT_TOP", x: 0.60, y: 0.10, direction: .rightToLeft),
            block(3, text: "RIGHT_BOTTOM", x: 0.60, y: 0.30, direction: .rightToLeft)
        ]
        let layout = twoColumnLayout(blocks: blocks)

        let ltr = PdfReadingOrderResolver.resolve(
            blocks: blocks,
            layout: layout,
            hints: PdfReadingOrderHints(writingDirection: .leftToRight)
        )
        let rtl = PdfReadingOrderResolver.resolve(
            blocks: blocks,
            layout: layout,
            hints: PdfReadingOrderHints(writingDirection: .rightToLeft)
        )

        XCTAssertEqual(ltr.orderedBlockIDs, [0, 1, 2, 3])
        XCTAssertEqual(rtl.orderedBlockIDs, [2, 3, 0, 1])
    }

    func testSidebarDefaultPolicySpeaksSidebarAfterPrimaryRegion() {
        let pipeline = pipelineForFixture(named: "right-sidebar")
        let layout = PdfLayoutRegionDetector.segment(blocks: pipeline.blocks)
        let result = PdfReadingOrderResolver.resolve(blocks: pipeline.blocks, layout: layout)
        let expected = TestLayoutFixtureCatalog.byName["right-sidebar"]!.expectedMarkerOrder

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(
            observedMarkers(result: result, blocks: pipeline.blocks, expected: expected),
            expected
        )
    }

    func testFootnoteHintMovesFootnoteAfterMainBody() {
        let blocks = [
            block(0, text: "BODY1", x: 0.10, y: 0.10),
            block(1, text: "FOOTNOTE", x: 0.10, y: 0.20),
            block(2, text: "BODY2", x: 0.10, y: 0.30)
        ]
        let layout = singleRegionLayout(blocks: blocks)
        let result = PdfReadingOrderResolver.resolve(
            blocks: blocks,
            layout: layout,
            hints: PdfReadingOrderHints(footnoteBlockIDs: [1])
        )

        XCTAssertEqual(result.orderedBlockIDs, [0, 2, 1])
        XCTAssertEqual(result.removedEdges.count, 1)
        XCTAssertEqual(result.removedEdges.first?.reason, .sameColumn)
    }

    func testCaptionAttachmentCanOverrideWeakGeometricOrder() {
        let blocks = [
            block(0, text: "CAPTION", x: 0.12, y: 0.10),
            block(1, text: "ANCHOR", x: 0.12, y: 0.30)
        ]
        let layout = singleRegionLayout(blocks: blocks)
        let result = PdfReadingOrderResolver.resolve(
            blocks: blocks,
            layout: layout,
            hints: PdfReadingOrderHints(
                captionAttachments: [PdfReadingOrderAttachment(blockID: 0, anchorBlockID: 1)]
            )
        )

        XCTAssertEqual(result.orderedBlockIDs, [1, 0])
        XCTAssertEqual(result.removedEdges.count, 1)
        XCTAssertEqual(result.removedEdges.first?.reason, .sameColumn)
    }

    func testForcedCycleRemovesLowestConfidenceEdgeAndPreservesAllBlocks() {
        let blocks = [
            block(0, text: "A", x: 0.10, y: 0.10),
            block(1, text: "B", x: 0.10, y: 0.20),
            block(2, text: "C", x: 0.10, y: 0.30)
        ]
        let layout = singleRegionLayout(blocks: blocks)
        let forcedCycle = PdfReadingOrderEdge(
            fromBlockID: 2,
            toBlockID: 0,
            confidence: 0.20,
            reason: .semanticHint
        )
        let result = PdfReadingOrderResolver.resolve(
            blocks: blocks,
            layout: layout,
            hints: PdfReadingOrderHints(additionalPrecedence: [forcedCycle])
        )

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.orderedBlockIDs, [0, 1, 2])
        XCTAssertEqual(result.removedEdges, [forcedCycle])
        assertExactConservation(result, blocks: blocks, context: "forced cycle")
    }

    func testAmbiguousIrregularOverlapFallsBackWithoutTextLoss() {
        let blocks = [
            block(0, text: "A", x: 0.10, y: 0.10, width: 0.60, height: 0.20),
            block(1, text: "B", x: 0.12, y: 0.12, width: 0.58, height: 0.18)
        ]
        let rect = blocks[0].rect.union(blocks[1].rect)
        let layout = PdfPageRegionLayout(
            regions: [PdfLayoutRegion(
                id: 0,
                rect: rect,
                kind: .irregular,
                columns: [],
                primaryBlockIDs: [0, 1],
                sidebarBlockIDs: [],
                spanningBlockIDs: [],
                confidence: 0.40
            )],
            primaryColumnCount: 1,
            sidebarBlockIDs: [],
            spanningBlockIDs: []
        )

        let result = PdfReadingOrderResolver.resolve(blocks: blocks, layout: layout)

        XCTAssertTrue(result.usedFallback)
        XCTAssertGreaterThan(result.geometryConflictCount, 0)
        assertExactConservation(result, blocks: blocks, context: "ambiguous overlap")
    }

    func testMissingRegionAssignmentFallsBackAndPreservesEveryBlock() {
        let blocks = [
            block(0, text: "A", x: 0.10, y: 0.10),
            block(1, text: "B", x: 0.10, y: 0.20)
        ]
        let layout = PdfPageRegionLayout(
            regions: [PdfLayoutRegion(
                id: 0,
                rect: blocks[0].rect,
                kind: .singleColumn,
                columns: [PdfLayoutColumn(id: 0, rect: blocks[0].rect, blockIDs: [0], confidence: 0.90)],
                primaryBlockIDs: [0],
                sidebarBlockIDs: [],
                spanningBlockIDs: [],
                confidence: 0.90
            )],
            primaryColumnCount: 1,
            sidebarBlockIDs: [],
            spanningBlockIDs: []
        )

        let result = PdfReadingOrderResolver.resolve(blocks: blocks, layout: layout)
        XCTAssertTrue(result.usedFallback)
        assertExactConservation(result, blocks: blocks, context: "missing assignment")
    }

    func testRealPDFKitTwoColumnFixtureResolvesColumnMajorMarkerOrder() throws {
        guard let fixture = TestLayoutFixtureCatalog.byName["two-column-symmetric"] else {
            return XCTFail("Missing fixture")
        }
        let data = try TestPDFBuilder.layoutPDF(fixture)
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else {
            return XCTFail("Could not build fixture")
        }

        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
        let lines = PdfLayoutLineBuilder.build(fragments: fragments)
        let blocks = PdfLayoutBlockBuilder.build(lines: lines)
        let layout = PdfLayoutRegionDetector.segment(blocks: blocks)
        let result = PdfReadingOrderResolver.resolve(blocks: blocks, layout: layout)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(
            observedMarkers(result: result, blocks: blocks, expected: fixture.expectedMarkerOrder),
            fixture.expectedMarkerOrder
        )
        assertExactConservation(result, blocks: blocks, context: "real PDFKit two-column")
    }

    private struct PipelineResult {
        let fragments: [PdfLayoutFragment]
        let lines: [PdfLayoutLine]
        let blocks: [PdfLayoutBlock]
    }

    private func pipelineForFixture(named name: String) -> PipelineResult {
        guard let fixture = TestLayoutFixtureCatalog.byName[name] else {
            XCTFail("Missing fixture \(name)")
            return PipelineResult(fragments: [], lines: [], blocks: [])
        }
        return pipeline(for: fixture)
    }

    private func pipeline(for fixture: TestLayoutFixture) -> PipelineResult {
        guard let page = fixture.pages.first else {
            return PipelineResult(fragments: [], lines: [], blocks: [])
        }
        let fragments = page.boxes.enumerated().map { index, box in
            let glyphWidth = min(
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
                x = box.rect.midX - glyphWidth / 2
            case .right:
                x = box.rect.maxX - glyphWidth
            default:
                x = box.rect.minX
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
        let blocks = PdfLayoutBlockBuilder.build(lines: lines)
        return PipelineResult(fragments: fragments, lines: lines, blocks: blocks)
    }

    private func observedMarkers(
        result: PdfReadingOrderResult,
        blocks: [PdfLayoutBlock],
        expected: [String]
    ) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        var resultMarkers: [String] = []
        for id in result.orderedBlockIDs {
            guard let text = byID[id]?.text else { continue }
            let matches = expected.compactMap { marker -> (String, Int)? in
                guard let range = text.range(of: marker) else { return nil }
                return (marker, text.distance(from: text.startIndex, to: range.lowerBound))
            }.sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.0 < $1.0
            }
            resultMarkers += matches.map(\.0)
        }
        return resultMarkers
    }

    private func assertExactConservation(
        _ result: PdfReadingOrderResult,
        blocks: [PdfLayoutBlock],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.orderedBlockIDs.count, blocks.count, context, file: file, line: line)
        XCTAssertEqual(Set(result.orderedBlockIDs), Set(blocks.map(\.id)), context, file: file, line: line)
    }

    private func block(
        _ id: Int,
        text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 0.30,
        height: CGFloat = 0.05,
        direction: PdfLayoutWritingDirection = .leftToRight
    ) -> PdfLayoutBlock {
        let fragment = PdfLayoutFragment(
            id: id,
            text: text,
            rect: CGRect(x: x, y: y, width: width, height: height),
            source: .native,
            confidence: 1,
            sourceOrder: id,
            style: PdfLayoutStyleHints(fontSize: 12, isBold: false, isItalic: false)
        )
        let line = PdfLayoutLine(
            id: id,
            fragments: [fragment],
            text: text,
            rect: fragment.rect,
            writingDirection: direction,
            sourceOrder: id
        )
        return PdfLayoutBlock(
            id: id,
            lines: [line],
            text: text,
            rect: fragment.rect,
            sourceOrder: id
        )
    }

    private func singleRegionLayout(blocks: [PdfLayoutBlock]) -> PdfPageRegionLayout {
        let rect = blocks.dropFirst().reduce(blocks.first?.rect ?? .zero) { $0.union($1.rect) }
        let ids = blocks.map(\.id)
        return PdfPageRegionLayout(
            regions: [PdfLayoutRegion(
                id: 0,
                rect: rect,
                kind: .singleColumn,
                columns: [PdfLayoutColumn(id: 0, rect: rect, blockIDs: ids, confidence: 0.88)],
                primaryBlockIDs: ids,
                sidebarBlockIDs: [],
                spanningBlockIDs: [],
                confidence: 0.88
            )],
            primaryColumnCount: 1,
            sidebarBlockIDs: [],
            spanningBlockIDs: []
        )
    }

    private func twoColumnLayout(blocks: [PdfLayoutBlock]) -> PdfPageRegionLayout {
        let left = blocks.filter { $0.rect.minX < 0.50 }
        let right = blocks.filter { $0.rect.minX >= 0.50 }
        let leftRect = left.dropFirst().reduce(left.first?.rect ?? .zero) { $0.union($1.rect) }
        let rightRect = right.dropFirst().reduce(right.first?.rect ?? .zero) { $0.union($1.rect) }
        let allRect = leftRect.union(rightRect)
        return PdfPageRegionLayout(
            regions: [PdfLayoutRegion(
                id: 0,
                rect: allRect,
                kind: .columnar,
                columns: [
                    PdfLayoutColumn(id: 0, rect: leftRect, blockIDs: left.map(\.id), confidence: 0.94),
                    PdfLayoutColumn(id: 1, rect: rightRect, blockIDs: right.map(\.id), confidence: 0.94)
                ],
                primaryBlockIDs: blocks.map(\.id),
                sidebarBlockIDs: [],
                spanningBlockIDs: [],
                confidence: 0.94
            )],
            primaryColumnCount: 2,
            sidebarBlockIDs: [],
            spanningBlockIDs: []
        )
    }
}
