import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutPhase9PerturbationDiagnosticsTests: XCTestCase {
    func testThreeColumnPerturbationDiagnostics() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["three-column"])
        let document = try XCTUnwrap(PDFDocument(data: TestPDFBuilder.layoutPDF(fixture)))
        let page = try XCTUnwrap(document.page(at: 0))
        let baseline = PdfPositionedTextExtractor.nativeFragments(page: page)

        for seed in 1...12 {
            let fragments = perturbed(baseline, seed: UInt64(seed))
            let assessment = PdfLayoutComplexityDetector.assess(
                fragments: fragments,
                nativeText: page.string ?? ""
            )
            let lines = PdfLayoutLineBuilder.build(fragments: fragments)
            let blocks = PdfLayoutBlockBuilder.build(lines: lines)
            let layout = PdfLayoutRegionDetector.segment(blocks: blocks)
            let special = PdfLayoutRoleClassifier.analyze(blocks: blocks, layout: layout)
            let order = PdfReadingOrderResolver.resolve(
                blocks: blocks,
                layout: layout,
                hints: special.readingOrderHints
            )
            let result = try PdfLayoutAnalyzer.analyze(
                fragments: fragments,
                nativeText: page.string ?? "",
                nativeTextThreshold: 20,
                pageIndex: 0,
                mode: .always
            )

            print("PHASE9_PERTURB seed=\(seed) complexity=\(assessment.complexity.rawValue) confidence=\(assessment.confidence) lines=\(lines.count) blocks=\(blocks.count) primaryColumns=\(layout.primaryColumnCount) tables=\(special.tables.map { $0.blockIDs }) rawOrder=\(order.orderedBlockIDs)")
            for region in layout.regions {
                print("PHASE9_PERTURB seed=\(seed) region kind=\(region.kind.rawValue) columns=\(region.columns.map { column in column.blockIDs.map { id in blocks.first(where: { $0.id == id })?.sourceOrder ?? -1 } })")
            }
            print("PHASE9_PERTURB seed=\(seed) analyzedOrder=\(result?.readingOrder.orderedBlockIDs ?? []) text=\((result?.text ?? "nil").replacingOccurrences(of: "\n", with: " | "))")
        }
    }

    private func perturbed(_ source: [PdfLayoutFragment], seed: UInt64) -> [PdfLayoutFragment] {
        var generator = Phase9PerturbGenerator(state: seed)
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

private struct Phase9PerturbGenerator {
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
