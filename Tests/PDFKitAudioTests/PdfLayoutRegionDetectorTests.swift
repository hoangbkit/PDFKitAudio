import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutRegionDetectorTests: XCTestCase {
    func testAllCanonicalTwoColumnFixturesProduceTwoPrimaryColumns() {
        for name in [
            "two-column-symmetric",
            "two-column-60-40",
            "two-column-40-60",
            "two-column-narrow-gutter",
            "two-column-wide-gutter",
            "columns-unequal-final-heights",
            "left-column-ending-early",
            "right-column-begins-lower",
            "short-column-beside-long-column",
            "columns-with-indented-paragraphs"
        ] {
            let layout = layoutForFixture(named: name)
            XCTAssertEqual(layout.primaryColumnCount, 2, name)
            XCTAssertEqual(layout.regions.count, 1, name)
            XCTAssertEqual(layout.regions.first?.kind, .columnar, name)
            XCTAssertEqual(layout.regions.first?.columns.count, 2, name)
            XCTAssertTrue(layout.spanningBlockIDs.isEmpty, name)
        }
    }

    func testThreeColumnFixtureProducesThreePrimaryColumns() {
        let layout = layoutForFixture(named: "three-column")

        XCTAssertEqual(layout.primaryColumnCount, 3)
        XCTAssertEqual(layout.regions.count, 1)
        XCTAssertEqual(layout.regions.first?.kind, .columnar)
        XCTAssertEqual(layout.regions.first?.columns.count, 3)
    }

    func testMixedRegionsSplitAtObservableSpanningBlocks() {
        assertRegionKinds(
            fixture: "full-width-title-two-columns",
            expected: [.spanning, .columnar]
        )
        assertRegionKinds(
            fixture: "full-width-abstract-two-columns",
            expected: [.spanning, .columnar]
        )

        // These fixture suffixes are left-aligned inside wide drawing boxes.
        // PDFKit selection geometry exposes glyph bounds, not the invisible box
        // width, so a short suffix that never crosses the gutter must not be
        // promoted to spanning based on information the extractor does not have.
        assertRegionKinds(
            fixture: "two-columns-full-width-conclusion",
            expected: [.columnar]
        )
        assertRegionKinds(
            fixture: "title-columns-footer-note",
            expected: [.spanning, .columnar]
        )
        assertRegionKinds(
            fixture: "single-two-single",
            expected: [.columnar]
        )
        assertRegionKinds(
            fixture: "abstract-columns-summary",
            expected: [.spanning, .columnar]
        )
    }

    func testExplicitSingleTwoSingleGeometryCreatesVerticalTransitions() {
        let fragments = [
            fragment("TOP FULL WIDTH", id: 0, x: 0.12, y: 0.06, width: 0.76),
            fragment("LEFT ONE", id: 1, x: 0.08, y: 0.20, width: 0.30),
            fragment("RIGHT ONE", id: 2, x: 0.62, y: 0.20, width: 0.30),
            fragment("LEFT TWO", id: 3, x: 0.08, y: 0.32, width: 0.30),
            fragment("RIGHT TWO", id: 4, x: 0.62, y: 0.32, width: 0.30),
            fragment("BOTTOM FULL WIDTH", id: 5, x: 0.12, y: 0.52, width: 0.76)
        ]
        let lines = PdfLayoutLineBuilder.build(fragments: fragments)
        let blocks = PdfLayoutBlockBuilder.build(lines: lines)
        let layout = PdfLayoutRegionDetector.segment(blocks: blocks)

        XCTAssertEqual(layout.regions.map(\.kind), [.spanning, .columnar, .spanning])
        XCTAssertEqual(layout.primaryColumnCount, 2)
        XCTAssertEqual(layout.spanningBlockIDs.count, 2)
        XCTAssertEqual(layout.regions[1].columns.count, 2)
    }

    func testInterruptedColumnsCreateIndependentVerticalColumnRegions() {
        let layout = layoutForFixture(named: "columns-interrupted-by-caption")

        XCTAssertEqual(layout.regions.map(\.kind), [.columnar, .spanning, .columnar])
        guard layout.regions.count == 3 else { return }
        XCTAssertEqual(layout.regions[0].columns.count, 2)
        XCTAssertEqual(layout.regions[2].columns.count, 2)
        XCTAssertEqual(layout.spanningBlockIDs.count, 1)
    }

    func testMultipleSpanningTransitionsStayDeterministic() {
        let first = layoutForFixture(named: "multiple-spanning-headings")
        let second = layoutForFixture(named: "multiple-spanning-headings")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.regions.map(\.kind), [.columnar, .spanning, .columnar, .spanning])
        XCTAssertEqual(first.spanningBlockIDs.count, 2)
    }

    func testSidebarsAreNotPrimaryColumns() {
        for name in [
            "right-sidebar",
            "left-sidebar",
            "pull-quote-inside-body",
            "marginal-note",
            "multiple-small-sidebars"
        ] {
            let pipeline = pipelineForFixture(named: name)
            let layout = PdfLayoutRegionDetector.segment(blocks: pipeline.blocks)

            XCTAssertEqual(layout.primaryColumnCount, 1, name)
            XCTAssertFalse(layout.sidebarBlockIDs.isEmpty, name)
            XCTAssertTrue(layout.regions.allSatisfy { $0.columns.count <= 1 }, name)
        }
    }

    func testTrueAsymmetricSecondColumnIsNotMistakenForSidebar() {
        for name in ["two-column-60-40", "two-column-40-60", "short-column-beside-long-column"] {
            let layout = layoutForFixture(named: name)
            XCTAssertEqual(layout.primaryColumnCount, 2, name)
            XCTAssertTrue(layout.sidebarBlockIDs.isEmpty, name)
        }
    }

    func testCenteredPullQuoteBetweenBodyRegionsDoesNotInventSecondColumn() {
        let layout = layoutForFixture(named: "narrow-callout-between-body-regions")

        XCTAssertEqual(layout.primaryColumnCount, 1)
        XCTAssertTrue(layout.regions.allSatisfy { $0.columns.count <= 1 })
    }

    func testOrdinaryParagraphIndentationDoesNotBecomeColumnGutter() {
        for name in [
            "first-line-indentation",
            "hanging-indentation",
            "single-column-narrow-margins",
            "short-chapter-heading-body"
        ] {
            let layout = layoutForFixture(named: name)
            XCTAssertEqual(layout.primaryColumnCount, 1, name)
            XCTAssertTrue(layout.regions.allSatisfy { $0.kind != .columnar }, name)
        }
    }

    func testSmallCoordinatePerturbationKeepsRegionAndColumnAssignmentsStable() {
        let pipeline = pipelineForFixture(named: "single-two-single")
        let baseline = PdfLayoutRegionDetector.segment(blocks: pipeline.blocks)
        let perturbedBlocks = pipeline.blocks.map { block in
            let dx: CGFloat = block.id.isMultiple(of: 2) ? 0.0020 : -0.0015
            let dy: CGFloat = block.id.isMultiple(of: 3) ? 0.0018 : -0.0012
            return PdfLayoutBlock(
                id: block.id,
                lines: block.lines,
                text: block.text,
                rect: block.rect.offsetBy(dx: dx, dy: dy),
                sourceOrder: block.sourceOrder
            )
        }
        let perturbed = PdfLayoutRegionDetector.segment(blocks: perturbedBlocks)

        XCTAssertEqual(perturbed.regions.map(\.kind), baseline.regions.map(\.kind))
        XCTAssertEqual(perturbed.primaryColumnCount, baseline.primaryColumnCount)
        XCTAssertEqual(perturbed.spanningBlockIDs, baseline.spanningBlockIDs)
        XCTAssertEqual(perturbed.sidebarBlockIDs, baseline.sidebarBlockIDs)
        XCTAssertEqual(
            perturbed.regions.map { $0.columns.map(\.blockIDs) },
            baseline.regions.map { $0.columns.map(\.blockIDs) }
        )
    }

    func testSupportedColumnAndMixedFixturesAreDeterministic() {
        let fixtures = TestLayoutFixtureCatalog.all.filter {
            $0.support == .supported && ($0.category == "columns" || $0.category == "mixed-regions")
        }
        XCTAssertFalse(fixtures.isEmpty)

        for fixture in fixtures {
            let first = pipeline(for: fixture)
            let firstLayout = PdfLayoutRegionDetector.segment(blocks: first.blocks)
            let second = pipeline(for: fixture)
            let secondLayout = PdfLayoutRegionDetector.segment(blocks: second.blocks)

            XCTAssertEqual(firstLayout, secondLayout, fixture.name)
            let inputIDs = Set(first.blocks.map(\.id))
            let assignedIDs = Set(firstLayout.regions.flatMap { region in
                region.primaryBlockIDs + region.sidebarBlockIDs + region.spanningBlockIDs
            })
            XCTAssertEqual(assignedIDs, inputIDs, fixture.name)
        }
    }

    func testRealPDFKitTwoColumnFixtureProducesTwoColumnRegion() throws {
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

        XCTAssertEqual(layout.primaryColumnCount, 2)
        XCTAssertEqual(layout.regions.count, 1)
        XCTAssertEqual(layout.regions.first?.kind, .columnar)
        XCTAssertEqual(layout.regions.first?.columns.count, 2)
    }

    private struct PipelineResult {
        let fragments: [PdfLayoutFragment]
        let lines: [PdfLayoutLine]
        let blocks: [PdfLayoutBlock]
    }

    private func layoutForFixture(named name: String) -> PdfPageRegionLayout {
        let result = pipelineForFixture(named: name)
        return PdfLayoutRegionDetector.segment(blocks: result.blocks)
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

        // Match the geometry shape produced by PDFKit line selections: the
        // rectangle wraps rendered glyphs, not the full fixture text box. Using
        // declared box width here would artificially erase narrow gutters before
        // Phase 4 receives the Phase 3 blocks.
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

    private func fragment(
        _ text: String,
        id: Int,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat = 0.035
    ) -> PdfLayoutFragment {
        PdfLayoutFragment(
            id: id,
            text: text,
            rect: CGRect(x: x, y: y, width: width, height: height),
            source: .native,
            confidence: 1,
            sourceOrder: id,
            style: PdfLayoutStyleHints(fontSize: 12, isBold: false, isItalic: false)
        )
    }

    private func assertRegionKinds(
        fixture: String,
        expected: [PdfLayoutRegionKind],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let layout = layoutForFixture(named: fixture)
        XCTAssertEqual(layout.regions.map(\.kind), expected, fixture, file: file, line: line)
        XCTAssertEqual(layout.primaryColumnCount, 2, fixture, file: file, line: line)
    }
}
