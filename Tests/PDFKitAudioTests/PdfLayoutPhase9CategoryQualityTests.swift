import Foundation
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

    func testSelectedFixtureFromEnvironment() throws {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["PDFKITAUDIO_PHASE9_FIXTURE"])
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName[name], name)
        try assertExact(fixture: fixture)
    }

    func testPhase9RootCauseDiagnostics() throws {
        let names = [
            "short-chapter-heading-body",
            "full-width-title-body",
            "three-column",
            "semantic-sentence-near-top"
        ]

        for name in names {
            let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName[name], name)
            let document = try XCTUnwrap(PDFDocument(data: TestPDFBuilder.layoutPDF(fixture)), name)
            print("PHASE9_DIAG fixture=\(name) pages=\(document.pageCount)")

            for pageIndex in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: pageIndex), "\(name) page \(pageIndex)")
                let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
                let assessment = PdfLayoutComplexityDetector.assess(
                    fragments: fragments,
                    nativeText: page.string ?? ""
                )
                let repair = PdfLayoutAnalyzer.shouldRepairSimpleOrder(
                    fragments: fragments,
                    assessment: assessment
                )
                print("PHASE9_DIAG page=\(pageIndex) complexity=\(assessment.complexity.rawValue) confidence=\(assessment.confidence) shouldAnalyze=\(assessment.shouldAnalyze) repair=\(repair) reasons=\(assessment.reasons)")
                print("PHASE9_DIAG raw=\((page.string ?? "").replacingOccurrences(of: "\n", with: " | "))")
                for fragment in fragments.sorted(by: { $0.sourceOrder < $1.sourceOrder }) {
                    print("PHASE9_DIAG fragment id=\(fragment.id) order=\(fragment.sourceOrder) y=\(fragment.rect.minY) x=\(fragment.rect.minX) w=\(fragment.rect.width) h=\(fragment.rect.height) text=\(fragment.text.replacingOccurrences(of: "\n", with: " "))")
                }

                let lines = PdfLayoutLineBuilder.build(fragments: fragments)
                let blocks = PdfLayoutBlockBuilder.build(lines: lines)
                let layout = PdfLayoutRegionDetector.segment(blocks: blocks)
                let special = PdfLayoutRoleClassifier.analyze(blocks: blocks, layout: layout)
                let order = PdfReadingOrderResolver.resolve(
                    blocks: blocks,
                    layout: layout,
                    hints: special.readingOrderHints
                )
                print("PHASE9_DIAG layout columns=\(layout.primaryColumnCount) sidebars=\(layout.sidebarBlockIDs) spanning=\(layout.spanningBlockIDs)")
                for region in layout.regions {
                    print("PHASE9_DIAG region id=\(region.id) kind=\(region.kind.rawValue) columns=\(region.columns.map { $0.blockIDs }) primary=\(region.primaryBlockIDs) spanning=\(region.spanningBlockIDs)")
                }
                for block in blocks {
                    let role = special.assignments.first(where: { $0.blockID == block.id })
                    print("PHASE9_DIAG block id=\(block.id) order=\(block.sourceOrder) y=\(block.rect.minY) x=\(block.rect.minX) w=\(block.rect.width) role=\(role?.role.rawValue ?? "none") roleConfidence=\(role?.confidence ?? 0) text=\(block.text.replacingOccurrences(of: "\n", with: " | "))")
                }
                print("PHASE9_DIAG tables=\(special.tables.map { $0.blockIDs }) order=\(order.orderedBlockIDs) orderConfidence=\(order.confidence) fallback=\(order.usedFallback) diagnostics=\(order.diagnostics)")

                if let analyzed = try PdfLayoutAnalyzer.analyze(
                    fragments: fragments,
                    nativeText: page.string ?? "",
                    nativeTextThreshold: 20,
                    pageIndex: pageIndex,
                    mode: .always
                ) {
                    print("PHASE9_DIAG analyzed=\(analyzed.text.replacingOccurrences(of: "\n", with: " | ")) assessment=\(analyzed.assessment.complexity.rawValue)")
                } else {
                    print("PHASE9_DIAG analyzed=nil")
                }
            }
        }
    }

    private func assertExact(category: String) throws {
        let fixtures = TestLayoutFixtureCatalog.all.filter {
            $0.support == .supported
                && $0.category == category
                && $0.pages.allSatisfy { $0.rendering == .native }
        }
        if fixtures.isEmpty { return }
        for fixture in fixtures {
            try assertExact(fixture: fixture)
        }
    }

    private func assertExact(fixture: TestLayoutFixture) throws {
        guard fixture.support == .supported,
              fixture.pages.allSatisfy({ $0.rendering == .native }) else {
            return
        }
        let parser = PdfParser(configuration: PdfParserConfiguration(
            ocr: PdfOCRConfiguration(mode: .never),
            layout: PdfLayoutConfiguration(mode: .auto),
            cleanup: .minimal,
            extractCoverImage: false
        ))
        let book = try parser.parse(data: TestPDFBuilder.layoutPDF(fixture))
        let combined = book.pages.map(\.text).joined(separator: "\n\n")
        let expected = qualityMarkers(for: fixture)
        let actual = TestLayoutBaselineScorer.orderedMarkers(expectedMarkers: expected, in: combined)
        let score = TestLayoutBaselineScorer.score(expectedMarkers: expected, in: combined)
        let detail = "\(fixture.name) expected=\(expected) actual=\(actual) text=\(combined)"
        XCTAssertEqual(score.coverage, 1, "Missing semantic marker: \(detail)")
        XCTAssertEqual(score.pairwiseAccuracy, 1, "Wrong semantic order: \(detail)")
        XCTAssertEqual(score.duplicateMarkerCount, 0, "Duplicated semantic marker: \(detail)")
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
