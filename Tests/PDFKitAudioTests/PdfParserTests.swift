import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfParserTests: XCTestCase {
    func testParseDataRejectsInvalidPDF() {
        let parser = PdfParser(ocrMode: .never)

        XCTAssertThrowsError(try parser.parse(data: Data("not a pdf".utf8))) { error in
            guard case PdfError.invalidPDF = error else {
                return XCTFail("Expected invalidPDF, got \(error)")
            }
        }
    }

    func testParseURLRejectsMissingFile() {
        let parser = PdfParser(ocrMode: .never)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        XCTAssertThrowsError(try parser.parse(at: url)) { error in
            guard case PdfError.fileNotFound = error else {
                return XCTFail("Expected fileNotFound, got \(error)")
            }
        }
    }

    func testParsesDigitalPDFMetadataAndText() throws {
        let data = try TestPDFBuilder.digitalPDF(
            pages: [
                "Chapter 1\nA first page with enough native text to avoid OCR in normal use.",
                "A second page that should remain in document order."
            ],
            title: "Regression Fixture",
            author: "Fixture Author"
        )

        let book = try PdfParser(ocrMode: .never).parse(data: data)

        XCTAssertEqual(book.metadata.title, "Regression Fixture")
        XCTAssertEqual(book.metadata.authors, ["Fixture Author"])
        XCTAssertEqual(book.metadata.pageCount, 2)
        XCTAssertTrue(book.allPlainText().contains("Chapter 1"))
        XCTAssertTrue(book.allPlainText().contains("second page"))
    }

    func testFileURLBecomesFallbackTitleWhenMetadataTitleMissing() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: ["Some extractable text."], title: nil)
        let url = try TestPDFBuilder.temporaryFile(data: data, name: "Fallback Book Title")
        defer { try? FileManager.default.removeItem(at: url) }

        let book = try PdfParser(ocrMode: .never).parse(at: url)

        XCTAssertEqual(book.metadata.title, "Fallback Book Title")
    }

    func testScannedDocumentDetectionUsesMissingNativeText() throws {
        let data = try TestPDFBuilder.scannedPDF(
            pages: ["Scanned fixture page one", "Scanned fixture page two"]
        )
        guard let document = PDFDocument(data: data) else {
            return XCTFail("Expected generated PDF to load")
        }

        XCTAssertTrue(PdfOCREngine.isScanned(document: document))
    }

    func testMixedDocumentKeepsNativePageAndMarksDocumentScannedAccordingToSamplingRule() throws {
        let data = try TestPDFBuilder.mixedPDF(
            digitalText: "This page contains enough selectable native text to be extracted without OCR and acts as the digital half of the mixed fixture.",
            scannedText: "This is an image-only scanned page"
        )
        guard let document = PDFDocument(data: data) else {
            return XCTFail("Expected generated PDF to load")
        }

        XCTAssertEqual(document.pageCount, 2)
        XCTAssertNotNil(document.page(at: 0)?.string)
        XCTAssertTrue((document.page(at: 1)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testParserCreatesFallbackChapterWhenNoTOCExists() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: ["A document without an outline but with enough text to form a fallback chapter."])
        let book = try PdfParser(ocrMode: .never).parse(data: data)

        XCTAssertFalse(book.chapters.isEmpty)
        XCTAssertEqual(book.chapters.first?.pageRange, 0...0)
        XCTAssertFalse(book.chapters.first?.plainText.isEmpty ?? true)
    }

    func testAudiobookScriptPreservesTextOrder() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: [
            "First sentence that is long enough to become useful spoken content. Second sentence that follows it in order. Third sentence remains last."
        ])
        let book = try PdfParser(ocrMode: .never).parse(data: data)
        let segments = book.audiobookScript(maxCharsPerSegment: 80)

        XCTAssertFalse(segments.isEmpty)
        XCTAssertEqual(segments.map(\.order), Array(0..<segments.count))
        XCTAssertEqual(
            segments.map(\.text).joined(separator: " "),
            book.allPlainText().replacingOccurrences(of: "\n\n", with: " ")
        )
    }
}
