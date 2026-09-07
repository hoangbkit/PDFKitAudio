import Darwin
import Foundation
import XCTest
@testable import PDFKitAudio

/// Stress harness for recording layout work baselines without slowing ordinary CI.
/// Run explicitly with:
///
///   PDFKITAUDIO_RUN_LAYOUT_BENCHMARKS=1 swift test --filter PdfLayoutBenchmarkTests
///
/// The output is intentionally machine-greppable via the `LAYOUT_BENCHMARK` prefix.
final class PdfLayoutBenchmarkTests: XCTestCase {
    func testOptInBaselineBenchmarks() throws {
        guard ProcessInfo.processInfo.environment["PDFKITAUDIO_RUN_LAYOUT_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set PDFKITAUDIO_RUN_LAYOUT_BENCHMARKS=1 to run stress baselines")
        }

        try runNativeBenchmark(
            name: "simple-100",
            fixtureName: "single-column-narrow-margins",
            pageCount: 100
        )
        try runNativeBenchmark(
            name: "two-column-100",
            fixtureName: "two-column-symmetric",
            pageCount: 100
        )
        try runMixedBenchmark(name: "mixed-native-scanned-20", pageCount: 20)
        try runNativeBenchmark(
            name: "simple-stress-500",
            fixtureName: "single-column-wide-margins",
            pageCount: 500
        )
    }

    private func runNativeBenchmark(
        name: String,
        fixtureName: String,
        pageCount: Int
    ) throws {
        guard let fixture = TestLayoutFixtureCatalog.byName[fixtureName] else {
            return XCTFail("Missing benchmark fixture \(fixtureName)")
        }

        let data = try TestPDFBuilder.repeatedLayoutPDF(fixture, pageCount: pageCount)
        let beforeRSS = peakResidentBytes()
        let start = CFAbsoluteTimeGetCurrent()
        let book = try PdfParser(
            ocrMode: .never,
            cleanupConfiguration: .minimal,
            extractCoverImage: false
        ).parse(data: data)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let afterRSS = peakResidentBytes()

        emit(
            name: name,
            pageCount: book.pages.count,
            seconds: elapsed,
            peakResidentBytes: max(beforeRSS, afterRSS),
            ocrPageCount: book.ocrPageCount,
            outputCharacters: book.pages.reduce(0) { $0 + $1.text.count }
        )
        XCTAssertEqual(book.pages.count, pageCount)
        XCTAssertEqual(book.ocrPageCount, 0)
    }

    private func runMixedBenchmark(name: String, pageCount: Int) throws {
        guard let template = TestLayoutFixtureCatalog.byName["mixed-native-scanned-pages"],
              template.pages.count == 2 else {
            return XCTFail("Missing mixed benchmark template")
        }

        var pages: [TestLayoutPage] = []
        pages.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            pages.append(template.pages[index % template.pages.count])
        }
        let fixture = TestLayoutFixture(
            name: name,
            category: "benchmark",
            support: .supported,
            pages: pages,
            expectedMarkerOrder: [],
            notes: "Alternating native/scanned benchmark"
        )

        let data = try TestPDFBuilder.layoutPDF(fixture)
        let beforeRSS = peakResidentBytes()
        let start = CFAbsoluteTimeGetCurrent()
        let book = try PdfParser(
            ocrMode: .auto,
            cleanupConfiguration: .minimal,
            extractCoverImage: false
        ).parse(data: data)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let afterRSS = peakResidentBytes()

        emit(
            name: name,
            pageCount: book.pages.count,
            seconds: elapsed,
            peakResidentBytes: max(beforeRSS, afterRSS),
            ocrPageCount: book.ocrPageCount,
            outputCharacters: book.pages.reduce(0) { $0 + $1.text.count }
        )
        XCTAssertEqual(book.pages.count, pageCount)
        XCTAssertGreaterThan(book.ocrPageCount, 0)
    }

    /// On Darwin, ru_maxrss is peak resident set size in bytes.
    private func peakResidentBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss)
    }

    private func emit(
        name: String,
        pageCount: Int,
        seconds: TimeInterval,
        peakResidentBytes: Int64,
        ocrPageCount: Int,
        outputCharacters: Int
    ) {
        print(
            "LAYOUT_BENCHMARK name=\(name) pages=\(pageCount) seconds=\(String(format: \"%.4f\", seconds)) peakResidentBytes=\(peakResidentBytes) ocrPages=\(ocrPageCount) outputCharacters=\(outputCharacters)"
        )
    }
}
