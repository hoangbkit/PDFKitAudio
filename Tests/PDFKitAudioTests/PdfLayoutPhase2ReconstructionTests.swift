import Foundation
import XCTest
@testable import PDFKitAudio

final class PdfLayoutPhase2ReconstructionTests: XCTestCase {
    func testSpanningHeadingBreaksParagraphContinuityInBothLanes() {
        let lines = [line(0, "Left before.", x: 0.08, y: 0.10, width: 0.40),
                     line(1, "Right before.", x: 0.50, y: 0.10, width: 0.40),
                     line(2, "Spanning heading", x: 0.08, y: 0.12, width: 0.82, bold: true),
                     line(3, "Left after.", x: 0.08, y: 0.135, width: 0.40),
                     line(4, "Right after.", x: 0.50, y: 0.135, width: 0.40)]
        let blocks = PdfLayoutBlockBuilder.build(lines: lines)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertTrue(blocks.allSatisfy { $0.lines.count == 1 })
    }

    func testChangingColumnWidthsUseIndependentGuttersBetweenSpans() throws {
        let lines = [line(0, "Title", x: 0.20, y: 0.05, width: 0.60, bold: true),
                     line(1, "Upper left one.", x: 0.08, y: 0.12, width: 0.32),
                     line(2, "Upper right one.", x: 0.47, y: 0.12, width: 0.43),
                     line(3, "Upper left two.", x: 0.08, y: 0.17, width: 0.32),
                     line(4, "Upper right two.", x: 0.47, y: 0.17, width: 0.43),
                     line(5, "Next section", x: 0.08, y: 0.27, width: 0.82, bold: true),
                     line(6, "Lower left one.", x: 0.08, y: 0.37, width: 0.47),
                     line(7, "Lower right one.", x: 0.62, y: 0.37, width: 0.28),
                     line(8, "Lower left two.", x: 0.08, y: 0.42, width: 0.47),
                     line(9, "Lower right two.", x: 0.62, y: 0.42, width: 0.28)]
        let result = try XCTUnwrap(PdfMixedRegionLayout.resolve(lines: lines))
        XCTAssertEqual(result.blocks.flatMap { $0.lines.map(\.id) }, [0, 1, 3, 2, 4, 5, 6, 8, 7, 9])
        XCTAssertEqual(result.layout.regions.map(\.kind), [.spanning, .columnar, .spanning, .columnar])
        XCTAssertEqual(result.gutters.count, 2)
        XCTAssertLessThan(result.gutters[0].verticalRange.upperBound, result.gutters[1].verticalRange.lowerBound)
        XCTAssertLessThan(result.gutters[0].center, result.gutters[1].center)
    }

    func testIndentedWrappedParagraphAndShortLastLineStayTogether() {
        let lines = [line(0, "Indented opening", x: 0.12, y: 0.10, width: 0.34),
                     line(1, "a differently wrapped continuation", x: 0.08, y: 0.12, width: 0.38),
                     line(2, "short ending.", x: 0.08, y: 0.14, width: 0.08),
                     line(3, "A new paragraph.", x: 0.08, y: 0.23, width: 0.38)]
        XCTAssertEqual(PdfLayoutBlockBuilder.build(lines: lines).map { $0.lines.map(\.id) }, [[0, 1, 2], [3]])
    }

    func testStaggeredBaselinesKeepColumnOrderAfterASpanningHeading() throws {
        let lines = [line(0, "Upper left one.", x: 0.08, y: 0.10, width: 0.32),
                     line(1, "Upper right one.", x: 0.50, y: 0.10, width: 0.40),
                     line(2, "Upper left two.", x: 0.08, y: 0.15, width: 0.32),
                     line(3, "Upper right two.", x: 0.50, y: 0.15, width: 0.40),
                     line(4, "Section heading", x: 0.08, y: 0.25, width: 0.82, bold: true),
                     line(5, "Lower left one.", x: 0.08, y: 0.35, width: 0.32),
                     line(6, "Lower right one.", x: 0.50, y: 0.375, width: 0.40),
                     line(7, "Lower left two.", x: 0.08, y: 0.40, width: 0.32),
                     line(8, "Lower right two.", x: 0.50, y: 0.425, width: 0.40)]
        let result = try XCTUnwrap(PdfMixedRegionLayout.resolve(lines: lines))
        XCTAssertEqual(result.blocks.flatMap { $0.lines.map(\.id) }, [0, 2, 1, 3, 4, 5, 7, 6, 8])
        XCTAssertEqual(result.layout.regions.map(\.kind), [.columnar, .spanning, .columnar])
    }

    private func line(_ id: Int, _ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
                      bold: Bool = false) -> PdfLayoutLine {
        let rect = CGRect(x: x, y: y, width: width, height: 0.01)
        let fragment = PdfLayoutFragment(id: id, text: text, rect: rect, source: .native,
            confidence: 1, sourceOrder: id, style: PdfLayoutStyleHints(fontSize: 10, isBold: bold, isItalic: false))
        return PdfLayoutLine(id: id, fragments: [fragment], text: text, rect: rect,
            writingDirection: .leftToRight, sourceOrder: id)
    }
}
