import Foundation
import PDFKit
import Vision
import XCTest
@testable import PDFKitAudio

final class PdfOCRTests: XCTestCase {
    func testConfigurationNormalizesThresholdAndLanguages() {
        let configuration = PdfOCRConfiguration(
            nativeTextThreshold: -10,
            recognitionLanguages: [" vi-VN ", "fr-FR", "VI-vn", ""]
        )

        XCTAssertEqual(configuration.nativeTextThreshold, 0)
        XCTAssertEqual(configuration.recognitionLanguages, ["vi-VN", "fr-FR"])
    }

    func testDefaultConfigurationUsesConservativeNativeTextThreshold() {
        XCTAssertEqual(PdfOCRConfiguration().nativeTextThreshold, 20)
        XCTAssertEqual(PdfParser().ocrConfiguration.nativeTextThreshold, 20)
    }

    func testDefaultRequestUsesAutomaticLanguageDetectionWithoutPackageEnglishOverride() {
        let configuration = PdfOCRConfiguration()
        let request = PdfOCREngine.makeRequest(configuration: configuration)

        XCTAssertTrue(request.automaticallyDetectsLanguage)
        XCTAssertEqual(request.recognitionLevel, .accurate)
        XCTAssertTrue(request.usesLanguageCorrection)
        XCTAssertTrue(configuration.recognitionLanguages.isEmpty)
    }

    func testExplicitRecognitionLanguagesPropagateToVisionRequest() {
        let configuration = PdfOCRConfiguration(
            recognitionLanguages: ["vi-VN", "fr-FR"],
            automaticallyDetectsLanguage: false,
            recognitionLevel: .fast,
            usesLanguageCorrection: false
        )
        let request = PdfOCREngine.makeRequest(configuration: configuration)

        XCTAssertEqual(request.recognitionLanguages, ["vi-VN", "fr-FR"])
        XCTAssertFalse(request.automaticallyDetectsLanguage)
        XCTAssertEqual(request.recognitionLevel, .fast)
        XCTAssertFalse(request.usesLanguageCorrection)
    }

    func testAutoPolicySkipsStrongNativeText() {
        let configuration = PdfOCRConfiguration(mode: .auto, nativeTextThreshold: 60)
        let text = "This is a healthy native PDF paragraph with enough readable alphanumeric content to remain on the fast path."

        XCTAssertEqual(PdfOCRPolicy.quality(of: text, threshold: 60), .usable)
        XCTAssertFalse(PdfOCRPolicy.shouldRunOCR(nativeText: text, configuration: configuration))
    }

    func testDefaultAutoModeSkipsShortHealthyDigitalPageLikeDemoFixture() throws {
        let attempts = LockedCounter()
        let parser = PdfParser(
            ocrConfiguration: PdfOCRConfiguration(mode: .auto),
            ocrRecognizer: { _, _ in
                attempts.increment()
                return PdfOCREngine.OCRResult(text: "Unexpected OCR", confidence: 1)
            }
        )
        let data = try TestPDFBuilder.digitalPDF(pages: [
            "Chapter One\nChapter one body text for outline parsing."
        ])

        let book = try parser.parse(data: data)

        XCTAssertEqual(attempts.value, 0)
        XCTAssertEqual(book.pages.first?.extractionSource, .native)
        XCTAssertTrue(book.pages.first?.text.contains("Chapter one body text") ?? false)
    }

    func testAutoPolicyTriggersForEmptyShortAndSuspiciousNativeText() {
        let configuration = PdfOCRConfiguration(mode: .auto, nativeTextThreshold: 60)
        let suspicious = String(repeating: "\u{FFFD}", count: 20) + "@@@@@@"

        XCTAssertTrue(PdfOCRPolicy.shouldRunOCR(nativeText: "", configuration: configuration))
        XCTAssertTrue(PdfOCRPolicy.shouldRunOCR(nativeText: "Short text", configuration: configuration))
        XCTAssertTrue(PdfOCRPolicy.shouldRunOCR(nativeText: suspicious, configuration: configuration))
    }

    func testNeverModeDoesNotInvokeOCRRecognizer() throws {
        let attempts = LockedCounter()
        let parser = PdfParser(
            ocrConfiguration: PdfOCRConfiguration(mode: .never),
            ocrRecognizer: { _, _ in
                attempts.increment()
                return PdfOCREngine.OCRResult(text: "Should not run", confidence: 1)
            }
        )
        let data = try TestPDFBuilder.scannedPDF(pages: ["Image-only source"])

        let book = try parser.parse(data: data)

        XCTAssertEqual(attempts.value, 0)
        XCTAssertEqual(book.pages.first?.extractionSource, .empty)
    }

    func testAutoModeDoesNotInvokeOCRForStrongNativePage() throws {
        let attempts = LockedCounter()
        let parser = PdfParser(
            ocrConfiguration: PdfOCRConfiguration(mode: .auto, nativeTextThreshold: 60),
            ocrRecognizer: { _, _ in
                attempts.increment()
                return PdfOCREngine.OCRResult(text: "Unexpected OCR", confidence: 1)
            }
        )
        let data = try TestPDFBuilder.digitalPDF(pages: [
            "This native PDF page contains enough normal text to prove that automatic mode performs no OCR work on a healthy digital page."
        ])

        let book = try parser.parse(data: data)

        XCTAssertEqual(attempts.value, 0)
        XCTAssertEqual(book.pages.first?.extractionSource, .native)
    }

    func testAlwaysModeAttemptsOCRButKeepsBetterNativeText() throws {
        let attempts = LockedCounter()
        let nativeText = "This is strong native text that should remain selected even when always mode asks the OCR engine to evaluate the page."
        let parser = PdfParser(
            ocrConfiguration: PdfOCRConfiguration(mode: .always),
            ocrRecognizer: { _, _ in
                attempts.increment()
                return PdfOCREngine.OCRResult(text: "bad", confidence: 0.05)
            }
        )
        let data = try TestPDFBuilder.digitalPDF(pages: [nativeText])

        let book = try parser.parse(data: data)

        XCTAssertEqual(attempts.value, 1)
        XCTAssertEqual(book.pages.first?.extractionSource, .native)
        XCTAssertTrue(book.pages.first?.text.contains("strong native text") ?? false)
    }

    func testOCRWinsWhenNativeTextIsMissingAndResultIsUsable() {
        let configuration = PdfOCRConfiguration(mode: .auto)

        XCTAssertTrue(PdfOCRPolicy.shouldPreferOCR(
            ocrText: "Recovered text from the scanned page",
            confidence: 0.85,
            nativeText: "",
            configuration: configuration
        ))
    }

    func testWeakOCRDoesNotReplaceUsableNativeText() {
        let configuration = PdfOCRConfiguration(mode: .always)
        let native = "A long, clean native paragraph with enough useful content that it should remain authoritative for speech output."

        XCTAssertFalse(PdfOCRPolicy.shouldPreferOCR(
            ocrText: "short OCR",
            confidence: 0.95,
            nativeText: native,
            configuration: configuration
        ))
    }

    func testExplicitFrenchOCRRecognizesScannedText() throws {
        let data = try TestPDFBuilder.scannedPDF(pages: [
            "Bonjour le monde. Ceci est une page numérisée en français."
        ])
        let parser = PdfParser(ocrConfiguration: PdfOCRConfiguration(
            mode: .always,
            recognitionLanguages: ["fr-FR"],
            automaticallyDetectsLanguage: false
        ))

        let book = try parser.parse(data: data)

        XCTAssertEqual(book.pages.first?.extractionSource, .ocr)
        XCTAssertTrue(book.pages.first?.text.localizedCaseInsensitiveContains("Bonjour") ?? false)
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
