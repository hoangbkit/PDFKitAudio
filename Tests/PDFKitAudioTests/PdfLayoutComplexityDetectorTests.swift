import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutComplexityDetectorTests: XCTestCase {
    func testCanonicalSingleColumnFixturesStayOnFastPath() {
        for name in [
            "single-column-narrow-margins",
            "single-column-wide-margins",
            "centered-paragraphs",
            "justified-looking-paragraphs",
            "first-line-indentation",
            "hanging-indentation",
            "short-chapter-heading-body",
            "full-width-title-body",
            "large-whitespace-between-paragraphs",
            "blank-page",
            "page-number-only"
        ] {
            let assessment = assessFixture(named: name)
            XCTAssertFalse(assessment.shouldAnalyze, name)
            XCTAssertEqual(assessment.complexity, .simpleSingleColumn, name)
            XCTAssertGreaterThanOrEqual(assessment.confidence, 0.80, name)
        }
    }

    func testCanonicalColumnsAreDetectedWithHighConfidence() {
        for name in [
            "two-column-symmetric",
            "two-column-60-40",
            "two-column-40-60",
            "two-column-narrow-gutter",
            "two-column-wide-gutter",
            "three-column",
            "columns-unequal-final-heights",
            "left-column-ending-early",
            "right-column-begins-lower",
            "short-column-beside-long-column",
            "columns-with-indented-paragraphs"
        ] {
            let assessment = assessFixture(named: name)
            XCTAssertTrue(assessment.shouldAnalyze, name)
            XCTAssertEqual(assessment.complexity, .likelyMultiColumn, name)
            XCTAssertGreaterThanOrEqual(assessment.confidence, 0.68, name)
            XCTAssertGreaterThanOrEqual(assessment.features.dominantLaneCount, 2, name)
        }
    }

    func testMixedVerticalRegionsAreDetected() {
        for name in [
            "full-width-title-two-columns",
            "full-width-abstract-two-columns",
            "two-columns-full-width-conclusion",
            "title-columns-footer-note",
            "single-two-single",
            "columns-interrupted-by-caption",
            "multiple-spanning-headings",
            "abstract-columns-summary"
        ] {
            let assessment = assessFixture(named: name)
            XCTAssertTrue(assessment.shouldAnalyze, name)
            XCTAssertEqual(assessment.complexity, .mixedRegions, name)
            XCTAssertTrue(assessment.features.mixedVerticalRegionsDetected, name)
        }
    }

    func testTablesAreSeparatedFromOrdinaryColumns() {
        for name in [
            "table-2x3-bordered",
            "table-borderless",
            "table-header-row",
            "table-numeric",
            "table-uneven-column-widths",
            "table-full-page-width",
            "table-inside-single-column",
            "table-between-text-regions",
            "table-multiline-cells"
        ] {
            let assessment = assessFixture(named: name)
            XCTAssertTrue(assessment.shouldAnalyze, name)
            XCTAssertEqual(assessment.complexity, .likelyTableHeavy, name)
            XCTAssertGreaterThanOrEqual(assessment.features.sideBySideRowCount, 2, name)
        }
    }

    func testSideContentAndFloatingRegionsAreConservativelyFlagged() {
        for name in [
            "right-sidebar",
            "left-sidebar",
            "pull-quote-inside-body",
            "narrow-callout-between-body-regions",
            "marginal-note",
            "multiple-small-sidebars",
            "floating-text-box-over-body",
            "text-box-near-center-gutter",
            "tiny-superscript-near-line"
        ] {
            let assessment = assessFixture(named: name)
            XCTAssertTrue(assessment.shouldAnalyze, name)
            XCTAssertEqual(assessment.complexity, .irregularPositioned, name)
        }
    }

    func testFullFixtureMatrixHasExplicitFastPathExpectation() {
        var checkedPages = 0

        for fixture in TestLayoutFixtureCatalog.all {
            for (pageIndex, page) in fixture.pages.enumerated() {
                let fragments = syntheticFragments(for: page)
                let assessment = PdfLayoutComplexityDetector.assess(
                    fragments: fragments,
                    nativeText: fragments.map(\.text).joined(separator: "\n")
                )
                let expected = expectsAnalysis(
                    fixture: fixture,
                    pageIndex: pageIndex
                )
                XCTAssertEqual(
                    assessment.shouldAnalyze,
                    expected,
                    "\(fixture.name) page \(pageIndex): \(assessment.complexity.rawValue), reasons=\(assessment.reasons)"
                )
                checkedPages += 1
            }
        }

        XCTAssertGreaterThanOrEqual(checkedPages, 75)
    }

    func testRealPDFKitFragmentsDetectTwoColumnsWithoutChangingParserText() throws {
        guard let fixture = TestLayoutFixtureCatalog.byName["two-column-symmetric"] else {
            return XCTFail("Missing fixture")
        }
        let data = try TestPDFBuilder.layoutPDF(fixture)
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            return XCTFail("Could not build two-column fixture")
        }

        let nativeTextBefore = page.string ?? ""
        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
        let assessment = PdfLayoutComplexityDetector.assess(
            fragments: fragments,
            nativeText: nativeTextBefore
        )

        XCTAssertTrue(assessment.shouldAnalyze)
        XCTAssertEqual(assessment.complexity, .likelyMultiColumn)
        XCTAssertEqual(page.string ?? "", nativeTextBefore)
    }

    func testRealPDFKitFragmentsKeepSimplePageOnFastPath() throws {
        guard let fixture = TestLayoutFixtureCatalog.byName["single-column-narrow-margins"] else {
            return XCTFail("Missing fixture")
        }
        let data = try TestPDFBuilder.layoutPDF(fixture)
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            return XCTFail("Could not build simple fixture")
        }

        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
        let assessment = PdfLayoutComplexityDetector.assess(
            fragments: fragments,
            nativeText: page.string
        )

        XCTAssertFalse(assessment.shouldAnalyze)
        XCTAssertEqual(assessment.complexity, .simpleSingleColumn)
    }

    func testCenteredPoemDoesNotBecomeColumns() {
        let fragments = [
            fragment("A quiet line", x: 0.31, y: 0.10, width: 0.38),
            fragment("A shorter line", x: 0.35, y: 0.20, width: 0.30, order: 1),
            fragment("A wider final thought", x: 0.27, y: 0.30, width: 0.46, order: 2),
            fragment("And silence", x: 0.39, y: 0.40, width: 0.22, order: 3)
        ]

        assertFastPath(fragments, context: "centered poem")
    }

    func testDialogueWithAlternatingIndentsDoesNotBecomeColumns() {
        let fragments = [
            fragment("Alice: Hello.", x: 0.12, y: 0.10, width: 0.35),
            fragment("Bob: Hi.", x: 0.20, y: 0.18, width: 0.25, order: 1),
            fragment("Alice: How are you?", x: 0.12, y: 0.26, width: 0.42, order: 2),
            fragment("Bob: Fine.", x: 0.20, y: 0.34, width: 0.28, order: 3)
        ]

        assertFastPath(fragments, context: "dialogue")
    }

    func testIndentedQuoteDoesNotBecomeSidebar() {
        let fragments = [
            fragment("Body paragraph one", x: 0.12, y: 0.10, width: 0.62),
            fragment("Quoted paragraph", x: 0.20, y: 0.20, width: 0.52, order: 1),
            fragment("Quoted continuation", x: 0.20, y: 0.28, width: 0.52, order: 2),
            fragment("Body paragraph two", x: 0.12, y: 0.38, width: 0.62, order: 3)
        ]

        assertFastPath(fragments, context: "indented quote")
    }

    func testNumberedListDoesNotBecomeTable() {
        var fragments: [PdfLayoutFragment] = []
        for row in 0..<4 {
            fragments.append(fragment(
                "\(row + 1).",
                x: 0.12,
                y: 0.10 + CGFloat(row) * 0.09,
                width: 0.025,
                order: row * 2
            ))
            fragments.append(fragment(
                "A normal list item with sentence-like content",
                x: 0.155,
                y: 0.10 + CGFloat(row) * 0.09,
                width: 0.60,
                order: row * 2 + 1
            ))
        }

        assertFastPath(fragments, context: "numbered list")
    }

    func testWideHeadingAndBodyRemainSimple() {
        let fragments = [
            PdfLayoutFragment(
                id: 0,
                text: "CHAPTER ONE",
                rect: CGRect(x: 0.33, y: 0.07, width: 0.34, height: 0.04),
                source: .native,
                confidence: 1,
                sourceOrder: 0,
                style: PdfLayoutStyleHints(fontSize: 20, isBold: true, isItalic: false)
            ),
            fragment("Body line one", x: 0.12, y: 0.18, width: 0.62, order: 1),
            fragment("Body line two", x: 0.12, y: 0.27, width: 0.62, order: 2),
            fragment("Body line three", x: 0.12, y: 0.36, width: 0.62, order: 3)
        ]

        assertFastPath(fragments, context: "heading plus single-column body")
    }

    func testSparseAmbiguousPairFailsSafeToCurrentPath() {
        let fragments = [
            fragment("Top left", x: 0.08, y: 0.10, width: 0.25),
            fragment("Bottom right", x: 0.62, y: 0.78, width: 0.25, order: 1)
        ]

        let assessment = PdfLayoutComplexityDetector.assess(fragments: fragments)
        XCTAssertFalse(assessment.shouldAnalyze)
        XCTAssertTrue(
            assessment.complexity == .simpleSingleColumn || assessment.complexity == .unknown
        )
    }

    func testNativeTextQualityIsRecordedButDoesNotOverrideGeometry() {
        let fragments = [
            fragment("Left one", x: 0.08, y: 0.10, width: 0.25),
            fragment("Right one", x: 0.60, y: 0.10, width: 0.25, order: 1),
            fragment("Left two", x: 0.08, y: 0.22, width: 0.25, order: 2),
            fragment("Right two", x: 0.60, y: 0.22, width: 0.25, order: 3)
        ]

        let assessment = PdfLayoutComplexityDetector.assess(
            fragments: fragments,
            nativeText: "x",
            nativeTextThreshold: 20
        )

        XCTAssertEqual(assessment.nativeTextQuality, .insufficient)
        XCTAssertTrue(assessment.shouldAnalyze)
        XCTAssertEqual(assessment.complexity, .likelyMultiColumn)
    }

    private func assessFixture(named name: String) -> PdfLayoutComplexityAssessment {
        guard let fixture = TestLayoutFixtureCatalog.byName[name],
              let page = fixture.pages.first else {
            XCTFail("Missing fixture \(name)")
            return PdfLayoutComplexityDetector.assess(fragments: [])
        }
        let fragments = syntheticFragments(for: page)
        return PdfLayoutComplexityDetector.assess(
            fragments: fragments,
            nativeText: fragments.map(\.text).joined(separator: "\n")
        )
    }

    private func syntheticFragments(for page: TestLayoutPage) -> [PdfLayoutFragment] {
        let raw = page.boxes.enumerated().map { index, box -> PdfLayoutFragment in
            let estimatedGlyphWidth = min(
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
                x = box.rect.midX - estimatedGlyphWidth / 2
            case .right:
                x = box.rect.maxX - estimatedGlyphWidth
            default:
                x = box.rect.minX
            }

            return PdfLayoutFragment(
                id: index,
                text: box.text,
                rect: CGRect(
                    x: max(0, min(1 - estimatedGlyphWidth, x)),
                    y: box.rect.minY,
                    width: estimatedGlyphWidth,
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
        return PdfPositionedTextExtractor.deduplicated(raw)
    }

    private func expectsAnalysis(
        fixture: TestLayoutFixture,
        pageIndex: Int
    ) -> Bool {
        switch fixture.category {
        case "columns", "mixed-regions", "side-content", "tables":
            return true

        case "footnotes-captions":
            return fixture.name == "caption-between-columns"

        case "difficult-positioning":
            return [
                "floating-text-box-over-body",
                "text-box-near-center-gutter",
                "tiny-superscript-near-line"
            ].contains(fixture.name)

        case "ocr-equivalents":
            return fixture.name == "scanned-two-column"

        case "simple", "running-matter", "scripts-languages":
            return false

        default:
            XCTFail("Unhandled fixture category \(fixture.category), page \(pageIndex)")
            return false
        }
    }

    private func fragment(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat = 0.035,
        order: Int = 0
    ) -> PdfLayoutFragment {
        PdfLayoutFragment(
            id: order,
            text: text,
            rect: CGRect(x: x, y: y, width: width, height: height),
            source: .native,
            confidence: 1,
            sourceOrder: order
        )
    }

    private func assertFastPath(
        _ fragments: [PdfLayoutFragment],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let assessment = PdfLayoutComplexityDetector.assess(fragments: fragments)
        XCTAssertFalse(
            assessment.shouldAnalyze,
            "\(context): \(assessment.complexity.rawValue), \(assessment.reasons)",
            file: file,
            line: line
        )
        XCTAssertNotEqual(assessment.complexity, .likelyTableHeavy, file: file, line: line)
        XCTAssertNotEqual(assessment.complexity, .likelyMultiColumn, file: file, line: line)
    }
}
