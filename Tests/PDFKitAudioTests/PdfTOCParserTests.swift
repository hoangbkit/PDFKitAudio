import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfTOCParserTests: XCTestCase {
    func testParsesFlatOutlineInOrder() throws {
        let document = try TestPDFBuilder.documentWithOutline(
            pages: ["One", "Two", "Three"],
            outline: [
                .init("Chapter 1", pageIndex: 0),
                .init("Chapter 2", pageIndex: 1),
                .init("Chapter 3", pageIndex: 2)
            ]
        )

        let toc = PdfTOCParser.parse(document: document)

        XCTAssertEqual(toc.map(\.title), ["Chapter 1", "Chapter 2", "Chapter 3"])
        XCTAssertEqual(toc.map(\.pageIndex), [0, 1, 2])
        XCTAssertTrue(toc.allSatisfy { $0.level == 0 })
    }

    func testPreservesNestedOutlineHierarchyAndLevels() throws {
        let document = try TestPDFBuilder.documentWithOutline(
            pages: ["One", "Two", "Three"],
            outline: [
                .init(
                    "Chapter 1",
                    pageIndex: 0,
                    children: [
                        .init("Section 1.1", pageIndex: 0),
                        .init("Section 1.2", pageIndex: 1)
                    ]
                ),
                .init("Chapter 2", pageIndex: 2)
            ]
        )

        let toc = PdfTOCParser.parse(document: document)

        XCTAssertEqual(toc.count, 2)
        XCTAssertEqual(toc[0].title, "Chapter 1")
        XCTAssertEqual(toc[0].level, 0)
        XCTAssertEqual(toc[0].children.map(\.title), ["Section 1.1", "Section 1.2"])
        XCTAssertEqual(toc[0].children.map(\.pageIndex), [0, 1])
        XCTAssertTrue(toc[0].children.allSatisfy { $0.level == 1 })
        XCTAssertEqual(toc[1].title, "Chapter 2")
        XCTAssertEqual(toc[1].pageIndex, 2)
    }

    func testPreservesRepeatedOutlineDestinationsAsCurrentBaseline() throws {
        let document = try TestPDFBuilder.documentWithOutline(
            pages: ["One", "Two"],
            outline: [
                .init("Chapter 1", pageIndex: 0),
                .init("Section 1.1", pageIndex: 0),
                .init("Chapter 2", pageIndex: 1)
            ]
        )

        let toc = PdfTOCParser.parse(document: document)

        XCTAssertEqual(toc.map(\.pageIndex), [0, 0, 1])
    }
}
