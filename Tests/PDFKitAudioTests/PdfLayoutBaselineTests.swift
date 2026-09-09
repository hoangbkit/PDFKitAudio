import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutBaselineTests: XCTestCase {
    func testFixtureCatalogIsLargeUniqueAndFullyClassified() throws {
        let fixtures = TestLayoutFixtureCatalog.all
        XCTAssertGreaterThanOrEqual(fixtures.count, 50)
        XCTAssertEqual(Set(fixtures.map(\.name)).count, fixtures.count)
        XCTAssertFalse(fixtures.contains { $0.category.isEmpty })
        XCTAssertFalse(fixtures.contains { $0.pages.isEmpty })

        let supportCounts = Dictionary(grouping: fixtures, by: \.support).mapValues(\.count)
        XCTAssertGreaterThan(supportCounts[.supported] ?? 0, 0)
        XCTAssertGreaterThan(supportCounts[.degradedButReadable] ?? 0, 0)

        let requiredCategories: Set<String> = [
            "simple",
            "columns",
            "mixed-regions",
            "side-content",
            "tables",
            "footnotes-captions",
            "running-matter",
            "difficult-positioning",
            "scripts-languages",
            "ocr-equivalents"
        ]
        XCTAssertTrue(requiredCategories.isSubset(of: Set(fixtures.map(\.category))))
    }

    func testAllFixtureGeometryIsNormalizedAndFinite() {
        for fixture in TestLayoutFixtureCatalog.all {
            for (pageIndex, page) in fixture.pages.enumerated() {
                XCTAssertGreaterThan(page.size.width, 0, "\(fixture.name) page \(pageIndex)")
                XCTAssertGreaterThan(page.size.height, 0, "\(fixture.name) page \(pageIndex)")
                XCTAssertTrue([0, 90, 180, 270].contains(((page.rotation % 360) + 360) % 360), "\(fixture.name) page \(pageIndex)")

                for box in page.boxes {
                    XCTAssertFalse(box.marker.isEmpty, fixture.name)
                    XCTAssertTrue(box.rect.minX.isFinite && box.rect.minY.isFinite && box.rect.width.isFinite && box.rect.height.isFinite, fixture.name)
                    XCTAssertGreaterThanOrEqual(box.rect.minX, 0, fixture.name)
                    XCTAssertGreaterThanOrEqual(box.rect.minY, 0, fixture.name)
                    XCTAssertLessThanOrEqual(box.rect.maxX, 1.000_001, fixture.name)
                    XCTAssertLessThanOrEqual(box.rect.maxY, 1.000_001, fixture.name)
                    XCTAssertGreaterThan(box.rect.width, 0, fixture.name)
                    XCTAssertGreaterThan(box.rect.height, 0, fixture.name)
                }
            }
        }
    }

    func testEveryFixtureCanBeGeneratedAsPDF() throws {
        for fixture in TestLayoutFixtureCatalog.all {
            let data = try TestPDFBuilder.layoutPDF(fixture)
            guard let document = PDFDocument(data: data) else {
                return XCTFail("Could not reopen fixture \(fixture.name)")
            }
            XCTAssertEqual(document.pageCount, fixture.pages.count, fixture.name)
        }
    }

    func testNativeFixturePagesPreserveSemanticMarkersInRawPDFKitText() throws {
        for fixture in TestLayoutFixtureCatalog.all {
            let data = try TestPDFBuilder.layoutPDF(fixture)
            guard let document = PDFDocument(data: data) else {
                return XCTFail("Could not reopen fixture \(fixture.name)")
            }

            for (pageIndex, pageSpec) in fixture.pages.enumerated() where pageSpec.rendering == .native {
                let raw = document.page(at: pageIndex)?.string ?? ""
                let canonicalRaw = TestLayoutBaselineScorer.canonicalMarkerText(raw)
                for box in pageSpec.boxes {
                    // Duplicate-layer fixtures intentionally use a marker that is
                    // semantic text rather than a unique source-layer identifier.
                    if box.marker == "DUPLICATE_LAYER" { continue }
                    let probe = measurementProbe(for: box)
                    XCTAssertTrue(
                        canonicalRaw.localizedCaseInsensitiveContains(
                            TestLayoutBaselineScorer.canonicalMarkerText(probe)
                        ),
                        "Missing probe \(probe) for marker \(box.marker) in \(fixture.name) page \(pageIndex). Raw text: \(raw)"
                    )
                }
            }
        }
    }

    func testScannedFixturePagesHaveNoSelectableNativeText() throws {
        let scannedFixtures = TestLayoutFixtureCatalog.all.filter {
            $0.pages.contains { $0.rendering == .scanned }
        }
        XCTAssertFalse(scannedFixtures.isEmpty)

        for fixture in scannedFixtures {
            let data = try TestPDFBuilder.layoutPDF(fixture)
            guard let document = PDFDocument(data: data) else {
                return XCTFail("Could not reopen fixture \(fixture.name)")
            }
            for (pageIndex, pageSpec) in fixture.pages.enumerated() where pageSpec.rendering == .scanned {
                let raw = document.page(at: pageIndex)?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                XCTAssertTrue(raw.isEmpty, "Expected image-only page for \(fixture.name) page \(pageIndex)")
            }
        }
    }

    func testBaselineReadingOrderMetricsAreMeasurableWithoutChangingProductionBehavior() throws {
        let parser = PdfParser(
            ocrMode: .never,
            cleanupConfiguration: .minimal,
            extractCoverImage: false
        )

        var overall = TestLayoutBaselineAggregate()
        var byCategory: [String: TestLayoutBaselineAggregate] = [:]

        for fixture in TestLayoutFixtureCatalog.all where fixture.pages.allSatisfy({ $0.rendering == .native }) {
            let data = try TestPDFBuilder.layoutPDF(fixture)
            let book = try parser.parse(data: data)
            let text = book.pages.map(\.text).joined(separator: "\n\n")
            let score = TestLayoutBaselineScorer.score(
                expectedMarkers: measurementMarkers(for: fixture),
                in: text
            )
            overall.add(score)
            var categoryAggregate = byCategory[fixture.category] ?? TestLayoutBaselineAggregate()
            categoryAggregate.add(score)
            byCategory[fixture.category] = categoryAggregate
        }

        XCTAssertGreaterThan(overall.fixtureCount, 50)
        XCTAssertGreaterThan(overall.expectedMarkers, 0)
        XCTAssertGreaterThan(overall.totalPairs, 0)
        XCTAssertGreaterThan(overall.coverage, 0.90)

        print("LAYOUT_BASELINE overall fixtures=\(overall.fixtureCount) coverage=\(format(overall.coverage)) pairwise=\(format(overall.pairwiseAccuracy)) duplicateMarkers=\(overall.duplicateMarkers)")
        for category in byCategory.keys.sorted() {
            guard let aggregate = byCategory[category] else { continue }
            print("LAYOUT_BASELINE category=\(category) fixtures=\(aggregate.fixtureCount) coverage=\(format(aggregate.coverage)) pairwise=\(format(aggregate.pairwiseAccuracy)) duplicateMarkers=\(aggregate.duplicateMarkers)")
        }
    }

    func testMarkerOrderScorerPenalizesMissingAndOutOfOrderMarkers() {
        let perfect = TestLayoutBaselineScorer.score(
            expectedMarkers: ["A", "B", "C"],
            in: "A text B text C"
        )
        XCTAssertEqual(perfect.coverage, 1)
        XCTAssertEqual(perfect.pairwiseAccuracy, 1)

        let reordered = TestLayoutBaselineScorer.score(
            expectedMarkers: ["A", "B", "C"],
            in: "A text C text B"
        )
        XCTAssertEqual(reordered.coverage, 1)
        XCTAssertLessThan(reordered.pairwiseAccuracy, 1)

        let missing = TestLayoutBaselineScorer.score(
            expectedMarkers: ["A", "B", "C"],
            in: "A text C"
        )
        XCTAssertLessThan(missing.coverage, 1)
        XCTAssertLessThan(missing.pairwiseAccuracy, 1)

        let wrapped = TestLayoutBaselineScorer.score(
            expectedMarkers: ["MARGINAL_NOTE", "AFTER"],
            in: "MARGINAL_NOT E\nAFTER"
        )
        XCTAssertEqual(wrapped.coverage, 1)
        XCTAssertEqual(wrapped.pairwiseAccuracy, 1)
    }

    func testDiagnosticsProduceInspectableJSON() throws {
        guard let fixture = TestLayoutFixtureCatalog.byName["two-column-symmetric"] else {
            return XCTFail("Missing fixture")
        }
        let fixtureJSON = try TestLayoutDiagnostics.fixtureJSON(fixture)
        XCTAssertTrue(fixtureJSON.contains("two-column-symmetric"))
        XCTAssertTrue(fixtureJSON.contains("L1"))

        let data = try TestPDFBuilder.layoutPDF(fixture)
        let book = try PdfParser(ocrMode: .never, extractCoverImage: false).parse(data: data)
        let bookJSON = try TestLayoutDiagnostics.parsedBookJSON(book)
        XCTAssertTrue(bookJSON.contains("pageCount"))
        XCTAssertTrue(bookJSON.contains("L1"))
    }

    /// Repeated running headers deliberately reuse the same string, so they are
    /// poor identity markers for pairwise order scoring. Only unique declared
    /// markers participate in the baseline. If an explicit fixture text omits its
    /// abstract marker (language fixtures do this), use the text's first token as
    /// the stable probe while keeping the source content itself unchanged.
    private func measurementMarkers(for fixture: TestLayoutFixture) -> [String] {
        let counts = Dictionary(grouping: fixture.expectedMarkerOrder, by: { $0 })
            .mapValues(\.count)
        let boxes = fixture.pages.flatMap(\.boxes)

        return fixture.expectedMarkerOrder.compactMap { marker in
            guard counts[marker] == 1 else { return nil }
            guard let box = boxes.first(where: { $0.marker == marker }) else {
                return marker
            }
            return measurementProbe(for: box)
        }
    }

    private func measurementProbe(for box: TestLayoutTextBox) -> String {
        let canonicalMarker = TestLayoutBaselineScorer.canonicalMarkerText(box.marker)
        let canonicalText = TestLayoutBaselineScorer.canonicalMarkerText(box.text)
        if canonicalText.localizedCaseInsensitiveContains(canonicalMarker) {
            return box.marker
        }
        return box.text.split(whereSeparator: \.isWhitespace).first.map(String.init)
            ?? box.marker
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
