import XCTest
@testable import PDFKitAudio

final class PdfTextCleanerTests: XCTestCase {
    func testRemovesUnsafeControlsAndNormalizesLigatures() {
        let input = "of\u{0000}fice ﬁle ﬂow ﬀ ﬃ ﬄ"
        let output = PdfTextCleaner.clean(input)

        XCTAssertEqual(output, "office file flow ff ffi ffl")
    }

    func testDehyphenatesObviousHardWrappedWord() {
        XCTAssertEqual(
            PdfTextCleaner.clean("A simple exam-\nple paragraph."),
            "A simple example paragraph."
        )
    }

    func testPreservesHyphenForExplicitCompoundContinuation() {
        XCTAssertEqual(
            PdfTextCleaner.clean("A state-\nof-the-art system."),
            "A state-of-the-art system."
        )
        XCTAssertEqual(
            PdfTextCleaner.clean("A well-\nbeing program."),
            "A well-being program."
        )
    }

    func testMinimalCleanupDoesNotDehyphenate() {
        XCTAssertEqual(
            PdfTextCleaner.cleanPage("exam-\nple", configuration: .minimal),
            "exam-\nple"
        )
    }

    func testPageLocalCleanupPreservesStandaloneNumbers() {
        let input = "First paragraph.\n42\n2024\nPage 12\nSecond paragraph."
        let output = PdfTextCleaner.clean(input)

        XCTAssertTrue(output.contains("\n42\n"))
        XCTAssertTrue(output.contains("\n2024\n"))
        XCTAssertTrue(output.contains("\nPage 12\n"))
    }

    func testPreservesParagraphBoundariesWhileCollapsingExcessWhitespace() {
        let input = "First   paragraph.\n\n\n\nSecond\t\tparagraph."
        let output = PdfTextCleaner.clean(input)

        XCTAssertEqual(output, "First paragraph.\n\nSecond paragraph.")
    }

    func testHtmlWrapEscapesBodyAndTitleMarkup() {
        let html = PdfTextCleaner.htmlWrap(
            "A < B & C > D \"quoted\" 'value'",
            title: "A&B <Title> \"Quoted\" 'Name'"
        )

        XCTAssertTrue(html.contains("A &lt; B &amp; C &gt; D &quot;quoted&quot; &#39;value&#39;"))
        XCTAssertTrue(html.contains("<h1>A&amp;B &lt;Title&gt; &quot;Quoted&quot; &#39;Name&#39;</h1>"))
        XCTAssertFalse(html.contains("<h1>A&B <Title>"))
    }
}
