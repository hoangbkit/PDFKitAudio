import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutRegionDetectorIntegrationTests: XCTestCase {
    func testRealPDFKitInterruptedColumnsCreateSpanningRegion() throws {
        let pipeline = try realPipeline(for: "columns-interrupted-by-caption")
        print("PHASE4_REAL_INTERRUPTED fragments=\(pipeline.fragments.map { debugFragment($0) })")
        print("PHASE4_REAL_INTERRUPTED lines=\(pipeline.lines.map { debugLine($0) })")
        print("PHASE4_REAL_INTERRUPTED blocks=\(pipeline.blocks.map { debugBlock($0) })")
        print("PHASE4_REAL_INTERRUPTED regions=\(pipeline.layout.regions.map { debugRegion($0) })")

        XCTAssertEqual(pipeline.layout.regions.map(\.kind), [.columnar, .spanning, .columnar])
        XCTAssertEqual(pipeline.layout.primaryColumnCount, 2)
        XCTAssertEqual(pipeline.layout.spanningBlockIDs.count, 1)
        XCTAssertEqual(pipeline.layout.regions.first?.columns.count, 2)
        XCTAssertEqual(pipeline.layout.regions.last?.columns.count, 2)
    }

    func testRealPDFKitSidebarIsNotPrimaryColumn() throws {
        let layout = try realPipeline(for: "right-sidebar").layout

        XCTAssertEqual(layout.primaryColumnCount, 1)
        XCTAssertFalse(layout.sidebarBlockIDs.isEmpty)
        XCTAssertTrue(layout.regions.allSatisfy { $0.columns.count <= 1 })
    }

    private struct Pipeline {
        let fragments: [PdfLayoutFragment]
        let lines: [PdfLayoutLine]
        let blocks: [PdfLayoutBlock]
        let layout: PdfPageRegionLayout
    }

    private func realPipeline(for fixtureName: String) throws -> Pipeline {
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
        let layout = PdfLayoutRegionDetector.segment(blocks: blocks)
        return Pipeline(fragments: fragments, lines: lines, blocks: blocks, layout: layout)
    }

    private func debugFragment(_ fragment: PdfLayoutFragment) -> String {
        "#\(fragment.id):\(fragment.text.replacingOccurrences(of: "\n", with: "↵"))@\(debugRect(fragment.rect))"
    }

    private func debugLine(_ line: PdfLayoutLine) -> String {
        "#\(line.id):\(line.text.replacingOccurrences(of: "\n", with: "↵"))@\(debugRect(line.rect)) fragments=\(line.fragments.map(\.id))"
    }

    private func debugBlock(_ block: PdfLayoutBlock) -> String {
        "#\(block.id):\(block.text.replacingOccurrences(of: "\n", with: "↵"))@\(debugRect(block.rect)) lines=\(block.lines.map(\.id))"
    }

    private func debugRegion(_ region: PdfLayoutRegion) -> String {
        "#\(region.id):\(region.kind.rawValue)@\(debugRect(region.rect)) columns=\(region.columns.map { $0.blockIDs }) primary=\(region.primaryBlockIDs) sidebar=\(region.sidebarBlockIDs) span=\(region.spanningBlockIDs)"
    }

    private func debugRect(_ rect: CGRect) -> String {
        String(format: "(%.4f,%.4f,%.4f,%.4f)", rect.minX, rect.minY, rect.width, rect.height)
    }

    private enum IntegrationError: Error {
        case missingFixture(String)
        case couldNotOpenPDF
    }
}
