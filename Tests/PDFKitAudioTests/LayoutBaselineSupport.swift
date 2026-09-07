import Foundation
@testable import PDFKitAudio

struct TestMarkerOrderScore: Equatable {
    let expectedMarkerCount: Int
    let foundMarkerCount: Int
    let totalPairs: Int
    let correctPairs: Int
    let duplicateMarkerCount: Int

    var coverage: Double {
        guard expectedMarkerCount > 0 else { return 1 }
        return Double(foundMarkerCount) / Double(expectedMarkerCount)
    }

    var pairwiseAccuracy: Double {
        guard totalPairs > 0 else { return coverage }
        return Double(correctPairs) / Double(totalPairs)
    }
}

enum TestLayoutBaselineScorer {
    static func score(expectedMarkers: [String], in text: String) -> TestMarkerOrderScore {
        guard !expectedMarkers.isEmpty else {
            return TestMarkerOrderScore(
                expectedMarkerCount: 0,
                foundMarkerCount: 0,
                totalPairs: 0,
                correctPairs: 0,
                duplicateMarkerCount: 0
            )
        }

        var firstOffsets: [String: Int] = [:]
        var duplicates = 0

        for marker in expectedMarkers {
            let ranges = allRanges(of: marker, in: text)
            if let first = ranges.first {
                firstOffsets[marker] = text.distance(from: text.startIndex, to: first.lowerBound)
            }
            if ranges.count > 1 {
                duplicates += 1
            }
        }

        var correctPairs = 0
        var totalPairs = 0
        if expectedMarkers.count > 1 {
            for leftIndex in 0..<(expectedMarkers.count - 1) {
                for rightIndex in (leftIndex + 1)..<expectedMarkers.count {
                    totalPairs += 1
                    let left = expectedMarkers[leftIndex]
                    let right = expectedMarkers[rightIndex]
                    if let leftOffset = firstOffsets[left],
                       let rightOffset = firstOffsets[right],
                       leftOffset < rightOffset {
                        correctPairs += 1
                    }
                }
            }
        }

        return TestMarkerOrderScore(
            expectedMarkerCount: expectedMarkers.count,
            foundMarkerCount: firstOffsets.count,
            totalPairs: totalPairs,
            correctPairs: correctPairs,
            duplicateMarkerCount: duplicates
        )
    }

    static func orderedMarkers(expectedMarkers: [String], in text: String) -> [String] {
        expectedMarkers.compactMap { marker -> (String, Int)? in
            guard let range = text.range(of: marker) else { return nil }
            return (marker, text.distance(from: text.startIndex, to: range.lowerBound))
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0 < $1.0
        }
        .map(\.0)
    }

    private static func allRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var searchStart = haystack.startIndex

        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }
}

/// Debug-only diagnostics used by tests and manual fixture investigation. Keeping
/// this outside Sources avoids committing to a public diagnostics API before the
/// internal layout model is implemented.
enum TestLayoutDiagnostics {
    static func fixtureJSON(_ fixture: TestLayoutFixture) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(fixture)
        return String(decoding: data, as: UTF8.self)
    }

    static func parsedBookJSON(_ book: PdfBook) throws -> String {
        let pages: [[String: Any]] = book.pages.map { page in
            [
                "pageIndex": page.pageIndex,
                "source": String(describing: page.extractionSource),
                "confidence": page.confidence,
                "text": page.text
            ]
        }

        let object: [String: Any] = [
            "title": book.metadata.title as Any,
            "pageCount": book.pages.count,
            "ocrPageCount": book.ocrPageCount,
            "emptyPageCount": book.emptyPageCount,
            "pages": pages
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

struct TestLayoutBaselineAggregate {
    private(set) var fixtureCount = 0
    private(set) var expectedMarkers = 0
    private(set) var foundMarkers = 0
    private(set) var totalPairs = 0
    private(set) var correctPairs = 0
    private(set) var duplicateMarkers = 0

    mutating func add(_ score: TestMarkerOrderScore) {
        fixtureCount += 1
        expectedMarkers += score.expectedMarkerCount
        foundMarkers += score.foundMarkerCount
        totalPairs += score.totalPairs
        correctPairs += score.correctPairs
        duplicateMarkers += score.duplicateMarkerCount
    }

    var coverage: Double {
        guard expectedMarkers > 0 else { return 1 }
        return Double(foundMarkers) / Double(expectedMarkers)
    }

    var pairwiseAccuracy: Double {
        guard totalPairs > 0 else { return coverage }
        return Double(correctPairs) / Double(totalPairs)
    }
}
