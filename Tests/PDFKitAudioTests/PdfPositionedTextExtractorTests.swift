import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfPositionedTextExtractorTests: XCTestCase {
    func testNativeExtractionProducesNormalizedPositionedLines() throws {
        guard let fixture = TestLayoutFixtureCatalog.byName["two-column-symmetric"] else {
            return XCTFail("Missing fixture")
        }
        let document = try makeDocument(fixture)
        guard let page = document.page(at: 0) else { return XCTFail("Missing page") }

        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)

        XCTAssertGreaterThan(fragments.count, 1)
        XCTAssertTrue(fragments.contains { $0.text.contains("L1") })
        XCTAssertTrue(fragments.contains { $0.text.contains("R1") })
        XCTAssertEqual(fragments.map(\.source), Array(repeating: .native, count: fragments.count))
        assertNormalized(fragments)
    }

    func testNativeFragmentOrderingAndGeometryAreStableAcrossRepeatedParses() throws {
        guard let fixture = TestLayoutFixtureCatalog.byName["full-width-title-two-columns"] else {
            return XCTFail("Missing fixture")
        }
        let data = try TestPDFBuilder.layoutPDF(fixture)
        guard let firstDocument = PDFDocument(data: data),
              let firstPage = firstDocument.page(at: 0),
              let secondDocument = PDFDocument(data: data),
              let secondPage = secondDocument.page(at: 0) else {
            return XCTFail("Could not reopen fixture")
        }

        let first = PdfPositionedTextExtractor.nativeFragments(page: firstPage)
        let second = PdfPositionedTextExtractor.nativeFragments(page: secondPage)

        XCTAssertEqual(first.count, second.count)
        for (lhs, rhs) in zip(first, second) {
            XCTAssertEqual(lhs.text, rhs.text)
            XCTAssertEqual(lhs.sourceOrder, rhs.sourceOrder)
            XCTAssertEqual(lhs.rect.origin.x, rhs.rect.origin.x, accuracy: 0.000_001)
            XCTAssertEqual(lhs.rect.origin.y, rhs.rect.origin.y, accuracy: 0.000_001)
            XCTAssertEqual(lhs.rect.width, rhs.rect.width, accuracy: 0.000_001)
            XCTAssertEqual(lhs.rect.height, rhs.rect.height, accuracy: 0.000_001)
        }
    }

    func testNativeUnicodeIntegrityIsPreserved() throws {
        let expected = "Café Việt Nam — déjà vu 你好"
        let data = try TestPDFBuilder.digitalPDF(pages: [expected])
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            return XCTFail("Could not create Unicode fixture")
        }

        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
        let joined = fragments.map(\.text).joined(separator: " ")

        XCTAssertTrue(joined.contains("Café"))
        XCTAssertTrue(joined.contains("Việt Nam"))
        XCTAssertTrue(joined.contains("déjà vu"))
        XCTAssertTrue(joined.contains("你好"))
    }

    func testPageGeometryNormalizesPortraitLandscapeCropAndRotation() throws {
        for fixtureName in [
            "single-column-narrow-margins",
            "landscape-page",
            "crop-box-differs-media-box",
            "rotated-page-90"
        ] {
            guard let fixture = TestLayoutFixtureCatalog.byName[fixtureName] else {
                XCTFail("Missing fixture \(fixtureName)")
                continue
            }
            let document = try makeDocument(fixture)
            guard let page = document.page(at: 0) else {
                XCTFail("Missing page for \(fixtureName)")
                continue
            }
            let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
            XCTAssertFalse(fragments.isEmpty, fixtureName)
            assertNormalized(fragments, file: #filePath, line: #line)
        }
    }

    func testRotationMapsPageSpaceIntoVisualTopLeftCoordinates() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: ["Rotation geometry"])
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            return XCTFail("Could not create page")
        }
        let bounds = page.bounds(for: .mediaBox)
        let rawRect = CGRect(
            x: bounds.minX + bounds.width * 0.10,
            y: bounds.minY + bounds.height * 0.60,
            width: bounds.width * 0.20,
            height: bounds.height * 0.10
        )

        page.rotation = 0
        let zero = PdfLayoutGeometry.normalizedPageRect(rawRect, page: page)
        XCTAssertEqual(zero.minX, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(zero.minY, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(zero.width, 0.20, accuracy: 0.000_001)
        XCTAssertEqual(zero.height, 0.10, accuracy: 0.000_001)

        page.rotation = 90
        let ninety = PdfLayoutGeometry.normalizedPageRect(rawRect, page: page)
        XCTAssertEqual(ninety.minX, 0.60, accuracy: 0.000_001)
        XCTAssertEqual(ninety.minY, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(ninety.width, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(ninety.height, 0.20, accuracy: 0.000_001)
    }

    func testVisionGeometryConvertsLowerLeftToTopLeftCoordinates() {
        let source = CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.40)
        let converted = PdfLayoutGeometry.normalizedVisionRect(source)

        XCTAssertEqual(converted.minX, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(converted.minY, 0.40, accuracy: 0.000_001)
        XCTAssertEqual(converted.width, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(converted.height, 0.40, accuracy: 0.000_001)
    }

    func testOCRPreservesObservationTextConfidenceOrderAndGeometry() throws {
        let data = try TestPDFBuilder.scannedPDF(
            pages: ["OCR geometry observation should remain positioned and readable."]
        )
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            return XCTFail("Could not create scanned page")
        }

        let result = PdfOCREngine.recognize(
            page: page,
            configuration: PdfOCRConfiguration(
                mode: .always,
                recognitionLanguages: ["en-US"],
                automaticallyDetectsLanguage: false,
                recognitionLevel: .accurate,
                usesLanguageCorrection: false
            )
        )

        let unwrapped = try XCTUnwrap(result)
        XCTAssertFalse(unwrapped.observations.isEmpty)
        XCTAssertEqual(
            unwrapped.observations.map(\.sourceOrder),
            Array(0..<unwrapped.observations.count)
        )
        XCTAssertEqual(
            unwrapped.text,
            unwrapped.observations.map(\.text).joined(separator: "\n")
        )
        XCTAssertTrue(unwrapped.observations.allSatisfy { (0...1).contains($0.confidence) })

        let fragments = PdfPositionedTextExtractor.ocrFragments(from: unwrapped)
        XCTAssertEqual(fragments.map(\.source), Array(repeating: .ocr, count: fragments.count))
        assertNormalized(fragments)
    }

    func testDeduplicationRequiresBothSpatialAndTextSimilarity() {
        let base = PdfLayoutFragment(
            id: 0,
            text: "Alpha beta gamma",
            rect: CGRect(x: 0.10, y: 0.20, width: 0.40, height: 0.05),
            source: .ocr,
            confidence: 0.92,
            sourceOrder: 0
        )
        let overlappingNative = PdfLayoutFragment(
            id: 1,
            text: "Alpha beta gamna",
            rect: CGRect(x: 0.105, y: 0.202, width: 0.395, height: 0.048),
            source: .native,
            confidence: 1,
            sourceOrder: 1
        )
        let sameTextDifferentPosition = PdfLayoutFragment(
            id: 2,
            text: "Alpha beta gamma",
            rect: CGRect(x: 0.10, y: 0.55, width: 0.40, height: 0.05),
            source: .native,
            confidence: 1,
            sourceOrder: 2
        )
        let differentTextSamePosition = PdfLayoutFragment(
            id: 3,
            text: "Completely different content",
            rect: base.rect,
            source: .native,
            confidence: 1,
            sourceOrder: 3
        )

        let deduplicated = PdfPositionedTextExtractor.deduplicated([
            base,
            overlappingNative,
            sameTextDifferentPosition,
            differentTextSamePosition
        ])

        XCTAssertEqual(deduplicated.count, 3)
        XCTAssertTrue(deduplicated.contains { $0.id == overlappingNative.id && $0.source == .native })
        XCTAssertTrue(deduplicated.contains { $0.id == sameTextDifferentPosition.id })
        XCTAssertTrue(deduplicated.contains { $0.id == differentTextSamePosition.id })
    }

    func testNativeAndVisionCoordinateSystemsAgreeForEquivalentRectangles() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: ["Geometry sanity"])
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            return XCTFail("Could not create page")
        }
        let bounds = page.bounds(for: .mediaBox)

        // Same visual rectangle expressed once in PDF page space (bottom-left)
        // and once as a Vision normalized observation (bottom-left).
        let pdfRect = CGRect(
            x: bounds.minX + bounds.width * 0.20,
            y: bounds.minY + bounds.height * 0.55,
            width: bounds.width * 0.35,
            height: bounds.height * 0.08
        )
        let visionRect = CGRect(x: 0.20, y: 0.55, width: 0.35, height: 0.08)

        let native = PdfLayoutGeometry.normalizedPageRect(pdfRect, page: page)
        let vision = PdfLayoutGeometry.normalizedVisionRect(visionRect)

        XCTAssertEqual(native.minX, vision.minX, accuracy: 0.000_001)
        XCTAssertEqual(native.minY, vision.minY, accuracy: 0.000_001)
        XCTAssertEqual(native.width, vision.width, accuracy: 0.000_001)
        XCTAssertEqual(native.height, vision.height, accuracy: 0.000_001)
    }

    private func makeDocument(_ fixture: TestLayoutFixture) throws -> PDFDocument {
        let data = try TestPDFBuilder.layoutPDF(fixture)
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func assertNormalized(
        _ fragments: [PdfLayoutFragment],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for fragment in fragments {
            XCTAssertTrue(fragment.rect.minX.isFinite, file: file, line: line)
            XCTAssertTrue(fragment.rect.minY.isFinite, file: file, line: line)
            XCTAssertTrue(fragment.rect.width.isFinite, file: file, line: line)
            XCTAssertTrue(fragment.rect.height.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(fragment.rect.minX, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(fragment.rect.minY, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(fragment.rect.maxX, 1.000_001, file: file, line: line)
            XCTAssertLessThanOrEqual(fragment.rect.maxY, 1.000_001, file: file, line: line)
        }
    }
}
