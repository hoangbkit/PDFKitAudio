import Foundation

enum PdfLayoutBlockBuilder {
    static func build(lines: [PdfLayoutLine]) -> [PdfLayoutBlock] {
        guard !lines.isEmpty else { return [] }

        let ordered = lines.sorted(by: stableGeometryOrder)
        let pageMedianHeight = median(ordered.map { $0.rect.height })
        let pageMedianFontSize = median(ordered.compactMap(\.medianFontSize))
        var drafts: [BlockDraft] = []

        for line in ordered {
            if let index = bestDraftIndex(
                for: line,
                drafts: drafts,
                pageMedianHeight: pageMedianHeight,
                pageMedianFontSize: pageMedianFontSize
            ) {
                drafts[index].append(line)
            } else {
                drafts.append(BlockDraft(line))
            }
        }

        return drafts
            .sorted(by: stableBlockOrder)
            .enumerated()
            .map { index, draft in
                PdfLayoutBlock(
                    id: index,
                    lines: draft.lines,
                    text: draft.lines.map(\.text).joined(separator: "\n"),
                    rect: draft.rect,
                    sourceOrder: draft.minimumSourceOrder
                )
            }
    }

    private struct BlockDraft {
        var lines: [PdfLayoutLine]
        var rect: CGRect

        init(_ line: PdfLayoutLine) {
            lines = [line]
            rect = line.rect
        }

        var lastLine: PdfLayoutLine { lines[lines.count - 1] }
        var minimumSourceOrder: Int { lines.map(\.sourceOrder).min() ?? 0 }
        var startsWithListItem: Bool {
            guard let first = lines.first else { return false }
            return PdfLayoutBlockBuilder.beginsListItem(first.text)
        }

        mutating func append(_ line: PdfLayoutLine) {
            lines.append(line)
            rect = rect.union(line.rect)
        }
    }

    private static func bestDraftIndex(
        for line: PdfLayoutLine,
        drafts: [BlockDraft],
        pageMedianHeight: CGFloat,
        pageMedianFontSize: CGFloat
    ) -> Int? {
        var best: (index: Int, score: CGFloat)?

        for (index, draft) in drafts.enumerated() {
            let previous = draft.lastLine
            guard canMerge(
                previous: previous,
                current: line,
                blockStartsWithListItem: draft.startsWithListItem,
                pageMedianHeight: pageMedianHeight,
                pageMedianFontSize: pageMedianFontSize
            ) else { continue }

            let verticalGap = max(0, line.rect.minY - previous.rect.maxY)
            let leftDelta = abs(line.rect.minX - previous.rect.minX)
            let rightDelta = abs(line.rect.maxX - previous.rect.maxX)
            let score = verticalGap + min(leftDelta, rightDelta) * 0.35

            if best == nil || score < best!.score {
                best = (index, score)
            }
        }

        return best?.index
    }

    private static func canMerge(
        previous: PdfLayoutLine,
        current: PdfLayoutLine,
        blockStartsWithListItem: Bool,
        pageMedianHeight: CGFloat,
        pageMedianFontSize: CGFloat
    ) -> Bool {
        guard previous.writingDirection == current.writingDirection else {
            return false
        }

        // Never merge side-by-side lines into a paragraph-like block.
        let verticalOverlap = overlapLength(
            previous.rect.minY,
            previous.rect.maxY,
            current.rect.minY,
            current.rect.maxY
        )
        if verticalOverlap > min(previous.rect.height, current.rect.height) * 0.35,
           horizontalOverlapRatio(previous.rect, current.rect) < 0.20 {
            return false
        }

        let verticalGap = current.rect.minY - previous.rect.maxY
        let largestRelevantHeight = max(
            pageMedianHeight,
            max(previous.rect.height, current.rect.height)
        )
        let maximumGap = max(
            0.030,
            min(0.080, largestRelevantHeight * 1.85)
        )
        if verticalGap < -max(0.010, pageMedianHeight * 0.35) || verticalGap > maximumGap {
            return false
        }

        let overlapRatio = horizontalOverlapRatio(previous.rect, current.rect)
        let leftDelta = abs(previous.rect.minX - current.rect.minX)
        let rightDelta = abs(previous.rect.maxX - current.rect.maxX)
        let edgeTolerance = max(0.040, pageMedianHeight * 1.55)
        let alignedEnough = overlapRatio >= 0.58
            || leftDelta <= edgeTolerance
            || rightDelta <= edgeTolerance
        guard alignedEnough else { return false }

        // A strong font-size or emphasis transition is usually a heading/body or
        // body/footnote boundary. Missing style hints never force a split.
        if strongStyleTransition(
            previous: previous,
            current: current,
            pageMedianFontSize: pageMedianFontSize
        ) {
            return false
        }

        // Each explicit list item starts a separate block. A continuation line
        // can still merge with the list block above, but the next marker cannot.
        if blockStartsWithListItem && beginsListItem(current.text) {
            return false
        }

        return true
    }

    private static func strongStyleTransition(
        previous: PdfLayoutLine,
        current: PdfLayoutLine,
        pageMedianFontSize: CGFloat
    ) -> Bool {
        if let previousSize = previous.medianFontSize,
           let currentSize = current.medianFontSize,
           previousSize > 0,
           currentSize > 0 {
            let ratio = max(previousSize, currentSize) / min(previousSize, currentSize)
            if ratio >= 1.28 {
                return true
            }

            if pageMedianFontSize > 0 {
                let previousEmphasized = previousSize >= pageMedianFontSize * 1.20
                let currentEmphasized = currentSize >= pageMedianFontSize * 1.20
                if previousEmphasized != currentEmphasized && ratio >= 1.12 {
                    return true
                }
            }
        }

        if let previousBold = previous.isPredominantlyBold,
           let currentBold = current.isPredominantlyBold,
           previousBold != currentBold {
            let previousShort = semanticCharacterCount(previous.text) <= 80
            let currentShort = semanticCharacterCount(current.text) <= 80
            if previousShort || currentShort {
                return true
            }
        }

        return false
    }

    private static func beginsListItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let first = trimmed.first,
           "•◦▪▫‣⁃-*–—".contains(first) {
            return true
        }

        var index = trimmed.startIndex
        var digitCount = 0
        while index < trimmed.endIndex,
              trimmed[index].isNumber,
              digitCount < 4 {
            digitCount += 1
            index = trimmed.index(after: index)
        }
        if digitCount > 0,
           index < trimmed.endIndex,
           ".)]:".contains(trimmed[index]) {
            return true
        }

        if trimmed.count >= 2 {
            let characters = Array(trimmed.prefix(3))
            if characters.count >= 2,
               characters[0].isLetter,
               ".)".contains(characters[1]) {
                return true
            }
        }

        return false
    }

    private static func semanticCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                count += 1
            }
        }
    }

    private static func horizontalOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = overlapLength(lhs.minX, lhs.maxX, rhs.minX, rhs.maxX)
        let denominator = max(0.000_001, min(lhs.width, rhs.width))
        return overlap / denominator
    }

    private static func overlapLength(
        _ firstMin: CGFloat,
        _ firstMax: CGFloat,
        _ secondMin: CGFloat,
        _ secondMax: CGFloat
    ) -> CGFloat {
        max(0, min(firstMax, secondMax) - max(firstMin, secondMin))
    }

    private static func stableGeometryOrder(_ lhs: PdfLayoutLine, _ rhs: PdfLayoutLine) -> Bool {
        if abs(lhs.rect.minY - rhs.rect.minY) > 0.000_001 {
            return lhs.rect.minY < rhs.rect.minY
        }
        if abs(lhs.rect.minX - rhs.rect.minX) > 0.000_001 {
            return lhs.rect.minX < rhs.rect.minX
        }
        return lhs.sourceOrder < rhs.sourceOrder
    }

    private static func stableBlockOrder(_ lhs: BlockDraft, _ rhs: BlockDraft) -> Bool {
        if abs(lhs.rect.minY - rhs.rect.minY) > 0.000_001 {
            return lhs.rect.minY < rhs.rect.minY
        }
        if abs(lhs.rect.minX - rhs.rect.minX) > 0.000_001 {
            return lhs.rect.minX < rhs.rect.minX
        }
        return lhs.minimumSourceOrder < rhs.minimumSourceOrder
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
