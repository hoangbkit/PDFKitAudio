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

    func testPasswordProtectedPDFIsRejected() throws {
        let data = try TestPDFBuilder.encryptedPDF(pages: ["Protected content"])

        XCTAssertThrowsError(try PdfParser(ocrMode: .never).parse(data: data)) { error in
            guard case PdfError.passwordProtected = error else {
                return XCTFail("Expected passwordProtected, got \(error)")
            }
        }
    }

    func testBlankContentDocumentDoesNotCrash() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: [""])
        let book = try PdfParser(ocrMode: .never).parse(data: data)

        XCTAssertEqual(book.metadata.pageCount, 1)
        XCTAssertEqual(book.pages.count, 1)
        XCTAssertEqual(book.pages.first?.pageIndex, 0)
        XCTAssertEqual(book.pages.first?.extractionSource, .empty)
        XCTAssertEqual(book.totalWords, 0)
    }

    func testParsesDigitalPDFMetadataTextAndPageProvenance() throws {
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
        XCTAssertEqual(book.pages.count, 2)
        XCTAssertEqual(book.pages.map(\.pageIndex), [0, 1])
        XCTAssertEqual(book.pages.map(\.id), [0, 1])
        XCTAssertEqual(book.pages.map(\.extractionSource), [.native, .native])
        XCTAssertTrue(book.pages[0].nativeText.contains("Chapter 1"))
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

    func testMixedDocumentContainsBothNativeAndImageOnlyPages() throws {
        let data = try TestPDFBuilder.mixedPDF(
            digitalText: "This page contains enough selectable native text to be extracted without OCR and acts as the digital half of the mixed fixture.",
            scannedText: "This is an image-only scanned page"
        )
        guard let document = PDFDocument(data: data) else {
            return XCTFail("Expected generated PDF to load")
        }

        XCTAssertEqual(document.pageCount, 2)
        XCTAssertFalse((document.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue((document.page(at: 1)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testMixedDocumentPreservesIndexesWhenOCRIsDisabled() throws {
        let data = try TestPDFBuilder.mixedPDF(
            digitalText: "This is a sufficiently long native page used to prove source index zero remains native without triggering OCR.",
            scannedText: "Image only second page"
        )

        let book = try PdfParser(ocrMode: .never).parse(data: data)

        XCTAssertEqual(book.metadata.pageCount, 2)
        XCTAssertEqual(book.pages.count, 2)
        XCTAssertEqual(book.pages.map(\.pageIndex), [0, 1])
        XCTAssertEqual(book.pages[0].extractionSource, .native)
        XCTAssertEqual(book.pages[1].extractionSource, .empty)
        XCTAssertEqual(book.emptyPageCount, 1)
        XCTAssertEqual(book.ocrPageCount, 0)
    }

    func testAutomaticOCRRecordsActualOCRPageWithoutShiftingIndexes() throws {
        let data = try TestPDFBuilder.mixedPDF(
            digitalText: "This selectable native page intentionally contains enough text to remain on the fast native extraction path without OCR.",
            scannedText: "Scanned source page two for OCR provenance"
        )

        let book = try PdfParser(ocrMode: .auto).parse(data: data)

        XCTAssertEqual(book.pages.map(\.pageIndex), [0, 1])
        XCTAssertEqual(book.pages[0].extractionSource, .native)
        XCTAssertEqual(book.pages[1].extractionSource, .ocr)
        XCTAssertEqual(book.ocrPageCount, 1)
        XCTAssertFalse(book.pages[1].text.isEmpty)
        XCTAssertTrue(book.pages[1].text.localizedCaseInsensitiveContains("scanned"))
    }

    func testEmptyMiddlePageDoesNotShiftLaterSourceIndexes() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: [
            "First source page with meaningful text.",
            "",
            "Third source page must remain source page index two."
        ])

        let book = try PdfParser(ocrMode: .never).parse(data: data)

        XCTAssertEqual(book.pages.count, 3)
        XCTAssertEqual(book.pages.map(\.pageIndex), [0, 1, 2])
        XCTAssertEqual(book.pages.map(\.extractionSource), [.native, .empty, .native])
        XCTAssertTrue(book.pages[2].text.contains("Third source page"))
    }

    func testParserCreatesFallbackChapterWhenNoTOCExists() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: ["A document without an outline but with enough text to form a fallback chapter."])
        let book = try PdfParser(ocrMode: .never).parse(data: data)

        XCTAssertFalse(book.chapters.isEmpty)
        XCTAssertEqual(book.chapters.first?.pageRange, 0...0)
        XCTAssertFalse(book.chapters.first?.plainText.isEmpty ?? true)
    }

    func testFallbackChapterRangeMatchesUnderlyingPages() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: [
            "First page of a chapter without explicit headings.",
            "Second page of the same fallback chapter.",
            "Third page remains in the same fallback chapter."
        ])
        let book = try PdfParser(ocrMode: .never).parse(data: data)

        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertEqual(book.chapters[0].pageRange, 0...2)
    }

    func testAllPlainTextContainsEachCanonicalPageExactlyOnce() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: [
            "UNIQUE_ALPHA source page text.",
            "UNIQUE_BETA source page text.",
            "UNIQUE_GAMMA source page text."
        ])
        let book = try PdfParser(ocrMode: .never).parse(data: data)
        let text = book.allPlainText()

        XCTAssertEqual(occurrences(of: "UNIQUE_ALPHA", in: text), 1)
        XCTAssertEqual(occurrences(of: "UNIQUE_BETA", in: text), 1)
        XCTAssertEqual(occurrences(of: "UNIQUE_GAMMA", in: text), 1)
    }

    func testAudiobookScriptPreservesTextOrder() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: [
            "First sentence that is long enough to become useful spoken content. Second sentence that follows it in order. Third sentence remains last."
        ])
        let book = try PdfParser(ocrMode: .never).parse(data: data)
        let segments = book.audiobookScript(maxCharsPerSegment: 80)

        XCTAssertFalse(segments.isEmpty)
        XCTAssertEqual(segments.map(\.order), Array(0..<segments.count))
        XCTAssertEqual(normalizedWhitespace(segments.map(\.text).joined(separator: " ")), normalizedWhitespace(book.allPlainText()))
    }

    func testAudiobookSegmentsCarryActualSourcePageRanges() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: [
            "First page spoken content stays associated with source page zero.",
            "Second page spoken content stays associated with source page one."
        ])
        let book = try PdfParser(ocrMode: .never).parse(data: data)
        let segments = book.audiobookScript(maxCharsPerSegment: 2_000)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.sourcePageRange), [0...0, 1...1])
        XCTAssertEqual(segments.map(\.pageIndex), [0, 1])
        XCTAssertEqual(
            normalizedWhitespace(segments.map(\.text).joined(separator: " ")),
            normalizedWhitespace(book.allPlainText())
        )
    }

    private func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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
