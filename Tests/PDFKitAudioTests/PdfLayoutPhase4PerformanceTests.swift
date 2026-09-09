import Darwin
import Foundation
import XCTest
@testable import PDFKitAudio

/// Reproducible measurements, not noisy wall-clock assertions in ordinary CI.
/// Run alone with swift test --filter PdfLayoutPhase4PerformanceTests.
final class PdfLayoutPhase4PerformanceTests: XCTestCase {
    func testControlledSimpleLegacyVersusAutomaticPerformance() throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["single-column-narrow-margins"])
        let data = try TestPDFBuilder.repeatedLayoutPDF(fixture, pageCount: 100)
        var legacy: [Double] = [], automatic: [Double] = []
        for round in 0..<6 {
            for mode in (round.isMultiple(of: 2) ? [PdfLayoutMode.never, .auto] : [.auto, .never]) {
                let elapsed = try autoreleasepool {
                    let start = CFAbsoluteTimeGetCurrent()
                    let book = try parser(mode).parse(data: data)
                    XCTAssertEqual(book.pages.count, 100)
                    XCTAssertEqual(book.ocrPageCount, 0)
                    return CFAbsoluteTimeGetCurrent() - start
                }
                if round > 0 {
                    if mode == .never { legacy.append(elapsed) } else { automatic.append(elapsed) }
                }
            }
        }
        let baseline = legacy.sorted()[legacy.count / 2]
        let current = automatic.sorted()[automatic.count / 2]
        print("PHASE4_PERFORMANCE pages=100 legacyMedian=\(baseline) autoMedian=\(current) ratio=\(current / baseline) target=1.15 targetMet=\(current <= baseline * 1.15)")
    }

    func testFiveHundredComplexPagesCompleteWithBoundedTransientMemory() async throws {
        let fixture = try XCTUnwrap(TestLayoutFixtureCatalog.byName["two-column-symmetric"])
        let data = try TestPDFBuilder.repeatedLayoutPDF(fixture, pageCount: 500)
        let legacySamples = MemorySamples()
        do {
            let legacy = try await parser(.never).parse(data: data) { progress in
                if progress.stage == .extracting && progress.completedPages.isMultiple(of: 50) {
                    legacySamples.record(progress.completedPages)
                }
            }
            XCTAssertEqual(legacy.pages.count, 500)
        }
        let samples = MemorySamples()
        let start = CFAbsoluteTimeGetCurrent()
        let book = try await parser(.auto).parse(data: data) { progress in
            if progress.stage == .extracting && progress.completedPages.isMultiple(of: 50) {
                samples.record(progress.completedPages)
            }
        }
        XCTAssertEqual(book.pages.count, 500)
        XCTAssertEqual(book.ocrPageCount, 0)
        for page in book.pages {
            let score = TestLayoutBaselineScorer.score(expectedMarkers: fixture.expectedMarkerOrder, in: page.text)
            XCTAssertEqual(score.coverage, 1)
            XCTAssertEqual(score.pairwiseAccuracy, 1)
            XCTAssertEqual(score.duplicateMarkerCount, 0)
        }
        print("PHASE4_STRESS pages=500 seconds=\(CFAbsoluteTimeGetCurrent() - start) residentSamples=\(samples.values)")
        print("PHASE4_STRESS_LEGACY residentSamples=\(legacySamples.values)")
        // Includes PDFKit document caches and retained output, not just layouts.
        // A generous bound catches gross retention without pretending RSS alone
        // can establish precise object lifetimes.
        let values = samples.values.map(\.bytes)
        XCTAssertEqual(values.count, 11)
        XCTAssertEqual(legacySamples.values.count, 11)
        if let first = values.first, let last = values.last {
            XCTAssertLessThan(last - first, 256 * 1024 * 1024)
            if let legacyFirst = legacySamples.values.first?.bytes, let legacyLast = legacySamples.values.last?.bytes {
                XCTAssertLessThan((last - first) - (legacyLast - legacyFirst), 32 * 1024 * 1024,
                    "Layout's incremental memory exceeds the matched legacy parse by 32 MiB")
            }
        }
    }

    private func parser(_ mode: PdfLayoutMode) -> PdfParser {
        PdfParser(configuration: .init(ocr: .init(mode: .never), layout: .init(mode: mode), cleanup: .minimal, extractCoverImage: false))
    }
}

private final class MemorySamples: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(page: Int, bytes: Int64)] = []
    var values: [(page: Int, bytes: Int64)] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(_ page: Int) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            lock.lock(); storage.append((page, Int64(info.resident_size))); lock.unlock()
        }
    }
}
