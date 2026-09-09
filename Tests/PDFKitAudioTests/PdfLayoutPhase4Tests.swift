import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutPhase4Tests: XCTestCase {
    func testHealthyRealDigitalCorpusNeverInvokesOCR() throws {
        let names = ["01-single-column", "02-two-columns", "03-three-columns", "04-spanning-headline-two-columns",
            "05-right-sidebar", "06-pull-quote", "07-table-with-prose", "08-footnotes", "09-repeated-header-footer",
            "10-mixed-column-transitions", "11-landscape-dashboard", "12-dense-academic"]
        let parser = PdfParser(ocrConfiguration: .init(mode: .auto), extractCoverImage: false,
            layoutConfiguration: .init(mode: .auto), ocrRecognizer: { _, _ in
                XCTFail("Healthy digital corpus must not invoke OCR")
                return nil
            })
        for name in names {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "PDFLayout"))
            let book = try parser.parse(at: url)
            XCTAssertEqual(book.ocrPageCount, 0, name)
            XCTAssertTrue(book.pages.allSatisfy { $0.extractionSource == .native }, name)
        }
    }

    func testAlwaysModeCannotBypassIdentitySafety() throws {
        XCTAssertEqual(PdfParserConfiguration().layout.mode, .auto)
        let fragments = ["First source paragraph.", "Second source paragraph."].enumerated().map { index, text in
            PdfLayoutFragment(id: 1, text: text, rect: CGRect(x: 0.1, y: 0.1 + CGFloat(index) * 0.2, width: 0.7, height: 0.03),
                source: .native, confidence: 1, sourceOrder: index)
        }
        for mode in [PdfLayoutMode.auto, .always] {
            var decision: PdfLayoutDiagnostics.Decision?
            let result = try PdfLayoutAnalyzer.analyze(fragments: fragments, nativeText: fragments.map(\.text).joined(),
                nativeTextThreshold: 20, pageIndex: 0, mode: mode, diagnostics: { decision = $0.decision })
            XCTAssertNil(result)
            XCTAssertEqual(decision, .fallback)
        }
    }

    func testSimpleNativeShortcutDeclinesMergedColumnsAndPreservesDiagnosticExtraction() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["single-column-narrow-margins"])
        let document = try XCTUnwrap(PDFDocument(data: TestPDFBuilder.layoutPDF(fixture)))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(PdfPositionedTextExtractor.nativeFragments(page: page, preservingSimpleOrder: true).isEmpty)
        var captured = false
        XCTAssertFalse(PdfPositionedTextExtractor.nativeFragments(page: page, preservingSimpleOrder: true,
            diagnostics: { _ in captured = true }).isEmpty)
        XCTAssertTrue(captured)
        for name in ["02-two-columns", "03-three-columns", "12-dense-academic"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "PDFLayout"))
            let document = try XCTUnwrap(PDFDocument(url: url))
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertFalse(PdfPositionedTextExtractor.nativeFragments(page: page, preservingSimpleOrder: true).isEmpty, name)
        }
    }

    func testLandscapeDashboardPreservesTextDeterministicallyInEveryMode() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "11-landscape-dashboard", withExtension: "pdf", subdirectory: "PDFLayout"))
        let data = try Data(contentsOf: url)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let native = try XCTUnwrap(document.page(at: 0)?.string)
        for mode in [PdfLayoutMode.never, .auto, .always] {
            let parser = parser(mode)
            let first = try parser.parse(data: data)
            XCTAssertEqual(inventory(first.allPlainText()), inventory(native), "\(mode)")
            XCTAssertEqual(first.pages, try parser.parse(data: data).pages)
            XCTAssertEqual(first.pages.first?.extractionSource, .native)
        }
    }

    func testRotationsCropBoxesAndMixedPageSizesConserveNativeText() throws {
        let template = try XCTUnwrap(TestLayoutFixtureCatalog.byName["two-column-symmetric"]?.pages.first)
        let pages = [0, 90, 180, 270].enumerated().map { index, rotation in
            TestLayoutPage(size: index.isMultiple(of: 2) ? CGSize(width: 612, height: 792) : CGSize(width: 792, height: 612),
                cropInsets: NSEdgeInsets(top: 12, left: 15, bottom: 18, right: 20), rotation: rotation, boxes: template.boxes)
        }
        let fixture = TestLayoutFixture(name: "phase4-transforms", category: "difficult-positioning",
            support: .degradedButReadable, pages: pages, expectedMarkerOrder: [], notes: "All orthogonal rotations and mixed sizes")
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let document = try XCTUnwrap(PDFDocument(data: data))
        for mode in [PdfLayoutMode.auto, .always, .never] {
            let book = try parser(mode).parse(data: data)
            XCTAssertEqual(book.pages.count, 4)
            for index in 0..<4 {
                let page = try XCTUnwrap(document.page(at: index))
                XCTAssertEqual(inventory(book.pages[index].text), inventory(page.string ?? ""), "\(mode) rotation \(pages[index].rotation)")
                for fragment in PdfPositionedTextExtractor.nativeFragments(page: page) {
                    XCTAssertTrue(fragment.rect.minX.isFinite && fragment.rect.minY.isFinite)
                    XCTAssertGreaterThanOrEqual(fragment.rect.minX, 0)
                    XCTAssertGreaterThanOrEqual(fragment.rect.minY, 0)
                    XCTAssertLessThanOrEqual(fragment.rect.maxX, 1.000001)
                    XCTAssertLessThanOrEqual(fragment.rect.maxY, 1.000001)
                }
            }
            XCTAssertEqual(book.pages, try parser(mode).parse(data: data).pages)
        }
    }

    func testAllDegradedNativeFixturesRemainReadableWithoutDuplicatingMarkers() throws {
        let fixtures = TestLayoutFixtureCatalog.all.filter {
            $0.support == .degradedButReadable && $0.pages.allSatisfy { $0.rendering == .native }
        }
        XCTAssertFalse(fixtures.isEmpty)
        for fixture in fixtures {
            let data = try TestPDFBuilder.layoutPDF(fixture)
            let book = try parser(.auto).parse(data: data)
            let boxes = fixture.pages.flatMap(\.boxes)
            let markers = Array(Set(fixture.expectedMarkerOrder)).sorted().map { marker in
                guard let box = boxes.first(where: { $0.marker == marker }), !box.text.contains(marker) else { return marker }
                return box.text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? marker
            }
            let score = TestLayoutBaselineScorer.score(expectedMarkers: markers, in: book.allPlainText())
            XCTAssertEqual(score.coverage, 1, fixture.name)
            // Duplicate-layer fixtures intentionally contain overprinted source
            // markers; other degraded layouts must not duplicate regions.
            if !fixture.name.contains("duplicate") {
                XCTAssertEqual(score.duplicateMarkerCount, 0, fixture.name)
            }
            XCTAssertEqual(book.pages, try parser(.auto).parse(data: data).pages, fixture.name)
        }
    }

    func testUnicodeSurvivesEveryLayoutMode() throws {
        for fixture in TestLayoutFixtureCatalog.all where fixture.category == "scripts-languages" {
            let data = try TestPDFBuilder.layoutPDF(fixture)
            let document = try XCTUnwrap(PDFDocument(data: data))
            let native = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
            for mode in [PdfLayoutMode.auto, .always, .never] {
                let book = try parser(mode).parse(data: data)
                XCTAssertEqual(inventory(book.allPlainText()), inventory(native), "\(fixture.name) \(mode)")
            }
        }
    }

    func testRealVisionSingleAndTwoColumnAndMixedDocumentsHaveExactOrder() throws {
        for name in ["scanned-single-column", "scanned-two-column", "mixed-native-scanned-pages"] {
            let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName[name])
            let data = try TestPDFBuilder.layoutPDF(fixture)
            let book = try PdfParser(configuration: .init(ocr: .init(mode: .auto, recognitionLanguages: ["en-US"]),
                cleanup: .minimal, extractCoverImage: false)).parse(data: data)
            let score = TestLayoutBaselineScorer.score(expectedMarkers: fixture.expectedMarkerOrder, in: book.allPlainText())
            XCTAssertEqual(score.coverage, 1, "\(name)\n\(book.allPlainText())")
            XCTAssertEqual(score.pairwiseAccuracy, 1, "\(name)\n\(book.allPlainText())")
            XCTAssertEqual(score.duplicateMarkerCount, 0, name)
            XCTAssertEqual(book.ocrPageCount, fixture.pages.filter { $0.rendering == .scanned }.count, name)
            for (index, page) in fixture.pages.enumerated() {
                XCTAssertEqual(book.pages[index].extractionSource, page.rendering == .native ? .native : .ocr, name)
            }
        }
    }

    private func parser(_ mode: PdfLayoutMode) -> PdfParser {
        PdfParser(configuration: .init(ocr: .init(mode: .never), layout: .init(mode: mode), cleanup: .minimal, extractCoverImage: false))
    }

    private func inventory(_ text: String) -> [Unicode.Scalar: Int] {
        text.precomposedStringWithCanonicalMapping.unicodeScalars.reduce(into: [:]) { counts, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { counts[scalar, default: 0] += 1 }
        }
    }
}
