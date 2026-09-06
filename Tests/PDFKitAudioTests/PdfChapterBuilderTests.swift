import XCTest
@testable import PDFKitAudio

final class PdfChapterBuilderTests: XCTestCase {
    func testNestedOutlineDoesNotDuplicateSourcePages() {
        let pages = makePages(["p0", "p1", "p2", "p3"])
        let toc = [
            PdfTOCItem(
                id: "outline:0",
                title: "Chapter 1",
                pageIndex: 0,
                level: 0,
                children: [
                    PdfTOCItem(id: "outline:0/0", title: "Section 1.1", pageIndex: 0, level: 1),
                    PdfTOCItem(id: "outline:0/1", title: "Section 1.2", pageIndex: 1, level: 1)
                ]
            ),
            PdfTOCItem(id: "outline:1", title: "Chapter 2", pageIndex: 2, level: 0)
        ]

        let chapters = PdfChapterBuilder.build(toc: toc, pages: pages)

        XCTAssertEqual(chapters.map(\.title), ["Chapter 1", "Chapter 2"])
        XCTAssertEqual(chapters.map(\.pageRange), [0...1, 2...3])
        assertNoOverlap(chapters)
        XCTAssertEqual(normalized(chapters.map(\.plainText).joined(separator: " ")), normalized(pages.map(\.text).joined(separator: " ")))
    }

    func testRepeatedSamePageDestinationsCollapseToOneBoundary() {
        let pages = makePages(["p0", "p1", "p2"])
        let toc = [
            PdfTOCItem(id: "0", title: "Chapter 1", pageIndex: 0),
            PdfTOCItem(id: "1", title: "Alias", pageIndex: 0),
            PdfTOCItem(id: "2", title: "Chapter 2", pageIndex: 1)
        ]

        let chapters = PdfChapterBuilder.build(toc: toc, pages: pages)

        XCTAssertEqual(chapters.map(\.title), ["Chapter 1", "Chapter 2"])
        XCTAssertEqual(chapters.map(\.pageRange), [0...0, 1...2])
        assertNoOverlap(chapters)
    }

    func testFrontMatterBeforeFirstTOCEntryIsPreserved() {
        let pages = makePages(["title", "preface", "chapter one", "continued", "chapter two", "end"])
        let toc = [
            PdfTOCItem(id: "0", title: "Chapter 1", pageIndex: 2),
            PdfTOCItem(id: "1", title: "Chapter 2", pageIndex: 4)
        ]

        let chapters = PdfChapterBuilder.build(toc: toc, pages: pages)

        XCTAssertEqual(chapters.map(\.title), ["Front Matter", "Chapter 1", "Chapter 2"])
        XCTAssertEqual(chapters.map(\.pageRange), [0...1, 2...3, 4...5])
        XCTAssertTrue(chapters[0].plainText.contains("title"))
        XCTAssertTrue(chapters[0].plainText.contains("preface"))
    }

    func testBlankFrontMatterDoesNotCreateEmptyChapter() {
        let pages = [
            page(0, ""),
            page(1, ""),
            page(2, "chapter one"),
            page(3, "end")
        ]
        let toc = [PdfTOCItem(id: "0", title: "Chapter 1", pageIndex: 2)]

        let chapters = PdfChapterBuilder.build(toc: toc, pages: pages)

        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "Chapter 1")
        XCTAssertEqual(chapters[0].pageRange, 2...3)
    }

    func testMalformedBackwardOutlineNormalizesIntoMonotonicRanges() {
        let pages = makePages(["front", "one", "two", "three", "four"])
        let toc = [
            PdfTOCItem(id: "0", title: "Later", pageIndex: 3),
            PdfTOCItem(id: "1", title: "Earlier", pageIndex: 1),
            PdfTOCItem(id: "2", title: "Last", pageIndex: 4)
        ]

        let chapters = PdfChapterBuilder.build(toc: toc, pages: pages)

        XCTAssertEqual(chapters.map(\.title), ["Front Matter", "Earlier", "Later", "Last"])
        XCTAssertEqual(chapters.map(\.pageRange), [0...0, 1...2, 3...3, 4...4])
        assertNoOverlap(chapters)
    }

    func testSparseTopLevelFallsBackToConsistentChildLevel() {
        let pages = makePages(["cover", "one", "continued", "two", "three"])
        let toc = [
            PdfTOCItem(
                id: "0",
                title: "Book",
                pageIndex: 0,
                level: 0,
                children: [
                    PdfTOCItem(id: "0/0", title: "Chapter 1", pageIndex: 1, level: 1),
                    PdfTOCItem(id: "0/1", title: "Chapter 2", pageIndex: 3, level: 1),
                    PdfTOCItem(id: "0/2", title: "Chapter 3", pageIndex: 4, level: 1)
                ]
            )
        ]

        let chapters = PdfChapterBuilder.build(toc: toc, pages: pages)

        XCTAssertEqual(chapters.map(\.title), ["Front Matter", "Chapter 1", "Chapter 2", "Chapter 3"])
        XCTAssertEqual(chapters.map(\.pageRange), [0...0, 1...2, 3...3, 4...4])
    }

    func testUnresolvedDestinationsAreIgnoredWithoutBecomingPageZero() {
        let pages = makePages(["front", "one", "two"])
        let toc = [
            PdfTOCItem(id: "0", title: "Broken", pageIndex: nil),
            PdfTOCItem(id: "1", title: "Chapter 1", pageIndex: 1),
            PdfTOCItem(id: "2", title: "Chapter 2", pageIndex: 2)
        ]

        let chapters = PdfChapterBuilder.build(toc: toc, pages: pages)

        XCTAssertEqual(chapters.map(\.title), ["Front Matter", "Chapter 1", "Chapter 2"])
        XCTAssertEqual(chapters.map(\.pageRange), [0...0, 1...1, 2...2])
        XCTAssertFalse(chapters.contains { $0.title == "Broken" })
    }

    func testEveryNonEmptyCanonicalPageAppearsExactlyOnce() {
        let pages = [
            page(0, "front"),
            page(1, ""),
            page(2, "alpha"),
            page(3, "beta"),
            page(4, "gamma")
        ]
        let toc = [
            PdfTOCItem(id: "0", title: "Chapter 1", pageIndex: 2),
            PdfTOCItem(id: "1", title: "Section", pageIndex: 2),
            PdfTOCItem(id: "2", title: "Chapter 2", pageIndex: 4)
        ]

        let chapters = PdfChapterBuilder.build(toc: toc, pages: pages)

        assertNoOverlap(chapters)
        for sourcePage in pages where !sourcePage.text.isEmpty {
            XCTAssertEqual(chapters.filter { $0.pageRange.contains(sourcePage.pageIndex) }.count, 1)
        }
        XCTAssertEqual(
            normalized(chapters.map(\.plainText).joined(separator: " ")),
            normalized(pages.map(\.text).joined(separator: " "))
        )
    }

    func testHeadingFallbackPreservesFrontMatter() {
        let pages = makePages([
            "Preface content",
            "Chapter 1\nOpening text",
            "middle",
            "CHAPTER II\nSecond chapter"
        ])

        let chapters = PdfChapterBuilder.build(toc: [], pages: pages)

        XCTAssertEqual(chapters.map(\.title), ["Front Matter", "Chapter 1", "CHAPTER II"])
        XCTAssertEqual(chapters.map(\.pageRange), [0...0, 1...2, 3...3])
    }

    private func makePages(_ texts: [String]) -> [PdfPageContent] {
        texts.enumerated().map { page($0.offset, $0.element) }
    }

    private func page(_ index: Int, _ text: String) -> PdfPageContent {
        PdfPageContent(
            pageIndex: index,
            nativeText: text,
            text: text,
            extractionSource: text.isEmpty ? .empty : .native,
            confidence: text.isEmpty ? 0 : 1
        )
    }

    private func assertNoOverlap(_ chapters: [PdfChapter], file: StaticString = #filePath, line: UInt = #line) {
        for pair in zip(chapters, chapters.dropFirst()) {
            XCTAssertLessThan(pair.0.pageRange.upperBound, pair.1.pageRange.lowerBound, file: file, line: line)
        }
    }

    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
