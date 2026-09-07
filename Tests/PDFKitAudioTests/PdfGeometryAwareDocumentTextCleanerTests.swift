import Foundation
import XCTest
@testable import PDFKitAudio

final class PdfGeometryAwareDocumentTextCleanerTests: XCTestCase {
    func testGeometryFindsRunningHeaderOutsideTextualFirstAndLastLines() {
        let pages = (0..<6).map { index in
            page(index, text: "META_A_\(index)\nMETA_B_\(index)\nRunning Header\nBODY_\(index)\nTAIL_A_\(index)\nTAIL_B_\(index)")
        }
        let fingerprints = (0..<6).map { index in
            fingerprint(page: index, block: index, text: "Running Header", x: 0.18, y: 0.025, width: 0.64, height: 0.025)
        }

        let cleaned = clean(pages, fingerprints: fingerprints)
        let combined = cleaned.map(\.text).joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "Running Header", in: combined), 1)
        for index in 0..<6 {
            XCTAssertEqual(occurrences(of: "BODY_\(index)", in: combined), 1)
        }
    }

    func testRepeatedTextWithInconsistentGeometryIsNotRemovedWhenGeometryIsAvailable() {
        let pages = (0..<6).map { index in
            page(index, text: "A_\(index)\nB_\(index)\nImportant Label\nC_\(index)\nD_\(index)\nE_\(index)")
        }
        let yPositions: [CGFloat] = [0.02, 0.08, 0.14, 0.20, 0.24, 0.27]
        let fingerprints = yPositions.enumerated().map { index, y in
            fingerprint(
                page: index,
                block: index,
                text: "Important Label",
                x: 0.18,
                y: y,
                width: 0.64,
                height: 0.015,
                style: .init(fontSizeBand: 5, isPredominantlyBold: false)
            )
        }

        let cleaned = clean(pages, fingerprints: fingerprints)
        let combined = cleaned.map(\.text).joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "Important Label", in: combined), 6)
    }

    func testMovingFooterPageNumbersAreRemovedDespiteHorizontalMovement() {
        let pages = (0..<6).map { index in
            page(index, text: "A_\(index)\nB_\(index)\n\(index + 1)\nC_\(index)\nD_\(index)\nE_\(index)")
        }
        let fingerprints = (0..<6).map { index in
            fingerprint(
                page: index,
                block: index,
                text: String(index + 1),
                x: index.isMultiple(of: 2) ? 0.08 : 0.84,
                y: 0.94,
                width: 0.08,
                height: 0.025
            )
        }

        let cleaned = clean(pages, fingerprints: fingerprints)

        for index in 0..<6 {
            XCTAssertFalse(cleaned[index].text.components(separatedBy: .newlines).contains(String(index + 1)))
            XCTAssertTrue(cleaned[index].text.contains("B_\(index)"))
            XCTAssertTrue(cleaned[index].text.contains("C_\(index)"))
        }
    }

    func testLegitimateRepeatedYearNearEdgeIsPreserved() {
        let pages = (0..<6).map { index in
            page(index, text: "A_\(index)\nB_\(index)\n2024\nC_\(index)\nD_\(index)\nE_\(index)")
        }
        let fingerprints = (0..<6).map { index in
            fingerprint(page: index, block: index, text: "2024", x: 0.80, y: 0.94, width: 0.10, height: 0.025)
        }

        let cleaned = clean(pages, fingerprints: fingerprints)
        let combined = cleaned.map(\.text).joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "2024", in: combined), 6)
    }

    func testSemanticChapterHeadingWinsOverEarlierRunningHeaderCopies() {
        let pages = (0..<6).map { index in
            page(index, text: "Chapter One\nBODY_\(index)")
        }
        let fingerprints = (0..<6).map { index -> PdfDocumentLayoutFingerprint in
            if index == 2 {
                return fingerprint(
                    page: index,
                    block: index,
                    text: "Chapter One",
                    x: 0.16,
                    y: 0.12,
                    width: 0.68,
                    height: 0.045,
                    role: .heading,
                    confidence: 0.96
                )
            }
            return fingerprint(page: index, block: index, text: "Chapter One", x: 0.22, y: 0.02, width: 0.56, height: 0.022)
        }

        let cleaned = clean(pages, fingerprints: fingerprints)

        XCTAssertFalse(cleaned[0].text.contains("Chapter One"))
        XCTAssertFalse(cleaned[1].text.contains("Chapter One"))
        XCTAssertTrue(cleaned[2].text.contains("Chapter One"))
        XCTAssertFalse(cleaned[3].text.contains("Chapter One"))
        XCTAssertFalse(cleaned[4].text.contains("Chapter One"))
        XCTAssertFalse(cleaned[5].text.contains("Chapter One"))
        XCTAssertEqual(occurrences(of: "Chapter One", in: cleaned.map(\.text).joined(separator: "\n")), 1)
    }

    func testShortSemanticTopLineAppearingOnlyTwiceIsPreserved() {
        let pages = (0..<6).map { index in
            let top = index < 2 ? "Important Notice" : "Unique Header \(index)"
            return page(index, text: "\(top)\nBODY_\(index)")
        }
        let fingerprints = (0..<2).map { index in
            fingerprint(page: index, block: index, text: "Important Notice", x: 0.20, y: 0.02, width: 0.60, height: 0.025)
        }

        let cleaned = clean(pages, fingerprints: fingerprints)

        XCTAssertEqual(occurrences(of: "Important Notice", in: cleaned.map(\.text).joined(separator: "\n")), 2)
    }

    func testDocumentsUnderFourPagesDoNotUseRepeatedRunningMatterStatistics() {
        let pages = (0..<3).map { index in
            page(index, text: "Repeated Header\nBODY_\(index)")
        }
        let fingerprints = (0..<3).map { index in
            fingerprint(page: index, block: index, text: "Repeated Header", x: 0.20, y: 0.02, width: 0.60, height: 0.025)
        }

        let cleaned = clean(pages, fingerprints: fingerprints)

        XCTAssertEqual(occurrences(of: "Repeated Header", in: cleaned.map(\.text).joined(separator: "\n")), 3)
    }

    func testMixedAnalyzedAndFastPathPagesStillCleanAsOneDocument() {
        let pages = (0..<8).map { index in
            page(index, text: "Shared Header\nBODY_\(index)")
        }
        let fingerprints = [0, 2, 4, 6].map { index in
            fingerprint(page: index, block: index, text: "Shared Header", x: 0.20, y: 0.02, width: 0.60, height: 0.025)
        }

        let cleaned = clean(pages, fingerprints: fingerprints)

        XCTAssertEqual(occurrences(of: "Shared Header", in: cleaned.map(\.text).joined(separator: "\n")), 1)
        for index in 0..<8 {
            XCTAssertTrue(cleaned[index].text.contains("BODY_\(index)"))
        }
    }

    func testAlternatingHeadersUseIndependentGeometryBackedRecurrence() {
        let pages = (0..<8).map { index in
            let header = index.isMultiple(of: 2) ? "Book Title" : "Author Name"
            return page(index, text: "A_\(index)\nB_\(index)\n\(header)\nC_\(index)\nD_\(index)\nE_\(index)")
        }
        let fingerprints = (0..<8).map { index in
            fingerprint(
                page: index,
                block: index,
                text: index.isMultiple(of: 2) ? "Book Title" : "Author Name",
                x: index.isMultiple(of: 2) ? 0.12 : 0.52,
                y: 0.025,
                width: 0.36,
                height: 0.025
            )
        }

        let cleaned = clean(pages, fingerprints: fingerprints)
        let combined = cleaned.map(\.text).joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "Book Title", in: combined), 1)
        XCTAssertEqual(occurrences(of: "Author Name", in: combined), 1)
    }

    func testGeometryAwareCleanupIsDeterministic() {
        let pages = (0..<6).map { index in
            page(index, text: "Repeated Header\nBODY_\(index)\n\(index + 1)")
        }
        let fingerprints = (0..<6).flatMap { index in
            [
                fingerprint(page: index, block: index * 2, text: "Repeated Header", x: 0.20, y: 0.02, width: 0.60, height: 0.025),
                fingerprint(page: index, block: index * 2 + 1, text: String(index + 1), x: 0.46, y: 0.95, width: 0.08, height: 0.02)
            ]
        }

        let first = clean(pages, fingerprints: fingerprints)
        let second = clean(pages, fingerprints: fingerprints.reversed())

        XCTAssertEqual(first, second)
    }

    private func clean(
        _ pages: [PdfPageContent],
        fingerprints: [PdfDocumentLayoutFingerprint]
    ) -> [PdfPageContent] {
        PdfDocumentTextCleaner.clean(
            pages,
            configuration: .audiobookDefault,
            layoutFingerprints: fingerprints
        )
    }

    private func page(_ index: Int, text: String) -> PdfPageContent {
        PdfPageContent(
            pageIndex: index,
            nativeText: text,
            text: text,
            extractionSource: .native,
            confidence: 1
        )
    }

    private func fingerprint(
        page: Int,
        block: Int,
        text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        role: PdfLayoutRole = .unknown,
        confidence: Double = 0,
        style: PdfDocumentLayoutStyleBucket? = nil
    ) -> PdfDocumentLayoutFingerprint {
        PdfDocumentLayoutFingerprint(
            pageIndex: page,
            blockID: block,
            text: text,
            rect: CGRect(x: x, y: y, width: width, height: height),
            role: role,
            roleConfidence: confidence,
            styleBucket: style
        )
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
