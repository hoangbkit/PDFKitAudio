import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutRegionDetectorIntegrationTests: XCTestCase {
    func testRealPDFKitInterruptedColumnsCreateSpanningRegion() throws {
        let layout = try realLayout(for: "columns-interrupted-by-caption")

        XCTAssertEqual(layout.regions.map(\.kind), [.columnar, .spanning, .columnar])
        XCTAssertEqual(layout.primaryColumnCount, 2)
        XCTAssertEqual(layout.spanningBlockIDs.count, 1)
        XCTAssertEqual(layout.regions.first?.columns.count, 2)
        XCTAssertEqual(layout.regions.last?.columns.count, 2)
    }

    func testRealPDFKitSidebarIsNotPrimaryColumn() throws {
        let layout = try realLayout(for: "right-sidebar")

        XCTAssertEqual(layout.primaryColumnCount, 1)
        XCTAssertFalse(layout.sidebarBlockIDs.isEmpty)
        XCTAssertTrue(layout.regions.allSatisfy { $0.columns.count <= 1 })
    }

    private func realLayout(for fixtureName: String) throws -> PdfPageRegionLayout {
        guard let fixture = TestLayoutFixtureCatalog.byName[fixtureName] else {
            throw IntegrationError.missingFixture(fixtureName)
        }
        let data = try TestPDFBuilder.layoutPDF(fixture)
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            throw IntegrationError.couldNotOpenPDF
        }

        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
        let lines = PdfLayoutLineBuilder.build(fragments: fragments)
        let blocks = PdfLayoutBlockBuilder.build(lines: lines)
        return PdfLayoutRegionDetector.segment(blocks: blocks)
    }

    private enum IntegrationError: Error {
        case missingFixture(String)
        case couldNotOpenPDF
    }
}
