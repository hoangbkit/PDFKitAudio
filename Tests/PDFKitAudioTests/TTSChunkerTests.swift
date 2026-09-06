import XCTest
@testable import PDFKitAudio

final class TTSChunkerTests: XCTestCase {
    func testShortTextRemainsSingleChunk() {
        XCTAssertEqual(TTSChunker.chunk(text: "A short sentence.", maxLength: 100), ["A short sentence."])
    }

    func testPrefersSentenceBoundaries() {
        let text = "This is the first sentence with enough words. This is the second sentence with enough words. This is the third sentence with enough words."
        let chunks = TTSChunker.chunk(text: text, maxLength: 70)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(separator: " "), text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 70 })
    }

    func testLongSentenceFallsBackToMaximumLengthPieces() {
        let text = String(repeating: "a", count: 101)
        let chunks = TTSChunker.chunk(text: text, maxLength: 40)

        XCTAssertEqual(chunks.map(\.count), [40, 40, 21])
        XCTAssertEqual(chunks.joined(), text)
    }

    func testReturnsNoEmptyChunks() {
        let text = "First sentence that is definitely long enough.\n\nSecond sentence that is definitely long enough."
        let chunks = TTSChunker.chunk(text: text, maxLength: 55)

        XCTAssertFalse(chunks.contains(where: { $0.isEmpty }))
    }
}
