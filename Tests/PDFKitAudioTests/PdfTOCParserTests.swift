import PDFKit
import XCTest
@testable import PDFKitAudio

final class PdfTOCParserTests: XCTestCase {
    func testParsesFlatOutlineInOrderWithDeterministicIDs() throws {
        let document = try TestPDFBuilder.documentWithOutline(
            pages: ["One", "Two", "Three"],
            outline: [
                .init("Chapter 1", pageIndex: 0),
                .init("Chapter 2", pageIndex: 1),
                .init("Chapter 3", pageIndex: 2)
            ]
        )

        let firstParse = PdfTOCParser.parse(document: document)
        let secondParse = PdfTOCParser.parse(document: document)

        XCTAssertEqual(firstParse.map(\.title), ["Chapter 1", "Chapter 2", "Chapter 3"])
        XCTAssertEqual(firstParse.map(\.pageIndex), [0, 1, 2])
        XCTAssertEqual(firstParse.map(\.id), ["outline:0", "outline:1", "outline:2"])
        XCTAssertEqual(firstParse.map(\.id), secondParse.map(\.id))
        XCTAssertTrue(firstParse.allSatisfy { $0.level == 0 })
    }

    func testPreservesNestedOutlineHierarchyLevelsAndPaths() throws {
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
        XCTAssertEqual(toc[0].id, "outline:0")
        XCTAssertEqual(toc[0].title, "Chapter 1")
        XCTAssertEqual(toc[0].level, 0)
        XCTAssertEqual(toc[0].children.map(\.title), ["Section 1.1", "Section 1.2"])
        XCTAssertEqual(toc[0].children.map(\.pageIndex), [0, 1])
        XCTAssertEqual(toc[0].children.map(\.id), ["outline:0/0", "outline:0/1"])
        XCTAssertTrue(toc[0].children.allSatisfy { $0.level == 1 })
        XCTAssertEqual(toc[1].pageIndex, 2)
    }

    func testPreservesRepeatedDestinationsAsNavigationMetadata() throws {
        let document = try TestPDFBuilder.documentWithOutline(
            pages: ["One", "Two"],
            outline: [
                .init("Chapter 1", pageIndex: 0),
                .init("Alias", pageIndex: 0),
                .init("Chapter 2", pageIndex: 1)
            ]
        )

        let toc = PdfTOCParser.parse(document: document)

        XCTAssertEqual(toc.map(\.pageIndex), [0, 0, 1])
        XCTAssertEqual(toc.count, 3)
    }

    func testUnresolvedDestinationRemainsNilInsteadOfBecomingPageZero() throws {
        guard let document = PDFDocument(data: try TestPDFBuilder.digitalPDF(pages: ["One", "Two"])) else {
            return XCTFail("Expected fixture PDF")
        }

        let root = PDFOutline()
        let unresolved = PDFOutline()
        unresolved.label = "Broken Destination"
        root.insertChild(unresolved, at: 0)
        document.outlineRoot = root

        let toc = PdfTOCParser.parse(document: document)

        XCTAssertEqual(toc.count, 1)
        XCTAssertNil(toc[0].pageIndex)
        XCTAssertFalse(toc[0].hasResolvedDestination)
    }

    func testDestinationFromDifferentDocumentRemainsUnresolved() throws {
        guard let document = PDFDocument(data: try TestPDFBuilder.digitalPDF(pages: ["One"])),
              let foreignDocument = PDFDocument(data: try TestPDFBuilder.digitalPDF(pages: ["Foreign"])),
              let foreignPage = foreignDocument.page(at: 0) else {
            return XCTFail("Expected fixture PDFs")
        }

        let root = PDFOutline()
        let item = PDFOutline()
        item.label = "Foreign"
        item.destination = PDFDestination(page: foreignPage, at: .zero)
        root.insertChild(item, at: 0)
        document.outlineRoot = root

        let toc = PdfTOCParser.parse(document: document)

        XCTAssertEqual(toc.count, 1)
        XCTAssertNil(toc[0].pageIndex)
    }

    func testGoToActionDestinationResolves() throws {
        guard let document = PDFDocument(data: try TestPDFBuilder.digitalPDF(pages: ["One", "Two"])),
              let secondPage = document.page(at: 1) else {
            return XCTFail("Expected fixture PDF")
        }

        let root = PDFOutline()
        let item = PDFOutline()
        item.label = "Action Destination"
        item.action = PDFActionGoTo(destination: PDFDestination(page: secondPage, at: .zero))
        root.insertChild(item, at: 0)
        document.outlineRoot = root

        let toc = PdfTOCParser.parse(document: document)

        XCTAssertEqual(toc.first?.pageIndex, 1)
    }
}
