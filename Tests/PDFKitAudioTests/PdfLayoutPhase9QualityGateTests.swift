import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutPhase9QualityGateTests: XCTestCase {
    func testEverySupportedNativeFixtureHasExactAnalyzerMarkerOrderAndConservation() throws {
        let fixtures = TestLayoutFixtureCatalog.all.filter {
            $0.support == .supported && $0.pages.allSatisfy { $0.rendering == .native }
        }
        XCTAssertGreaterThan(fixtures.count, 50)

        var checked = 0
        for fixture in fixtures {
            let data = try TestPDFBuilder.layoutPDF(fixture)
            let document = try XCTUnwrap(PDFDocument(data: data), fixture.name)
            var analyzedPages: [String] = []

            for pageIndex in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: pageIndex), "\(fixture.name) page \(pageIndex)")
                let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
                if fragments.isEmpty {
                    analyzedPages.append("")
                    continue
                }

                let result = try PdfLayoutAnalyzer.analyze(
                    fragments: fragments,
                    nativeText: page.string ?? "",
                    nativeTextThreshold: 20,
                    pageIndex: pageIndex,
                    mode: .always
                )
                XCTAssertNotNil(result, "Analyzer rejected supported fixture \(fixture.name) page \(pageIndex)")
                analyzedPages.append(result?.text ?? "")
            }

            let score = TestLayoutBaselineScorer.score(
                expectedMarkers: qualityMarkers(for: fixture),
                in: analyzedPages.joined(separator: "\n\n")
            )
            XCTAssertEqual(score.coverage, 1, "Missing semantic marker in \(fixture.name)")
            XCTAssertEqual(score.pairwiseAccuracy, 1, "Wrong semantic order in \(fixture.name)")
            XCTAssertEqual(score.duplicateMarkerCount, 0, "Duplicated semantic marker in \(fixture.name)")
            checked += 1
        }

        XCTAssertEqual(checked, fixtures.count)
    }

    func testAutoParserMeetsExactOrderOnSupportedComplexNativeFixtures() throws {
        let complexCategories: Set<String> = [
            "columns",
            "mixed-regions",
            "side-content",
            "tables",
            "footnotes-captions"
        ]
        let fixtures = TestLayoutFixtureCatalog.all.filter {
            $0.support == .supported
                && $0.pages.allSatisfy { $0.rendering == .native }
                && complexCategories.contains($0.category)
        }
        XCTAssertGreaterThan(fixtures.count, 20)

        let parser = parser(layout: .auto)
        for fixture in fixtures {
            let book = try parser.parse(data: TestPDFBuilder.layoutPDF(fixture))
            let score = TestLayoutBaselineScorer.score(
                expectedMarkers: qualityMarkers(for: fixture),
                in: book.pages.map(\.text).joined(separator: "\n\n")
            )
            XCTAssertEqual(score.coverage, 1, "Parser lost a marker in \(fixture.name)")
            XCTAssertEqual(score.pairwiseAccuracy, 1, "Parser order mismatch in \(fixture.name)")
            XCTAssertEqual(score.duplicateMarkerCount, 0, "Parser duplicated a marker in \(fixture.name)")
        }
    }

    func testControlledSimpleCorpusHasPerfectAutoFastPathPrecision() throws {
        let simpleCategories: Set<String> = ["simple", "scripts-languages", "running-matter"]
        let fixtures = TestLayoutFixtureCatalog.all.filter {
            $0.pages.allSatisfy { $0.rendering == .native }
                && simpleCategories.contains($0.category)
        }
        XCTAssertGreaterThan(fixtures.count, 15)

        let automatic = parser(layout: .auto)
        let legacy = parser(layout: .never)
        var equivalent = 0

        for fixture in fixtures {
            let data = try TestPDFBuilder.layoutPDF(fixture)
            let autoBook = try automatic.parse(data: data)
            let neverBook = try legacy.parse(data: data)
            XCTAssertEqual(autoBook.pages, neverBook.pages, "Simple fast-path regression in \(fixture.name)")
            if autoBook.pages == neverBook.pages { equivalent += 1 }
        }

        let precision = Double(equivalent) / Double(max(1, fixtures.count))
        XCTAssertGreaterThanOrEqual(precision, 0.99)
    }

    func testHealthySimpleDigitalPagesDoNotIncreaseOCRInvocation() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["single-column-narrow-margins"])
            .repeatedPages(8, name: "phase9-healthy-simple-no-ocr")
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let counter = LockedCounter()
        let parser = PdfParser(
            ocrConfiguration: PdfOCRConfiguration(mode: .auto),
            cleanupConfiguration: .minimal,
            extractCoverImage: false,
            layoutConfiguration: PdfLayoutConfiguration(mode: .auto),
            ocrRecognizer: { _, _ in
                counter.increment()
                return PdfOCREngine.OCRResult(text: "unexpected OCR", confidence: 1)
            }
        )

        let book = try parser.parse(data: data)

        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(book.ocrPageCount, 0)
        XCTAssertTrue(book.pages.allSatisfy { $0.extractionSource == .native })
    }

    func testSupportedLayoutsRemainExactUnderDeterministicCoordinatePerturbations() throws {
        let names = [
            "two-column-symmetric",
            "three-column",
            "full-width-title-two-columns",
            "columns-interrupted-by-caption",
            "right-sidebar",
            "table-header-row",
            "caption-between-columns"
        ]

        for name in names {
            let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName[name])
            XCTAssertEqual(fixture.pages.count, 1, name)
            let data = try TestPDFBuilder.layoutPDF(fixture)
            let document = try XCTUnwrap(PDFDocument(data: data))
            let page = try XCTUnwrap(document.page(at: 0))
            let baselineFragments = PdfPositionedTextExtractor.nativeFragments(page: page)
            XCTAssertFalse(baselineFragments.isEmpty, name)

            for seed in 0..<12 {
                let fragments = perturbed(baselineFragments, seed: UInt64(seed + 1))
                let result = try PdfLayoutAnalyzer.analyze(
                    fragments: fragments,
                    nativeText: page.string ?? "",
                    nativeTextThreshold: 20,
                    pageIndex: 0,
                    mode: .always
                )
                let accepted = try XCTUnwrap(result, "Perturbed supported layout rejected: \(name), seed \(seed)")
                let score = TestLayoutBaselineScorer.score(
                    expectedMarkers: qualityMarkers(for: fixture),
                    in: accepted.text
                )
                XCTAssertEqual(score.coverage, 1, "\(name), seed \(seed)")
                XCTAssertEqual(score.pairwiseAccuracy, 1, "\(name), seed \(seed)")
                XCTAssertEqual(score.duplicateMarkerCount, 0, "\(name), seed \(seed)")
            }
        }
    }

    func testMalformedGeometryIsFilteredWithoutCorruptingValidLayout() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["two-column-symmetric"])
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        var fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
        let nextID = (fragments.map(\.id).max() ?? 0) + 1
        fragments.append(PdfLayoutFragment(
            id: nextID,
            text: "INVALID_ZERO_WIDTH",
            rect: CGRect(x: 0.2, y: 0.2, width: 0, height: 0.03),
            source: .native,
            confidence: 1,
            sourceOrder: nextID
        ))
        fragments.append(PdfLayoutFragment(
            id: nextID + 1,
            text: "INVALID_NAN",
            rect: CGRect(x: CGFloat.nan, y: 0.3, width: 0.2, height: 0.03),
            source: .native,
            confidence: 1,
            sourceOrder: nextID + 1
        ))

        let result = try XCTUnwrap(PdfLayoutAnalyzer.analyze(
            fragments: fragments,
            nativeText: page.string ?? "",
            nativeTextThreshold: 20,
            pageIndex: 0,
            mode: .always
        ))
        let score = TestLayoutBaselineScorer.score(
            expectedMarkers: qualityMarkers(for: fixture),
            in: result.text
        )

        XCTAssertEqual(score.coverage, 1)
        XCTAssertEqual(score.pairwiseAccuracy, 1)
        XCTAssertEqual(score.duplicateMarkerCount, 0)
        XCTAssertFalse(result.text.contains("INVALID_ZERO_WIDTH"))
        XCTAssertFalse(result.text.contains("INVALID_NAN"))
    }

    func testDegradedAndUnsupportedFixturesFailReadablyWithoutCrashing() throws {
        let fixtures = TestLayoutFixtureCatalog.all.filter { $0.support != .supported }
        XCTAssertFalse(fixtures.isEmpty)
        let parser = parser(layout: .auto)

        for fixture in fixtures where fixture.pages.allSatisfy({ $0.rendering == .native }) {
            let book = try parser.parse(data: TestPDFBuilder.layoutPDF(fixture))
            XCTAssertEqual(book.pages.count, fixture.pages.count, fixture.name)
            let sourceHasText = fixture.pages.contains { !$0.boxes.isEmpty }
            if sourceHasText {
                XCTAssertFalse(
                    book.pages.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Degraded fixture became unreadable: \(fixture.name)"
                )
            }
        }
    }

    private func parser(layout mode: PdfLayoutMode) -> PdfParser {
        PdfParser(configuration: PdfParserConfiguration(
            ocr: PdfOCRConfiguration(mode: .never),
            layout: PdfLayoutConfiguration(mode: mode),
            cleanup: .minimal,
            extractCoverImage: false
        ))
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

    private func perturbed(_ source: [PdfLayoutFragment], seed: UInt64) -> [PdfLayoutFragment] {
        var generator = Phase9Generator(state: seed)
        var output = source.map { fragment -> PdfLayoutFragment in
            let dx = generator.delta(maximum: 0.0035)
            let dy = generator.delta(maximum: 0.0035)
            let dw = generator.delta(maximum: 0.0020)
            let dh = generator.delta(maximum: 0.0015)
            let width = max(0.001, min(1, fragment.rect.width + dw))
            let height = max(0.001, min(1, fragment.rect.height + dh))
            let x = max(0, min(1 - width, fragment.rect.minX + dx))
            let y = max(0, min(1 - height, fragment.rect.minY + dy))
            return PdfLayoutFragment(
                id: fragment.id,
                text: fragment.text,
                rect: CGRect(x: x, y: y, width: width, height: height),
                source: fragment.source,
                confidence: fragment.confidence,
                sourceOrder: fragment.sourceOrder,
                style: fragment.style
            )
        }
        if seed.isMultiple(of: 2) {
            output.reverse()
        }
        return output
    }
}

private struct Phase9Generator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func delta(maximum: CGFloat) -> CGFloat {
        let unit = Double(next() % 1_000_001) / 1_000_000.0
        return CGFloat((unit * 2 - 1) * Double(maximum))
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
