import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutReconstructionIntegrationTests: XCTestCase {
    func testRealPDFKitTwoColumnFragmentsNeverCrossStrongGutter() throws {
        guard let fixture = TestLayoutFixtureCatalog.byName["two-column-wide-gutter"] else {
            return XCTFail("Missing two-column fixture")
        }
        let data = try TestPDFBuilder.layoutPDF(fixture)
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            return XCTFail("Could not build two-column fixture")
        }

        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
        let lines = PdfLayoutLineBuilder.build(fragments: fragments)
        let blocks = PdfLayoutBlockBuilder.build(lines: lines)

        XCTAssertFalse(fragments.isEmpty)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertFalse(blocks.isEmpty)

        let leftMarkers = ["L1", "L2", "L3"]
        let rightMarkers = ["R1", "R2", "R3"]
        for block in blocks {
            let hasLeft = leftMarkers.contains { block.text.contains($0) }
            let hasRight = rightMarkers.contains { block.text.contains($0) }
            XCTAssertFalse(
                hasLeft && hasRight,
                "Block crossed the fixture's strong column gutter: \(block.text)"
            )
        }

        let inputIDs = fragments.map(\.id).sorted()
        let blockIDs = blocks.flatMap { block in
            block.lines.flatMap { $0.fragments.map(\.id) }
        }.sorted()
        XCTAssertEqual(blockIDs, inputIDs)
    }
}
