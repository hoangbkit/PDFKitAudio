import Foundation
import XCTest
@testable import PDFKitAudio

final class PdfLayoutDiagnosticsTests: XCTestCase {
    func testAcceptedCaptureContainsGeometryRolesRegionsAndReadingOrder() throws {
        let fragments = [
            fragment(0, "LEFT_TOP", x: 0.08, y: 0.10, width: 0.34),
            fragment(1, "LEFT_BOTTOM", x: 0.08, y: 0.28, width: 0.34),
            fragment(2, "RIGHT_TOP", x: 0.58, y: 0.14, width: 0.34),
            fragment(3, "RIGHT_BOTTOM", x: 0.58, y: 0.32, width: 0.34)
        ]
        var snapshot: PdfLayoutDiagnostics.Snapshot?

        let result = try PdfLayoutAnalyzer.analyze(
            fragments: fragments,
            nativeText: fragments.map(\.text).joined(separator: "\n"),
            nativeTextThreshold: 20,
            pageIndex: 7,
            mode: .always,
            diagnostics: { snapshot = $0 }
        )

        XCTAssertNotNil(result)
        guard let snapshot else { return XCTFail("Expected diagnostics snapshot") }
        XCTAssertEqual(snapshot.pageIndex, 7)
        XCTAssertEqual(snapshot.mode, "always")
        XCTAssertEqual(snapshot.decision, .accepted)
        XCTAssertEqual(snapshot.fragments.count, 4)
        XCTAssertFalse(snapshot.lines.isEmpty)
        XCTAssertFalse(snapshot.blocks.isEmpty)
        XCTAssertFalse(snapshot.regions.isEmpty)
        XCTAssertTrue(snapshot.blocks.allSatisfy { !$0.role.isEmpty })
        XCTAssertEqual(Set(snapshot.orderedBlockIDs), Set(snapshot.blocks.map(\.id)))
        XCTAssertFalse(snapshot.readingOrderEdges.isEmpty)
        XCTAssertNotNil(snapshot.readingOrderConfidence)
        XCTAssertEqual(snapshot.readingOrderUsedFallback, false)
        XCTAssertTrue(snapshot.textDescription.contains("decision=accepted"))
        XCTAssertTrue(snapshot.textDescription.contains("complexity="))
        XCTAssertTrue(snapshot.jsonString?.contains("\"decision\" : \"accepted\"") == true)
    }

    func testAutoFastPathStillEmitsWhyAnalysisWasSkipped() throws {
        let fragments = [
            fragment(0, "CHAPTER ONE", x: 0.12, y: 0.10, width: 0.68),
            fragment(1, "A normal single column paragraph.", x: 0.12, y: 0.24, width: 0.68),
            fragment(2, "Another normal single column paragraph.", x: 0.12, y: 0.38, width: 0.68)
        ]
        var snapshot: PdfLayoutDiagnostics.Snapshot?

        let result = try PdfLayoutAnalyzer.analyze(
            fragments: fragments,
            nativeText: fragments.map(\.text).joined(separator: "\n"),
            nativeTextThreshold: 20,
            pageIndex: 0,
            mode: .auto,
            diagnostics: { snapshot = $0 }
        )

        XCTAssertNil(result)
        guard let snapshot else { return XCTFail("Expected diagnostics snapshot") }
        XCTAssertEqual(snapshot.decision, .fastPath)
        XCTAssertEqual(snapshot.complexity?.category, "simpleSingleColumn")
        XCTAssertFalse(snapshot.fragments.isEmpty)
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertTrue(snapshot.decisionReason.contains("fast path"))
    }

    func testStructuralFallbackExplainsDuplicateFragmentIdentity() throws {
        let fragments = [
            fragment(42, "FIRST", x: 0.10, y: 0.10, width: 0.30, sourceOrder: 0),
            fragment(42, "SECOND", x: 0.60, y: 0.40, width: 0.30, sourceOrder: 1)
        ]
        var snapshot: PdfLayoutDiagnostics.Snapshot?

        let result = try PdfLayoutAnalyzer.analyze(
            fragments: fragments,
            nativeText: "FIRST\nSECOND",
            nativeTextThreshold: 20,
            pageIndex: 2,
            mode: .always,
            diagnostics: { snapshot = $0 }
        )

        XCTAssertNil(result)
        guard let snapshot else { return XCTFail("Expected diagnostics snapshot") }
        XCTAssertEqual(snapshot.decision, .fallback)
        XCTAssertEqual(snapshot.fragments.count, 2)
        XCTAssertTrue(snapshot.decisionReason.contains("not unique"))
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertTrue(snapshot.blocks.isEmpty)
    }

    func testNeverModeReportsPermanentLegacyEscapeHatchWithoutAnalysis() throws {
        var snapshot: PdfLayoutDiagnostics.Snapshot?
        let fragments = [fragment(0, "TEXT", x: 0.10, y: 0.10, width: 0.70)]

        let result = try PdfLayoutAnalyzer.analyze(
            fragments: fragments,
            nativeText: "TEXT",
            nativeTextThreshold: 20,
            pageIndex: 1,
            mode: .never,
            diagnostics: { snapshot = $0 }
        )

        XCTAssertNil(result)
        guard let snapshot else { return XCTFail("Expected diagnostics snapshot") }
        XCTAssertEqual(snapshot.mode, "never")
        XCTAssertEqual(snapshot.decision, .fastPath)
        XCTAssertTrue(snapshot.fragments.isEmpty)
        XCTAssertTrue(snapshot.decisionReason.contains("legacy selected text"))
    }

    private func fragment(
        _ id: Int,
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        sourceOrder: Int? = nil
    ) -> PdfLayoutFragment {
        PdfLayoutFragment(
            id: id,
            text: text,
            rect: CGRect(x: x, y: y, width: width, height: 0.04),
            source: .native,
            confidence: 1,
            sourceOrder: sourceOrder ?? id,
            style: PdfLayoutStyleHints(fontSize: 12, isBold: false, isItalic: false)
        )
    }
}
