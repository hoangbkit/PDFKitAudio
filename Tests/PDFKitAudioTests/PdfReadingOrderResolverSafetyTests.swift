import Foundation
import XCTest
@testable import PDFKitAudio

final class PdfReadingOrderResolverSafetyTests: XCTestCase {
    func testDuplicateBlockIDsFailSafeWithoutCrashing() {
        let first = block(id: 7, text: "FIRST", y: 0.10)
        let second = block(id: 7, text: "SECOND", y: 0.30)
        let layout = PdfPageRegionLayout(
            regions: [PdfLayoutRegion(
                id: 0,
                rect: first.rect.union(second.rect),
                kind: .singleColumn,
                columns: [PdfLayoutColumn(
                    id: 0,
                    rect: first.rect.union(second.rect),
                    blockIDs: [7],
                    confidence: 0.90
                )],
                primaryBlockIDs: [7],
                sidebarBlockIDs: [],
                spanningBlockIDs: [],
                confidence: 0.90
            )],
            primaryColumnCount: 1,
            sidebarBlockIDs: [],
            spanningBlockIDs: []
        )

        let result = PdfReadingOrderResolver.resolve(blocks: [first, second], layout: layout)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.orderedBlockIDs, [7, 7])
        XCTAssertTrue(result.diagnostics.contains { $0.contains("Duplicate block identifier 7") })
    }

    private func block(id: Int, text: String, y: CGFloat) -> PdfLayoutBlock {
        let fragment = PdfLayoutFragment(
            id: id,
            text: text,
            rect: CGRect(x: 0.12, y: y, width: 0.45, height: 0.05),
            source: .native,
            confidence: 1,
            sourceOrder: id
        )
        let line = PdfLayoutLine(
            id: id,
            fragments: [fragment],
            text: text,
            rect: fragment.rect,
            writingDirection: .leftToRight,
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
}
