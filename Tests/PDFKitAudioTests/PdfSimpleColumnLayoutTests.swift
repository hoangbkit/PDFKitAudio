import Foundation
import XCTest
@testable import PDFKitAudio

final class PdfSimpleColumnLayoutTests: XCTestCase {
    func testPersistentGuttersIntersectVariableLineEndsAndOrderThreeLanes() throws {
        var lines: [PdfLayoutLine] = []
        for row in 0..<3 {
            for lane in 0..<3 {
                lines.append(line(row * 3 + lane, "Lane \(lane) sentence \(row).",
                    x: 0.08 + CGFloat(lane) * 0.29, y: 0.12 + CGFloat(row) * 0.05,
                    width: row == 1 ? 0.12 : 0.22))
            }
        }
        let result = try XCTUnwrap(PdfSimpleColumnLayout.resolve(lines: lines))
        XCTAssertEqual(result.gutters.count, 2)
        XCTAssertEqual(result.gutters[0].minX, 0.30, accuracy: 0.0001)
        XCTAssertEqual(result.gutters[0].maxX, 0.37, accuracy: 0.0001)
        XCTAssertEqual(orderedIDs(result), [0, 3, 6, 1, 4, 7, 2, 5, 8])
        XCTAssertFalse(result.readingOrder.usedFallback)
    }

    func testSmallColumnFootprintDoesNotRequirePageWidthThreshold() throws {
        let lines = (0..<3).flatMap { row in
            [line(row * 2, "Left sentence.", x: 0.08, y: 0.12 + CGFloat(row) * 0.05, width: 0.06),
             line(row * 2 + 1, "Right sentence.", x: 0.21, y: 0.12 + CGFloat(row) * 0.05, width: 0.07)]
        }
        let result = try XCTUnwrap(PdfSimpleColumnLayout.resolve(lines: lines))
        XCTAssertEqual(orderedIDs(result), [0, 2, 4, 1, 3, 5])
    }

    func testRightToLeftEvidenceReversesLanesWithoutReversingVerticalOrder() throws {
        let lines = (0..<3).flatMap { row in
            [line(row * 2, "جملة عربية.", x: 0.08, y: 0.12 + CGFloat(row) * 0.05, direction: .rightToLeft),
             line(row * 2 + 1, "جملة أخرى.", x: 0.60, y: 0.12 + CGFloat(row) * 0.05, direction: .rightToLeft)]
        }
        let result = try XCTUnwrap(PdfSimpleColumnLayout.resolve(lines: lines))
        XCTAssertEqual(orderedIDs(result), [1, 3, 5, 0, 2, 4])
    }

    func testCellGridAndInteriorSpansUseGeneralResolver() {
        let cells = (0..<3).flatMap { row in
            [line(row * 2, "Item \(row)", x: 0.08, y: 0.12 + CGFloat(row) * 0.10),
             line(row * 2 + 1, "100", x: 0.60, y: 0.12 + CGFloat(row) * 0.10)]
        }
        XCTAssertNil(PdfSimpleColumnLayout.resolve(lines: cells))
        let prose = cells.map {
            line($0.id, $0.text + ".", x: $0.rect.minX, y: $0.rect.minY)
        } + [line(99, "An interior spanning caption.", x: 0.08, y: 0.27, width: 0.8)]
        XCTAssertNil(PdfSimpleColumnLayout.resolve(lines: prose))
    }

    func testLongerColumnContinuesBeforeNextColumn() throws {
        let lines = (0..<4).map { line($0, "Left sentence \($0).", x: 0.08, y: 0.12 + CGFloat($0) * 0.05) }
            + (0..<2).map { line($0 + 4, "Right sentence \($0).", x: 0.60, y: 0.12 + CGFloat($0) * 0.05) }
        let result = try XCTUnwrap(PdfSimpleColumnLayout.resolve(lines: lines))
        XCTAssertEqual(orderedIDs(result), [0, 1, 2, 3, 4, 5])
    }

    func testEarlierRightColumnStartDoesNotBecomeFrontMatter() throws {
        let left = (0..<3).map { line($0, "Left sentence.", x: 0.08, y: 0.17 + CGFloat($0) * 0.05) }
        let right = (0..<3).map { line($0 + 3, "Right sentence.", x: 0.60, y: 0.12 + CGFloat($0) * 0.05) }
        let result = try XCTUnwrap(PdfSimpleColumnLayout.resolve(lines: left + right))
        XCTAssertEqual(orderedIDs(result), [0, 1, 2, 3, 4, 5])
    }

    private func orderedIDs(_ result: PdfSimpleColumnLayout.Result) -> [Int] {
        result.readingOrder.orderedBlockIDs.flatMap { id in
            result.blocks.first { $0.id == id }!.lines.map(\.id)
        }
    }

    private func line(_ id: Int, _ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 0.22,
                      direction: PdfLayoutWritingDirection = .leftToRight) -> PdfLayoutLine {
        let rect = CGRect(x: x, y: y, width: width, height: 0.015)
        let fragment = PdfLayoutFragment(id: id, text: text, rect: rect, source: .native, confidence: 1, sourceOrder: id)
        return PdfLayoutLine(id: id, fragments: [fragment], text: text, rect: rect, writingDirection: direction, sourceOrder: id)
    }
}
