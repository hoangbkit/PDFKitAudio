import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfGeometryAwareDocumentTextCleanerIntegrationTests: XCTestCase {
    func testRealPDFKitRepeatedHeaderUsesGeometryFingerprints() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["identical-header-every-page"])
        let result = try makePagesAndFingerprints(fixture)

        let cleaned = PdfDocumentTextCleaner.clean(
            result.pages,
            configuration: .audiobookDefault,
            layoutFingerprints: result.fingerprints
        )
        let combined = cleaned.map(\.text).joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "BOOK_HEADER", in: combined), 1)
        for index in 0..<fixture.pages.count {
            XCTAssertEqual(occurrences(of: "BODY_PAGE_\(index + 1)", in: combined), 1)
        }
    }

    func testRealPDFKitAlternatingHeadersRemainIndependentPatterns() throws {
        let base = try XCTUnwrap(TestLayoutFixtureCatalog.byName["alternating-even-odd-headers"])
        // The production cleaner intentionally requires at least three recurring
        // occurrences. Repeat the four-page fixture so each alternating header
        // appears four times rather than weakening that conservative threshold.
        let fixture = TestLayoutFixture(
            name: "alternating-even-odd-headers-eight-pages",
            category: base.category,
            support: base.support,
            pages: base.pages + base.pages,
            expectedMarkerOrder: base.expectedMarkerOrder + base.expectedMarkerOrder,
            notes: "Eight-page real-PDF recurrence fixture"
        )
        let result = try makePagesAndFingerprints(fixture)

        let cleaned = PdfDocumentTextCleaner.clean(
            result.pages,
            configuration: .audiobookDefault,
            layoutFingerprints: result.fingerprints
        )
        let combined = cleaned.map(\.text).joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "EVEN_HEADER", in: combined), 1)
        XCTAssertEqual(occurrences(of: "ODD_HEADER", in: combined), 1)
        XCTAssertTrue(cleaned.allSatisfy { $0.text.contains("BODY_PAGE_") })
    }

    func testFingerprintBuilderRetainsOnlyCompactDocumentMetadata() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["identical-header-every-page"])
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
        let lines = PdfLayoutLineBuilder.build(fragments: fragments)
        let blocks = PdfLayoutBlockBuilder.build(lines: lines)
        let layout = PdfLayoutRegionDetector.segment(blocks: blocks)
        let analysis = PdfLayoutRoleClassifier.analyze(blocks: blocks, layout: layout)
        let fingerprints = PdfDocumentLayoutFingerprintBuilder.make(
            pageIndex: 0,
            blocks: blocks,
            analysis: analysis
        )

        XCTAssertEqual(fingerprints.count, blocks.count)
        XCTAssertEqual(Set(fingerprints.map(\.blockID)), Set(blocks.map(\.id)))
        XCTAssertTrue(fingerprints.allSatisfy { $0.pageIndex == 0 })
        XCTAssertTrue(fingerprints.allSatisfy { !$0.textSignature.isEmpty })
        XCTAssertTrue(fingerprints.allSatisfy { !$0.lineSignatures.isEmpty })
        XCTAssertTrue(fingerprints.allSatisfy {
            $0.rect.minX.isFinite && $0.rect.minY.isFinite
                && $0.rect.width.isFinite && $0.rect.height.isFinite
        })
    }

    private struct Result {
        let pages: [PdfPageContent]
        let fingerprints: [PdfDocumentLayoutFingerprint]
    }

    private func makePagesAndFingerprints(_ fixture: TestLayoutFixture) throws -> Result {
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let document = try XCTUnwrap(PDFDocument(data: data))
        var pages: [PdfPageContent] = []
        var fingerprints: [PdfDocumentLayoutFingerprint] = []

        for pageIndex in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: pageIndex))
            let native = page.string ?? ""
            let selected = PdfTextCleaner.cleanPage(native, configuration: .audiobookDefault)
            pages.append(PdfPageContent(
                pageIndex: pageIndex,
                nativeText: native,
                text: selected,
                extractionSource: selected.isEmpty ? .empty : .native,
                confidence: selected.isEmpty ? 0 : 1
            ))

            let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
            let lines = PdfLayoutLineBuilder.build(fragments: fragments)
            let blocks = PdfLayoutBlockBuilder.build(lines: lines)
            let layout = PdfLayoutRegionDetector.segment(blocks: blocks)
            let analysis = PdfLayoutRoleClassifier.analyze(blocks: blocks, layout: layout)
            fingerprints.append(contentsOf: PdfDocumentLayoutFingerprintBuilder.make(
                pageIndex: pageIndex,
                blocks: blocks,
                analysis: analysis
            ))
        }

        return Result(pages: pages, fingerprints: fingerprints)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }
}
