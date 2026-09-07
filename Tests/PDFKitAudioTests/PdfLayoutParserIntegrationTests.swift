import Foundation
import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfLayoutParserIntegrationTests: XCTestCase {
    func testNeverModePreservesLegacySelectedTextForComplexPage() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["two-column-symmetric"])
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let raw = try XCTUnwrap(document.page(at: 0)?.string)
        let expected = PdfTextCleaner.cleanPage(raw, configuration: .minimal)

        let parser = makeParser(layoutMode: .never)
        let book = try parser.parse(data: data)

        XCTAssertEqual(book.pages.count, 1)
        XCTAssertEqual(book.pages[0].text, expected)
        XCTAssertEqual(book.pages[0].extractionSource, .native)
    }

    func testAutoModeKeepsSimplePageByteEquivalentToNeverMode() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["single-column-wide-margins"])
        let data = try TestPDFBuilder.layoutPDF(fixture)

        let legacy = try makeParser(layoutMode: .never).parse(data: data)
        let automatic = try makeParser(layoutMode: .auto).parse(data: data)

        XCTAssertEqual(automatic.pages, legacy.pages)
        XCTAssertEqual(automatic.allPlainText(), legacy.allPlainText())
    }

    func testAutoModeUsesLayoutOrderForSupportedTwoColumnPage() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["two-column-symmetric"])
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let book = try makeParser(layoutMode: .auto).parse(data: data)
        let page = try XCTUnwrap(book.pages.first)

        XCTAssertEqual(
            TestLayoutBaselineScorer.orderedMarkers(
                expectedMarkers: fixture.expectedMarkerOrder,
                in: page.text
            ),
            fixture.expectedMarkerOrder
        )
        let score = TestLayoutBaselineScorer.score(
            expectedMarkers: fixture.expectedMarkerOrder,
            in: page.text
        )
        XCTAssertEqual(score.coverage, 1)
        XCTAssertEqual(score.pairwiseAccuracy, 1)
        XCTAssertEqual(score.duplicateMarkerCount, 0)
        XCTAssertEqual(page.extractionSource, .native)
        XCTAssertEqual(page.pageIndex, 0)
    }

    func testAlwaysModeAttemptsSupportedSimplePageThroughAnalyzer() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["single-column-wide-margins"])
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)

        let result = try PdfLayoutAnalyzer.analyze(
            fragments: fragments,
            nativeText: page.string ?? "",
            nativeTextThreshold: 20,
            pageIndex: 0,
            mode: .always
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(
            TestLayoutBaselineScorer.orderedMarkers(
                expectedMarkers: fixture.expectedMarkerOrder,
                in: result?.text ?? ""
            ),
            fixture.expectedMarkerOrder
        )
    }

    func testAnalyzerRejectsUnsafeDuplicateFragmentIdentity() throws {
        let duplicateID = [
            PdfLayoutFragment(
                id: 7,
                text: "LEFT safe text",
                rect: CGRect(x: 0.08, y: 0.12, width: 0.36, height: 0.05),
                source: .native,
                confidence: 1,
                sourceOrder: 0
            ),
            PdfLayoutFragment(
                id: 7,
                text: "RIGHT different text",
                rect: CGRect(x: 0.56, y: 0.12, width: 0.36, height: 0.05),
                source: .native,
                confidence: 1,
                sourceOrder: 1
            )
        ]

        let result = try PdfLayoutAnalyzer.analyze(
            fragments: duplicateID,
            nativeText: "LEFT safe text\nRIGHT different text",
            nativeTextThreshold: 20,
            pageIndex: 0,
            mode: .always
        )

        XCTAssertNil(result)
    }

    func testMixedNativeAndScannedComplexPagesPreserveSourceProvenanceAndOrder() throws {
        let nativeBoxes = columnBoxes(prefix: "N")
        let scannedBoxes = columnBoxes(prefix: "S")
        let fixture = TestLayoutFixture(
            name: "phase8-mixed-native-scanned-columns",
            category: "phase8",
            support: .supported,
            pages: [
                TestLayoutPage(rendering: .native, boxes: nativeBoxes),
                TestLayoutPage(rendering: .scanned, boxes: scannedBoxes)
            ],
            expectedMarkerOrder: expectedColumnOrder(prefix: "N") + expectedColumnOrder(prefix: "S"),
            notes: "Phase 8 parser integration fixture"
        )
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let scannedObservations = scannedBoxes.enumerated().map { index, box in
            PdfOCREngine.OCRObservation(
                text: box.text,
                rect: box.rect,
                confidence: 1,
                sourceOrder: index
            )
        }
        let ocrText = scannedObservations.map(\.text).joined(separator: "\n")
        let parser = PdfParser(
            ocrConfiguration: PdfOCRConfiguration(mode: .auto),
            cleanupConfiguration: .minimal,
            extractCoverImage: false,
            layoutConfiguration: PdfLayoutConfiguration(mode: .auto),
            ocrRecognizer: { _, _ in
                PdfOCREngine.OCRResult(
                    text: ocrText,
                    confidence: 1,
                    observations: scannedObservations
                )
            }
        )

        let book = try parser.parse(data: data)

        XCTAssertEqual(book.pages.map(\.pageIndex), [0, 1])
        XCTAssertEqual(book.pages.map(\.extractionSource), [.native, .ocr])
        XCTAssertEqual(
            TestLayoutBaselineScorer.orderedMarkers(
                expectedMarkers: expectedColumnOrder(prefix: "N"),
                in: book.pages[0].text
            ),
            expectedColumnOrder(prefix: "N")
        )
        XCTAssertEqual(
            TestLayoutBaselineScorer.orderedMarkers(
                expectedMarkers: expectedColumnOrder(prefix: "S"),
                in: book.pages[1].text
            ),
            expectedColumnOrder(prefix: "S")
        )
        XCTAssertTrue(book.pages[0].nativeText.contains("N_L1"))
        XCTAssertTrue(book.pages[1].nativeText.isEmpty)
        XCTAssertEqual(book.pages[1].confidence, 1)
    }

    func testLayoutAnalyzerHonorsCancellationCheckpoints() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["two-column-symmetric"])
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let fragments = PdfPositionedTextExtractor.nativeFragments(page: page)
        var checkpoints = 0

        do {
            _ = try PdfLayoutAnalyzer.analyze(
                fragments: fragments,
                nativeText: page.string ?? "",
                nativeTextThreshold: 20,
                pageIndex: 0,
                mode: .always,
                checkpoint: {
                    checkpoints += 1
                    if checkpoints == 2 {
                        throw CancellationError()
                    }
                }
            )
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            XCTAssertEqual(checkpoints, 2)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testComplexLayoutProgressRemainsMonotonicWithoutNewPublicStage() async throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["two-column-symmetric"])
            .repeatedPages(3, name: "phase8-progress-columns")
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let recorder = Phase8ProgressRecorder()
        let parser = makeParser(layoutMode: .auto)

        _ = try await parser.parse(data: data) { progress in
            recorder.append(progress)
        }

        let snapshots = recorder.snapshots
        let extraction = snapshots.filter { $0.stage == .extracting }
        XCTAssertEqual(extraction.map(\.completedPages), [0, 1, 2, 3])
        XCTAssertTrue(extraction.allSatisfy { $0.totalPages == 3 })
        XCTAssertEqual(snapshots.last?.stage, .finished)
        XCTAssertTrue(snapshots.contains { $0.stage == .cleaning })
        XCTAssertTrue(snapshots.contains { $0.stage == .buildingChapters })
    }

    func testAsyncCancellationStopsBetweenLargeComplexPageUnits() async throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["two-column-symmetric"])
            .repeatedPages(24, name: "phase8-cancellation-columns")
        let data = try TestPDFBuilder.layoutPDF(fixture)
        let gate = Phase8CancellationGate()
        let parser = makeParser(layoutMode: .auto)

        let task = Task {
            try await parser.parse(data: data) { progress in
                gate.handle(progress)
            }
        }

        await fulfillment(of: [gate.reachedFirstPage], timeout: 5)
        task.cancel()
        gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected at the checkpoint before the next page-sized unit.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func makeParser(layoutMode: PdfLayoutMode) -> PdfParser {
        PdfParser(configuration: PdfParserConfiguration(
            ocr: PdfOCRConfiguration(mode: .never),
            layout: PdfLayoutConfiguration(mode: layoutMode),
            cleanup: .minimal,
            extractCoverImage: false
        ))
    }

    private func columnBoxes(prefix: String) -> [TestLayoutTextBox] {
        [
            TestLayoutTextBox("\(prefix)_L1", x: 0.08, y: 0.12, width: 0.36, height: 0.05),
            TestLayoutTextBox("\(prefix)_R1", x: 0.56, y: 0.12, width: 0.36, height: 0.05),
            TestLayoutTextBox("\(prefix)_L2", x: 0.08, y: 0.24, width: 0.36, height: 0.05),
            TestLayoutTextBox("\(prefix)_R2", x: 0.56, y: 0.24, width: 0.36, height: 0.05),
            TestLayoutTextBox("\(prefix)_L3", x: 0.08, y: 0.36, width: 0.36, height: 0.05),
            TestLayoutTextBox("\(prefix)_R3", x: 0.56, y: 0.36, width: 0.36, height: 0.05)
        ]
    }

    private func expectedColumnOrder(prefix: String) -> [String] {
        ["\(prefix)_L1", "\(prefix)_L2", "\(prefix)_L3", "\(prefix)_R1", "\(prefix)_R2", "\(prefix)_R3"]
    }
}

private final class Phase8ProgressRecorder: @unchecked Sendable {
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

private final class Phase8CancellationGate: @unchecked Sendable {
    let reachedFirstPage = XCTestExpectation(description: "first complex page completed")
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasBlocked = false

    func handle(_ progress: PdfParseProgress) {
        guard progress.stage == .extracting, progress.completedPages == 1 else { return }

        lock.lock()
        let shouldBlock = !hasBlocked
        hasBlocked = true
        lock.unlock()
        guard shouldBlock else { return }

        reachedFirstPage.fulfill()
        _ = semaphore.wait(timeout: .now() + 5)
    }

    func release() {
        semaphore.signal()
    }
}
