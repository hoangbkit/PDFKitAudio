import Foundation
import XCTest
@testable import PDFKitAudio

final class PdfAsyncParserTests: XCTestCase {
    func testAsyncParseMatchesSynchronousParse() async throws {
        let data = try TestPDFBuilder.digitalPDF(pages: [
            "First source page with enough text to exercise the native extraction path.",
            "Second source page remains in deterministic document order.",
            "Third source page completes the async equivalence fixture."
        ])
        let parser = PdfParser(ocrMode: .never, extractCoverImage: false)

        let synchronousBook = try parser.parse(data: data)
        let asynchronousBook = try await parser.parse(data: data)

        XCTAssertEqual(asynchronousBook.metadata.pageCount, synchronousBook.metadata.pageCount)
        XCTAssertEqual(asynchronousBook.metadata.isScanned, synchronousBook.metadata.isScanned)
        XCTAssertEqual(asynchronousBook.pages, synchronousBook.pages)
        XCTAssertEqual(asynchronousBook.chapters, synchronousBook.chapters)
        XCTAssertEqual(asynchronousBook.allPlainText(), synchronousBook.allPlainText())
    }

    func testAsyncProgressReportsMonotonicPageExtractionAndDocumentStages() async throws {
        let data = try TestPDFBuilder.digitalPDF(pages: [
            "Page one contains ordinary native PDF text.",
            "Page two contains ordinary native PDF text.",
            "Page three contains ordinary native PDF text."
        ])
        let recorder = ProgressRecorder()
        let parser = PdfParser(ocrMode: .never, extractCoverImage: false)

        _ = try await parser.parse(data: data) { progress in
            recorder.append(progress)
        }

        let snapshots = recorder.snapshots
        XCTAssertEqual(snapshots.first?.stage, .loading)
        XCTAssertEqual(snapshots.last, PdfParseProgress(
            stage: .finished,
            completedPages: 3,
            totalPages: 3
        ))

        let extraction = snapshots.filter { $0.stage == .extracting }
        XCTAssertEqual(extraction.map(\.completedPages), [0, 1, 2, 3])
        XCTAssertTrue(extraction.allSatisfy { $0.totalPages == 3 })
        XCTAssertEqual(extraction.last?.pageFractionCompleted, 1)

        XCTAssertTrue(snapshots.contains { $0.stage == .cleaning })
        XCTAssertTrue(snapshots.contains { $0.stage == .buildingChapters })
        XCTAssertTrue(snapshots.contains { $0.stage == .finishing })
    }

    func testAsyncCancellationPropagatesAfterCurrentOCRPageFinishes() async throws {
        let recognizerStarted = DispatchSemaphore(value: 0)
        let allowRecognizerToFinish = DispatchSemaphore(value: 0)
        let parser = PdfParser(
            ocrConfiguration: PdfOCRConfiguration(mode: .always),
            extractCoverImage: false,
            ocrRecognizer: { _, _ in
                recognizerStarted.signal()
                _ = allowRecognizerToFinish.wait(timeout: .now() + 5)
                return PdfOCREngine.OCRResult(
                    text: "OCR result that should be discarded after cancellation.",
                    confidence: 1
                )
            }
        )
        let data = try TestPDFBuilder.digitalPDF(pages: [
            "Native page text that deliberately enters OCR because the parser is in always mode."
        ])

        let task = Task {
            try await parser.parse(data: data)
        }

        let started = recognizerStarted.wait(timeout: .now() + 5)
        guard started == .success else {
            task.cancel()
            allowRecognizerToFinish.signal()
            return XCTFail("Timed out waiting for the OCR recognizer to start")
        }

        task.cancel()
        allowRecognizerToFinish.signal()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected: cancellation is checked immediately after the current
            // synchronous Vision-sized OCR unit returns.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testCoverExtractionCanBeDisabled() throws {
        let data = try TestPDFBuilder.digitalPDF(pages: ["Cover source page"])
        let parser = PdfParser(ocrMode: .never, extractCoverImage: false)

        let book = try parser.parse(data: data)

        XCTAssertNil(book.coverImageData)
    }

    func testParseProgressClampsInvalidPageCounts() {
        let unknownTotal = PdfParseProgress(
            stage: .loading,
            completedPages: 10,
            totalPages: -1
        )
        XCTAssertEqual(unknownTotal.completedPages, 0)
        XCTAssertEqual(unknownTotal.totalPages, 0)
        XCTAssertNil(unknownTotal.pageFractionCompleted)

        let bounded = PdfParseProgress(
            stage: .extracting,
            completedPages: 20,
            totalPages: 4
        )
        XCTAssertEqual(bounded.completedPages, 4)
        XCTAssertEqual(bounded.pageFractionCompleted, 1)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PdfParseProgress] = []

    var snapshots: [PdfParseProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ progress: PdfParseProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}
