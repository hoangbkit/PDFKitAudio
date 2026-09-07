import PDFKit
import XCTest
@testable import PDFKitAudio

/// Category-level Phase 9 gates make failures attributable without weakening the
/// aggregate supported-fixture requirement.
final class PdfLayoutPhase9CategoryQualityTests: XCTestCase {
    func testSimple() throws { try assertExact(category: "simple") }
    func testColumns() throws { try assertExact(category: "columns") }
    func testMixedRegions() throws { try assertExact(category: "mixed-regions") }
    func testSideContent() throws { try assertExact(category: "side-content") }
    func testTables() throws { try assertExact(category: "tables") }
    func testFootnotesCaptions() throws { try assertExact(category: "footnotes-captions") }
    func testRunningMatter() throws { try assertExact(category: "running-matter") }
    func testDifficultPositioning() throws { try assertExact(category: "difficult-positioning") }
    func testScriptsLanguages() throws { try assertExact(category: "scripts-languages") }
    func testOCREquivalentsNativeOnly() throws { try assertExact(category: "ocr-equivalents") }

    private func assertExact(category: String) throws {
        let fixtures = TestLayoutFixtureCatalog.all.filter {
            $0.support == .supported
                && $0.category == category
                && $0.pages.allSatisfy { $0.rendering == .native }
        }
        if fixtures.isEmpty { return }

        let parser = PdfParser(configuration: PdfParserConfiguration(
            ocr: PdfOCRConfiguration(mode: .never),
            layout: PdfLayoutConfiguration(mode: .auto),
            cleanup: .minimal,
            extractCoverImage: false
        ))

        for fixture in fixtures {
            let book = try parser.parse(data: TestPDFBuilder.layoutPDF(fixture))
            let score = TestLayoutBaselineScorer.score(
                expectedMarkers: qualityMarkers(for: fixture),
                in: book.pages.map(\.text).joined(separator: "\n\n")
            )
            XCTAssertEqual(score.coverage, 1, "Missing semantic marker in \(fixture.name)")
            XCTAssertEqual(score.pairwiseAccuracy, 1, "Wrong semantic order in \(fixture.name)")
            XCTAssertEqual(score.duplicateMarkerCount, 0, "Duplicated semantic marker in \(fixture.name)")
        }
    }

    private func qualityMarkers(for fixture: TestLayoutFixture) -> [String] {
        let counts = Dictionary(grouping: fixture.expectedMarkerOrder, by: { $0 }).mapValues(\.count)
        let boxes = fixture.pages.flatMap(\.boxes)
        return fixture.expectedMarkerOrder.compactMap { marker in
            guard counts[marker] == 1 else { return nil }
            guard let box = boxes.first(where: { $0.marker == marker }) else { return marker }
            let canonicalMarker = TestLayoutBaselineScorer.canonicalMarkerText(box.marker)
            let canonicalText = TestLayoutBaselineScorer.canonicalMarkerText(box.text)
            if canonicalText.localizedCaseInsensitiveContains(canonicalMarker) {
                return box.marker
            }
            return box.text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? box.marker
        }
    }
}
