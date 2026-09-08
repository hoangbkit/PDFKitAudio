import Foundation

enum PdfLayoutLineBuilder {
    static func build(fragments: [PdfLayoutFragment], gutters: [PdfLayoutGutter]? = nil) -> [PdfLayoutLine] {
        let valid = fragments.filter(isValid)
        guard !valid.isEmpty else { return [] }
        let gutters = gutters ?? PdfSimpleColumnLayout.fragmentGutters(valid)

        let medianHeight = median(valid.map { $0.rect.height })
        let ordered = valid.sorted(by: verticalSourceOrder)
        var rows: [RowDraft] = []

        for fragment in ordered {
            if let index = bestRowIndex(
                for: fragment,
                rows: rows,
                pageMedianHeight: medianHeight
            ) {
                rows[index].append(fragment)
            } else {
                rows.append(RowDraft(fragment))
            }
        }

        rows.sort {
            if abs($0.rect.minY - $1.rect.minY) > 0.000_001 {
                return $0.rect.minY < $1.rect.minY
            }
            if abs($0.rect.minX - $1.rect.minX) > 0.000_001 {
                return $0.rect.minX < $1.rect.minX
            }
            return $0.minimumSourceOrder < $1.minimumSourceOrder
        }

        var output: [PdfLayoutLine] = []
        var nextID = 0

        for row in rows {
            for segment in splitAtStrongHorizontalGaps(row.fragments, medianHeight: medianHeight, gutters: gutters) {
                let direction = writingDirection(for: segment)
                let fragments = orderedWithinLine(segment, direction: direction)
                let text = reconstructText(fragments, direction: direction)
                let rect = unionRect(fragments.map(\.rect))
                output.append(PdfLayoutLine(
                    id: nextID,
                    fragments: fragments,
                    text: text,
                    rect: rect,
                    writingDirection: direction,
                    sourceOrder: fragments.map(\.sourceOrder).min() ?? nextID
                ))
                nextID += 1
            }
        }

        return output.sorted {
            if abs($0.rect.minY - $1.rect.minY) > 0.000_001 {
                return $0.rect.minY < $1.rect.minY
            }
            if abs($0.rect.minX - $1.rect.minX) > 0.000_001 {
                return $0.rect.minX < $1.rect.minX
            }
            return $0.sourceOrder < $1.sourceOrder
        }
        .enumerated()
        .map { index, line in
            PdfLayoutLine(
                id: index,
                fragments: line.fragments,
                text: line.text,
                rect: line.rect,
                writingDirection: line.writingDirection,
                sourceOrder: line.sourceOrder
            )
        }
    }

    private struct RowDraft {
        var fragments: [PdfLayoutFragment]
        var rect: CGRect

        init(_ fragment: PdfLayoutFragment) {
            fragments = [fragment]
            rect = fragment.rect
        }

        var medianHeight: CGFloat {
            PdfLayoutLineBuilder.median(fragments.map { $0.rect.height })
        }

        var minimumSourceOrder: Int {
            fragments.map(\.sourceOrder).min() ?? 0
        }

        mutating func append(_ fragment: PdfLayoutFragment) {
            fragments.append(fragment)
            rect = rect.union(fragment.rect)
        }
    }

    private static func bestRowIndex(
        for fragment: PdfLayoutFragment,
        rows: [RowDraft],
        pageMedianHeight: CGFloat
    ) -> Int? {
        var best: (index: Int, score: CGFloat)?

        for (index, row) in rows.enumerated().reversed() {
            let verticalDistance = fragment.rect.midY - row.rect.midY
            let searchWindow = max(0.025, pageMedianHeight * 1.4)
            if verticalDistance > searchWindow {
                break
            }

            guard sharesLogicalBaseline(
                fragment,
                row: row,
                pageMedianHeight: pageMedianHeight
            ) else { continue }

            let score = abs(fragment.rect.midY - row.rect.midY)
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }

        return best?.index
    }

    private static func sharesLogicalBaseline(
        _ fragment: PdfLayoutFragment,
        row: RowDraft,
        pageMedianHeight: CGFloat
    ) -> Bool {
        let rowHeight = max(row.medianHeight, 0.000_001)
        let fragmentHeight = max(fragment.rect.height, 0.000_001)
        let overlap = verticalOverlap(fragment.rect, row.rect)
        let overlapRatio = overlap / min(fragmentHeight, rowHeight)
        if overlapRatio >= 0.42 {
            return true
        }

        let centerDistance = abs(fragment.rect.midY - row.rect.midY)
        let adaptiveCenterTolerance = max(
            0.008,
            min(
                0.030,
                max(pageMedianHeight * 0.58, min(fragmentHeight, rowHeight) * 0.72)
            )
        )
        if centerDistance <= adaptiveCenterTolerance {
            return true
        }

        // Small superscript/subscript-like fragments may sit above/below the
        // normal center line. Attach them only when they are both vertically
        // close and horizontally adjacent to an existing row member.
        let small = min(fragmentHeight, rowHeight) <= max(fragmentHeight, rowHeight) * 0.72
        guard small else { return false }

        let verticalEdgeDistance = max(
            0,
            max(fragment.rect.minY, row.rect.minY) - min(fragment.rect.maxY, row.rect.maxY)
        )
        let horizontalDistance = horizontalDistanceToRect(fragment.rect, row.rect)
        return verticalEdgeDistance <= max(0.010, pageMedianHeight * 0.55)
            && horizontalDistance <= max(0.030, pageMedianHeight * 1.25)
    }

    private static func splitAtStrongHorizontalGaps(
        _ fragments: [PdfLayoutFragment],
        medianHeight: CGFloat,
        gutters: [PdfLayoutGutter]
    ) -> [[PdfLayoutFragment]] {
        guard fragments.count > 1 else { return [fragments] }
        let ordered = fragments.sorted {
            if abs($0.rect.minX - $1.rect.minX) > 0.000_001 {
                return $0.rect.minX < $1.rect.minX
            }
            return $0.sourceOrder < $1.sourceOrder
        }

        var result: [[PdfLayoutFragment]] = []
        var current: [PdfLayoutFragment] = [ordered[0]]

        for index in 1..<ordered.count {
            let lhs = ordered[index - 1]
            let rhs = ordered[index]
            let gap = rhs.rect.minX - lhs.rect.maxX
            let charWidth = median([
                estimatedCharacterWidth(lhs),
                estimatedCharacterWidth(rhs)
            ])
            let typographyGap = min(0.090, charWidth * 4.5)
            let strongGap = max(
                max(0.045, medianHeight * 1.45),
                typographyGap
            )

            let crossesEstablishedGutter = gutters.contains {
                lhs.rect.maxX <= $0.center && rhs.rect.minX >= $0.center
                    && min(lhs.rect.maxY, rhs.rect.maxY) >= $0.verticalRange.lowerBound
                    && max(lhs.rect.minY, rhs.rect.minY) <= $0.verticalRange.upperBound
            }
            if gap >= strongGap || crossesEstablishedGutter {
                result.append(current)
                current = [rhs]
            } else {
                current.append(rhs)
            }
        }

        result.append(current)
        return result
    }

    private static func reconstructText(
        _ fragments: [PdfLayoutFragment],
        direction: PdfLayoutWritingDirection
    ) -> String {
        guard let first = fragments.first else { return "" }
        var result = trimmedFragmentText(first.text)
        var previous = first

        for fragment in fragments.dropFirst() {
            let currentText = trimmedFragmentText(fragment.text)
            guard !currentText.isEmpty else { continue }

            if shouldInsertSpace(
                between: previous,
                previousText: result,
                current: fragment,
                currentText: currentText,
                direction: direction
            ) {
                result.append(" ")
            }
            result.append(currentText)
            previous = fragment
        }

        return result
    }

    private static func shouldInsertSpace(
        between previous: PdfLayoutFragment,
        previousText: String,
        current: PdfLayoutFragment,
        currentText: String,
        direction: PdfLayoutWritingDirection
    ) -> Bool {
        guard let previousCharacter = previousText.last,
              let currentCharacter = currentText.first else {
            return false
        }

        if isClosingPunctuation(currentCharacter) || isOpeningPunctuation(previousCharacter) {
            return false
        }
        if isCJK(previousCharacter) && isCJK(currentCharacter) {
            return false
        }
        if previous.text.last?.isWhitespace == true || current.text.first?.isWhitespace == true {
            return true
        }

        let gap: CGFloat
        switch direction {
        case .leftToRight:
            gap = current.rect.minX - previous.rect.maxX
        case .rightToLeft:
            gap = previous.rect.minX - current.rect.maxX
        }

        if gap <= 0 {
            return false
        }

        let charWidth = median([
            estimatedCharacterWidth(previous),
            estimatedCharacterWidth(current)
        ])
        let noSpaceThreshold = max(0.0025, min(0.018, charWidth * 0.70))
        return gap > noSpaceThreshold
    }

    private static func orderedWithinLine(
        _ fragments: [PdfLayoutFragment],
        direction: PdfLayoutWritingDirection
    ) -> [PdfLayoutFragment] {
        fragments.sorted { lhs, rhs in
            switch direction {
            case .leftToRight:
                if abs(lhs.rect.minX - rhs.rect.minX) > 0.000_001 {
                    return lhs.rect.minX < rhs.rect.minX
                }
            case .rightToLeft:
                if abs(lhs.rect.maxX - rhs.rect.maxX) > 0.000_001 {
                    return lhs.rect.maxX > rhs.rect.maxX
                }
            }
            return lhs.sourceOrder < rhs.sourceOrder
        }
    }

    private static func writingDirection(
        for fragments: [PdfLayoutFragment]
    ) -> PdfLayoutWritingDirection {
        var rtl = 0
        var ltr = 0

        for fragment in fragments {
            for scalar in fragment.text.unicodeScalars {
                if isRTLScalar(scalar) {
                    rtl += 1
                } else if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                    ltr += 1
                }
            }
        }

        return rtl > ltr ? .rightToLeft : .leftToRight
    }

    private static func estimatedCharacterWidth(_ fragment: PdfLayoutFragment) -> CGFloat {
        let count = max(1, fragment.text.unicodeScalars.reduce(into: 0) { total, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                total += 1
            }
        })
        return max(0.001, fragment.rect.width / CGFloat(count))
    }

    private static func isValid(_ fragment: PdfLayoutFragment) -> Bool {
        !fragment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && fragment.rect.minX.isFinite
            && fragment.rect.minY.isFinite
            && fragment.rect.width.isFinite
            && fragment.rect.height.isFinite
            && fragment.rect.width > 0
            && fragment.rect.height > 0
    }

    private static func verticalSourceOrder(
        _ lhs: PdfLayoutFragment,
        _ rhs: PdfLayoutFragment
    ) -> Bool {
        if abs(lhs.rect.midY - rhs.rect.midY) > 0.000_001 {
            return lhs.rect.midY < rhs.rect.midY
        }
        if abs(lhs.rect.minX - rhs.rect.minX) > 0.000_001 {
            return lhs.rect.minX < rhs.rect.minX
        }
        return lhs.sourceOrder < rhs.sourceOrder
    }

    private static func verticalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }

    private static func horizontalDistanceToRect(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        if lhs.maxX < rhs.minX { return rhs.minX - lhs.maxX }
        if rhs.maxX < lhs.minX { return lhs.minX - rhs.maxX }
        return 0
    }

    private static func trimmedFragmentText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        ",.;:!?)]}%、。，！？；：》】」』…".contains(character)
    }

    private static func isOpeningPunctuation(_ character: Character) -> Bool {
        "([{“‘《【「『".contains(character)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0x3040...0x30FF,
                 0x31F0...0x31FF,
                 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }

    private static func isRTLScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF,
             0x0600...0x06FF,
             0x0750...0x077F,
             0x08A0...0x08FF,
             0xFB50...0xFDFF,
             0xFE70...0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func unionRect(_ rects: [CGRect]) -> CGRect {
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
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
