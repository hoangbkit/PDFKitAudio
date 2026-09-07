import XCTest
@testable import PDFKitAudio

final class TTSChunkerTests: XCTestCase {
    func testShortTextRemainsSingleChunk() {
        XCTAssertEqual(
            TTSChunker.chunk(text: "A short sentence.", maxLength: 100),
            ["A short sentence."]
        )
    }

    func testZeroAndNegativeLimitsAreClampedSafely() {
        let zero = TTSChunker.chunk(text: "abc", maxLength: 0)
        let negative = TTSChunker.chunk(text: "abc", maxLength: -10)

        XCTAssertEqual(zero, ["a", "b", "c"])
        XCTAssertEqual(negative, ["a", "b", "c"])
    }

    func testExactLimitStringRemainsSingleChunk() {
        let text = String(repeating: "a", count: 40)
        XCTAssertEqual(TTSChunker.chunk(text: text, maxLength: 40), [text])
    }

    func testPrefersSentenceBoundaries() {
        let text = "This is the first sentence with enough words. This is the second sentence with enough words. This is the third sentence with enough words."
        let chunks = TTSChunker.chunk(text: text, maxLength: 70)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(normalized(chunks.joined(separator: " ")), normalized(text))
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 70 })
    }

    func testLongSentenceSplitsAtWordsBeforeHardCutting() {
        let text = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
        let chunks = TTSChunker.chunk(text: text, maxLength: 24)
        let originalWords = Set(text.split(separator: " ").map(String.init))

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 24 })
        XCTAssertEqual(normalized(chunks.joined(separator: " ")), normalized(text))
        for chunk in chunks {
            for word in chunk.split(separator: " ") {
                XCTAssertTrue(originalWords.contains(String(word)))
            }
        }
    }

    func testUnbrokenTokenUsesGraphemeSafeHardSplit() {
        let text = String(repeating: "😀", count: 101)
        let chunks = TTSChunker.chunk(text: text, maxLength: 40)

        XCTAssertEqual(chunks.map(\.count), [40, 40, 21])
        XCTAssertEqual(chunks.joined(), text)
    }

    func testFoundationSentenceBoundariesHandleAbbreviationDecimalAndQuote() {
        let text = "Dr. Smith paid 3.14 dollars. \"Then he left.\" Another sentence follows."
        let chunks = TTSChunker.chunk(text: text, maxLength: 34)

        XCTAssertTrue(chunks.allSatisfy { $0.count <= 34 })
        XCTAssertEqual(normalized(chunks.joined(separator: " ")), normalized(text))
        XCTAssertTrue(chunks.contains { $0.contains("Dr. Smith") })
        XCTAssertTrue(chunks.contains { $0.contains("3.14") })
    }

    func testParagraphPreservationAvoidsPackingAcrossBlankLine() {
        let text = "First short paragraph.\n\nSecond short paragraph."
        let preserving = TTSChunker.chunk(
            text: text,
            configuration: TTSChunkingConfiguration(
                maxCharacters: 100,
                preferredMinimumCharacters: 20,
                preserveParagraphs: true
            )
        )
        let compact = TTSChunker.chunk(
            text: text,
            configuration: TTSChunkingConfiguration(
                maxCharacters: 100,
                preferredMinimumCharacters: 20,
                preserveParagraphs: false
            )
        )

        XCTAssertEqual(preserving.count, 2)
        XCTAssertEqual(compact.count, 1)
        XCTAssertEqual(normalized(preserving.joined(separator: " ")), normalized(text))
        XCTAssertEqual(normalized(compact.joined(separator: " ")), normalized(text))
    }

    func testMultilingualSentencePunctuationPreservesContent() {
        let text = "Đây là câu tiếng Việt. 这是第一句话。これは二番目の文です。 Kết thúc."
        let chunks = TTSChunker.chunk(text: text, maxLength: 24)

        XCTAssertTrue(chunks.allSatisfy { $0.count <= 24 })
        XCTAssertEqual(normalized(chunks.joined(separator: " ")), normalized(text))
    }

    func testReturnsNoEmptyChunksAndNeverExceedsMaximum() {
        let text = "First sentence that is definitely long enough.\n\nSecond sentence that is definitely long enough."
        let chunks = TTSChunker.chunk(text: text, maxLength: 25)

        XCTAssertFalse(chunks.contains(where: { $0.isEmpty }))
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 25 })
        XCTAssertEqual(normalized(chunks.joined(separator: " ")), normalized(text))
    }

    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
