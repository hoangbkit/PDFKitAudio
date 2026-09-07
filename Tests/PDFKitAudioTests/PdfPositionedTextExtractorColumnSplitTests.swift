import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfPositionedTextExtractorColumnSplitTests: XCTestCase {
    func testMergedSameBaselineColumnsSplitIntoSeparateNativeFragments() throws {
        guard let fixture = TestLayoutFixtureCatalog.byName["columns-interrupted-by-caption"] else {
            return XCTFail("Missing fixture")
        }
        let data = try TestPDFBuilder.layoutPDF(fixture)
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else {
            return XCTFail("Could not open fixture")
        }

        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)

        XCTAssertTrue(fragments.contains { $0.text.contains("L1") && !$0.text.contains("R1") })
        XCTAssertTrue(fragments.contains { $0.text.contains("R1") && !$0.text.contains("L1") })
        XCTAssertTrue(fragments.contains { $0.text.contains("L2") && !$0.text.contains("R2") })
        XCTAssertTrue(fragments.contains { $0.text.contains("R2") && !$0.text.contains("L2") })
        XCTAssertTrue(fragments.contains { $0.text.contains("FIGURE_CAPTION") })
    }

    func testWideSingleColumnLinesAreNotOverSplit() throws {
        guard let fixture = TestLayoutFixtureCatalog.byName["single-column-narrow-margins"] else {
            return XCTFail("Missing fixture")
        }
        let data = try TestPDFBuilder.layoutPDF(fixture)
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else {
            return XCTFail("Could not open fixture")
        }

        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)

        XCTAssertEqual(fragments.count, 4)
        XCTAssertEqual(fragments.filter { $0.text.contains("P1") }.count, 1)
        XCTAssertEqual(fragments.filter { $0.text.contains("P2") }.count, 1)
        XCTAssertEqual(fragments.filter { $0.text.contains("P3") }.count, 1)
        XCTAssertEqual(fragments.filter { $0.text.contains("P4") }.count, 1)
    }
}
