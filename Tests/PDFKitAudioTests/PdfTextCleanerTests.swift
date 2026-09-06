import XCTest
@testable import PDFKitAudio

final class PdfTextCleanerTests: XCTestCase {
    func testRemovesNullBytesAndNormalizesLigatures() {
        let input = "of\u{0000}fice ﬁle ﬂow ﬀ ﬃ ﬄ"
        let output = PdfTextCleaner.clean(input)

        XCTAssertEqual(output, "office file flow ff ffi ffl")
    }

    func testDehyphenatesHardWrappedWords() {
        XCTAssertEqual(
            PdfTextCleaner.clean("A simple exam-\nple paragraph."),
            "A simple example paragraph."
        )
    }

    func testRemovesIsolatedNumericPageNumbers() {
        let input = "First paragraph.\n42\nSecond paragraph."
        let output = PdfTextCleaner.clean(input)

        XCTAssertEqual(output, "First paragraph.\nSecond paragraph.")
    }

    func testRemovesShortPagePrefixLines() {
        let input = "First paragraph.\nPage 12\nSecond paragraph."
        let output = PdfTextCleaner.clean(input)

        XCTAssertEqual(output, "First paragraph.\nSecond paragraph.")
    }

    func testPreservesParagraphBoundariesWhileCollapsingExcessWhitespace() {
        let input = "First   paragraph.\n\n\n\nSecond\t\tparagraph."
        let output = PdfTextCleaner.clean(input)

        XCTAssertEqual(output, "First paragraph.\n\nSecond paragraph.")
    }

    func testHtmlWrapEscapesBodyMarkup() {
        let html = PdfTextCleaner.htmlWrap("A < B & C > D", title: "Title")

        XCTAssertTrue(html.contains("A &lt; B &amp; C &gt; D"))
    }
}
