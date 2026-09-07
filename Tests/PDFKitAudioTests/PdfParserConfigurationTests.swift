import XCTest
@testable import PDFKitAudio

final class PdfParserConfigurationTests: XCTestCase {
    func testConsolidatedConfigurationPropagatesToParser() {
        let configuration = PdfParserConfiguration(
            ocr: PdfOCRConfiguration(
                mode: .never,
                nativeTextThreshold: 123,
                recognitionLanguages: ["vi-VN"]
            ),
            cleanup: .minimal,
            extractCoverImage: false,
            retainNativeText: false
        )
        let parser = PdfParser(configuration: configuration)

        XCTAssertEqual(parser.configuration, configuration)
        XCTAssertEqual(parser.ocrConfiguration, configuration.ocr)
        XCTAssertEqual(parser.cleanupConfiguration, configuration.cleanup)
        XCTAssertFalse(parser.extractCoverImage)
        XCTAssertFalse(parser.retainNativeText)
    }

    func testLegacyInitializerStillMapsToConsolidatedConfiguration() {
        let parser = PdfParser(
            ocrMode: .never,
            ocrThreshold: 77,
            cleanupConfiguration: .minimal,
            extractCoverImage: false
        )

        XCTAssertEqual(parser.configuration.ocr.mode, .never)
        XCTAssertEqual(parser.configuration.ocr.nativeTextThreshold, 77)
        XCTAssertEqual(parser.configuration.cleanup, .minimal)
        XCTAssertFalse(parser.configuration.extractCoverImage)
        XCTAssertTrue(parser.configuration.retainNativeText)
    }

    func testNativeTextCanBeDroppedWithoutChangingSelectedText() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: [
            "This digital source page has enough native text to remain on the PDFKit fast path and prove that diagnostic retention is optional."
        ])
        let parser = PdfParser(configuration: PdfParserConfiguration(
            ocr: PdfOCRConfiguration(mode: .never),
            extractCoverImage: false,
            retainNativeText: false
        ))

        let book = try parser.parse(data: data)

        XCTAssertEqual(book.pages.count, 1)
        XCTAssertEqual(book.pages[0].nativeText, "")
        XCTAssertEqual(book.pages[0].extractionSource, .native)
        XCTAssertTrue(book.pages[0].text.contains("digital source page"))
        XCTAssertFalse(book.metadata.isScanned)
    }
}
