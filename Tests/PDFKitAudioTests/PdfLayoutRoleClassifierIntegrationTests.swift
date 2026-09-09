import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutRoleClassifierIntegrationTests: XCTestCase {
    func testRealPDFKitTableSurvivesExtractionAndSpecialStructureAnalysis() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["table-header-row"])
        let result = try analyzeNativeFixture(fixture)
        let table = try XCTUnwrap(result.analysis.tables.first)

        XCTAssertGreaterThanOrEqual(table.cellsByRow.count, 2)
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertGreaterThanOrEqual(table.confidence, 0.72)

        for marker in fixture.expectedMarkerOrder {
            XCTAssertTrue(
                table.linearizedText.contains(marker),
                "Missing \(marker) after real PDFKit extraction"
            )
        }
        XCTAssertTrue(table.blockIDs.isSubset(of: Set(result.blocks.map(\.id))))
    }

    func testRealPDFKitCaptionProducesPreservedRoleAndAnchorHint() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["image-caption-below-body"])
        let result = try analyzeNativeFixture(fixture)
        let captionID = try XCTUnwrap(result.blocks.first(where: { $0.text.contains("CAPTION") })?.id)

        XCTAssertEqual(result.analysis.role(for: captionID), .caption)
        XCTAssertTrue(result.analysis.readingOrderHints.captionAttachments.contains { $0.blockID == captionID })

        let ordered = PdfReadingOrderResolver.resolve(
            blocks: result.blocks,
            layout: result.layout,
            hints: result.analysis.readingOrderHints
        )
        XCTAssertEqual(ordered.orderedBlockIDs.count, result.blocks.count)
        XCTAssertEqual(Set(ordered.orderedBlockIDs), Set(result.blocks.map(\.id)))
    }

    func testRealPDFKitFootnoteStrongEvidenceSurvivesExtraction() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["one-footnote"])
        let result = try analyzeNativeFixture(fixture)
        let footnoteID = try XCTUnwrap(result.blocks.first(where: { $0.text.contains("FOOTNOTE_1") })?.id)

        XCTAssertEqual(result.analysis.role(for: footnoteID), .footnote)
        XCTAssertTrue(result.analysis.readingOrderHints.footnoteBlockIDs.contains(footnoteID))
        XCTAssertEqual(Set(result.analysis.assignments.map(\.blockID)), Set(result.blocks.map(\.id)))
    }

    private struct Result {
        let blocks: [PdfLayoutBlock]
        let layout: PdfPageRegionLayout
        let analysis: PdfSpecialStructureAnalysis
    }

    private func analyzeNativeFixture(_ fixture: TestLayoutFixture) throws -> Result {
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
        let lines = PdfLayoutLineBuilder.build(fragments: fragments)
        let blocks = PdfLayoutBlockBuilder.build(lines: lines)
        let layout = PdfLayoutRegionDetector.segment(blocks: blocks)
        let analysis = PdfLayoutRoleClassifier.analyze(blocks: blocks, layout: layout)
        if ProcessInfo.processInfo.environment["PDFKITAUDIO_LAYOUT_DIAGNOSTICS"] == "1" {
            print("FIXTURE \(fixture.name)")
            for fragment in fragments { print("CELL \(fragment.text) \(fragment.rect)") }
        }

        XCTAssertFalse(fragments.isEmpty)
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertEqual(Set(analysis.assignments.map(\.blockID)), Set(blocks.map(\.id)))
        return Result(blocks: blocks, layout: layout, analysis: analysis)
    }
}
