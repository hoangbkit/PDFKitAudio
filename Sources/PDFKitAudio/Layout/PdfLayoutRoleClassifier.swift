import Foundation

enum PdfLayoutRoleClassifier {
    static func analyze(
        blocks: [PdfLayoutBlock],
        layout: PdfPageRegionLayout
    ) -> PdfSpecialStructureAnalysis {
        let valid = blocks.filter { block in
            !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && block.rect.minX.isFinite
                && block.rect.minY.isFinite
                && block.rect.width.isFinite
                && block.rect.height.isFinite
                && block.rect.width > 0
                && block.rect.height > 0
        }
        guard !valid.isEmpty else {
            return PdfSpecialStructureAnalysis(
                assignments: [],
                tables: [],
                readingOrderHints: PdfReadingOrderHints()
            )
        }

        let pageMedianFont = median(valid.compactMap(blockFontSize))
        let tables = detectTables(blocks: valid)
        let tableBlockIDs = tables.reduce(into: Set<Int>()) { result, table in
            result.formUnion(table.blockIDs)
        }
        let sidebarIDs = Set(layout.sidebarBlockIDs)
        let bottomSmallCount = valid.filter {
            isBottomSmallBlock($0, pageMedianFont: pageMedianFont)
        }.count
        let hasBottomSeparator = valid.contains { block in
            block.rect.minY >= 0.65 && looksLikeSeparator(block.text)
        }

        var assignments: [PdfLayoutRoleAssignment] = []
        assignments.reserveCapacity(valid.count)

        for block in valid.sorted(by: stableBlockOrder) {
            if tableBlockIDs.contains(block.id) {
                assignments.append(PdfLayoutRoleAssignment(
                    blockID: block.id,
                    role: .tableCell,
                    confidence: tables.filter { $0.blockIDs.contains(block.id) }.map(\.confidence).max() ?? 0.82,
                    signals: ["block contributes one or more cells to a repeated row/X-lane table grid"]
                ))
                continue
            }

            if sidebarIDs.contains(block.id) {
                assignments.append(PdfLayoutRoleAssignment(
                    blockID: block.id,
                    role: .sidebar,
                    confidence: 0.96,
                    signals: ["Phase 4 region model identified a sparse side lane"]
                ))
                continue
            }

            if beginsListItem(block.text) {
                assignments.append(PdfLayoutRoleAssignment(
                    blockID: block.id,
                    role: .listItem,
                    confidence: 0.96,
                    signals: ["explicit bullet/number/list prefix"]
                ))
                continue
            }

            let footnote = footnoteScore(
                block,
                blocks: valid,
                pageMedianFont: pageMedianFont,
                bottomSmallCount: bottomSmallCount,
                hasBottomSeparator: hasBottomSeparator
            )
            if footnote.score >= 0.72 {
                assignments.append(PdfLayoutRoleAssignment(
                    blockID: block.id,
                    role: .footnote,
                    confidence: footnote.score,
                    signals: footnote.signals
                ))
                continue
            }

            let heading = headingScore(block, blocks: valid, pageMedianFont: pageMedianFont)
            if heading.score >= 0.70 {
                assignments.append(PdfLayoutRoleAssignment(
                    blockID: block.id,
                    role: .heading,
                    confidence: heading.score,
                    signals: heading.signals
                ))
                continue
            }

            let caption = captionScore(block, blocks: valid, pageMedianFont: pageMedianFont)
            if caption.score >= 0.72 {
                assignments.append(PdfLayoutRoleAssignment(
                    blockID: block.id,
                    role: .caption,
                    confidence: caption.score,
                    signals: caption.signals
                ))
                continue
            }

            let pullQuote = pullQuoteScore(block, pageMedianFont: pageMedianFont)
            if pullQuote.score >= 0.72 {
                assignments.append(PdfLayoutRoleAssignment(
                    blockID: block.id,
                    role: .pullQuote,
                    confidence: pullQuote.score,
                    signals: pullQuote.signals
                ))
                continue
            }

            assignments.append(PdfLayoutRoleAssignment(
                blockID: block.id,
                role: .body,
                confidence: 0.72,
                signals: ["no special-structure score crossed a conservative threshold"]
            ))
        }

        let roleByID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.blockID, $0) })
        let footnoteIDs = Set(assignments.filter { $0.role == .footnote }.map(\.blockID))
        let captionAttachments = assignments
            .filter { $0.role == .caption }
            .compactMap { assignment -> PdfReadingOrderAttachment? in
                guard let caption = valid.first(where: { $0.id == assignment.blockID }),
                      let anchor = nearestCaptionAnchor(
                        to: caption,
                        blocks: valid,
                        roleByID: roleByID
                      ) else {
                    return nil
                }
                return PdfReadingOrderAttachment(
                    blockID: caption.id,
                    anchorBlockID: anchor.id,
                    confidence: min(0.95, assignment.confidence)
                )
            }

        let headingEdges = assignments
            .filter { $0.role == .heading && $0.confidence >= 0.80 }
            .compactMap { assignment -> PdfReadingOrderEdge? in
                guard let heading = valid.first(where: { $0.id == assignment.blockID }),
                      let next = valid
                        .filter({ $0.id != heading.id && $0.rect.minY >= heading.rect.maxY - 0.005 })
                        .sorted(by: stableBlockOrder)
                        .first else {
                    return nil
                }
                return PdfReadingOrderEdge(
                    fromBlockID: heading.id,
                    toBlockID: next.id,
                    confidence: min(0.90, assignment.confidence),
                    reason: .semanticHint
                )
            }

        let unknownIDs = Set(assignments.filter { $0.role == .unknown }.map(\.blockID))
        return PdfSpecialStructureAnalysis(
            assignments: assignments,
            tables: tables,
            readingOrderHints: PdfReadingOrderHints(
                footnoteBlockIDs: footnoteIDs,
                captionAttachments: captionAttachments,
                additionalPrecedence: headingEdges,
                unknownBlockIDs: unknownIDs
            )
        )
    }

    private struct Score {
        var score: Double
        var signals: [String]

        mutating func add(_ value: Double, _ signal: String) {
            score += value
            signals.append(signal)
        }

        var clamped: Score {
            Score(score: min(1, max(0, score)), signals: signals)
        }
    }

    private static func headingScore(
        _ block: PdfLayoutBlock,
        blocks: [PdfLayoutBlock],
        pageMedianFont: CGFloat
    ) -> Score {
        var result = Score(score: 0.05, signals: [])
        let textLength = semanticCharacterCount(block.text)
        let font = blockFontSize(block) ?? 0

        if pageMedianFont > 0, font >= pageMedianFont * 1.18 {
            result.add(0.38, "font size is materially larger than page median")
        }
        if block.lines.contains(where: { $0.isPredominantlyBold == true }) {
            result.add(0.20, "bold/emphasized line style")
        }
        if textLength <= 90 {
            result.add(0.12, "short heading-like text")
        }
        if abs(block.rect.midX - 0.5) <= 0.16 {
            result.add(0.10, "approximately centered placement")
        }
        if block.rect.minY <= 0.25 {
            result.add(0.08, "appears near the start of a page/region")
        }
        let gap = surroundingWhitespace(block, blocks: blocks)
        if gap.before >= 0.04 || gap.after >= 0.06 {
            result.add(0.10, "strong surrounding vertical whitespace")
        }
        return result.clamped
    }

    private static func captionScore(
        _ block: PdfLayoutBlock,
        blocks: [PdfLayoutBlock],
        pageMedianFont: CGFloat
    ) -> Score {
        var result = Score(score: 0.02, signals: [])
        let font = blockFontSize(block) ?? 0
        let length = semanticCharacterCount(block.text)
        let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if pageMedianFont > 0, font > 0, font <= pageMedianFont * 0.84 {
            result.add(0.30, "smaller text than page body")
        }
        if length <= 140 {
            result.add(0.12, "caption-length text")
        }
        if abs(block.rect.midX - 0.5) <= 0.18 {
            result.add(0.14, "centered/aligned figure-caption placement")
        }
        if block.rect.minY < 0.74 {
            result.add(0.08, "not concentrated in the page-bottom footnote zone")
        }
        if trimmed.hasPrefix("figure ") || trimmed.hasPrefix("fig. ")
            || trimmed.hasPrefix("table ") || trimmed.hasPrefix("caption ") {
            result.add(0.32, "explicit figure/table/caption prefix")
        }
        let gap = surroundingWhitespace(block, blocks: blocks)
        if min(gap.before, gap.after) <= 0.18 {
            result.add(0.08, "geometrically close to a neighboring anchor region")
        }
        return result.clamped
    }

    private static func footnoteScore(
        _ block: PdfLayoutBlock,
        blocks: [PdfLayoutBlock],
        pageMedianFont: CGFloat,
        bottomSmallCount: Int,
        hasBottomSeparator: Bool
    ) -> Score {
        var result = Score(score: 0.02, signals: [])
        let font = blockFontSize(block) ?? 0
        let length = semanticCharacterCount(block.text)
        let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard block.rect.minY >= 0.70 else { return result }
        result.add(0.24, "concentrated in bottom page zone")

        if pageMedianFont > 0, font > 0, font <= pageMedianFont * 0.78 {
            result.add(0.30, "font is substantially smaller than page median")
        }
        if length <= 220 {
            result.add(0.08, "short footnote-like text")
        }
        if block.rect.minY >= 0.76 {
            result.add(0.08, "deep bottom-zone placement")
        }
        if bottomSmallCount >= 2 {
            result.add(0.10, "multiple small bottom-zone blocks form a footnote region")
        }
        if hasBottomSeparator {
            result.add(0.10, "bottom separator/rule evidence")
        }
        if beginsReferenceMarker(trimmed) {
            result.add(0.14, "reference-marker prefix")
        }
        let gap = surroundingWhitespace(block, blocks: blocks)
        if gap.before >= 0.18 {
            result.add(0.08, "large separation from main body")
        }
        return result.clamped
    }

    private static func pullQuoteScore(
        _ block: PdfLayoutBlock,
        pageMedianFont: CGFloat
    ) -> Score {
        var result = Score(score: 0.02, signals: [])
        let font = blockFontSize(block) ?? 0
        if block.rect.width <= 0.35 {
            result.add(0.24, "narrow isolated block")
        }
        if abs(block.rect.midX - 0.5) <= 0.14 {
            result.add(0.24, "centered side-callout placement")
        }
        if pageMedianFont > 0, font > 0, font <= pageMedianFont * 0.90 {
            result.add(0.16, "slightly smaller than body text")
        }
        if semanticCharacterCount(block.text) <= 160 {
            result.add(0.10, "short pull-quote/callout length")
        }
        return result.clamped
    }

    private static func detectTables(blocks: [PdfLayoutBlock]) -> [PdfDetectedTable] {
        let fragments = blocks.flatMap { $0.lines.flatMap(\.fragments) }
        let assessment = PdfLayoutComplexityDetector.assess(fragments: fragments)
        guard assessment.complexity == .likelyTableHeavy else { return [] }

        let cells = blocks.flatMap { block in
            block.lines.map { line in
                PdfTableCell(blockID: block.id, lineID: line.id, text: line.text, rect: line.rect)
            }
        }
        guard cells.count >= 4 else { return [] }

        let medianHeight = median(cells.map { $0.rect.height })
        let tolerance = max(0.012, min(0.035, medianHeight * 0.80))
        let rows = clusterRows(cells, tolerance: tolerance)
            .filter { $0.count >= 2 }
            .map { $0.sorted { $0.rect.minX < $1.rect.minX } }
        guard rows.count >= 2 else { return [] }

        let counts = rows.map(\.count)
        let columnCount = mode(counts) ?? counts.max() ?? 0
        guard columnCount >= 2 else { return [] }
        let stableRows = rows.filter { abs($0.count - columnCount) <= 1 }
        guard stableRows.count >= 2 else { return [] }

        let aligned = columnAlignmentScore(rows: stableRows, expectedColumns: columnCount)
        guard aligned >= 0.70 else { return [] }

        let headerIndex = detectHeaderRow(stableRows)
        let linearized = PdfTableLinearizer.linearize(rows: stableRows, headerRowIndex: headerIndex)
        let confidence = min(
            0.97,
            max(0.72, assessment.confidence * 0.70 + aligned * 0.30)
        )
        return [PdfDetectedTable(
            cellsByRow: stableRows,
            columnCount: columnCount,
            headerRowIndex: headerIndex,
            confidence: confidence,
            linearizedText: linearized
        )]
    }

    private static func detectHeaderRow(_ rows: [[PdfTableCell]]) -> Int? {
        guard rows.count >= 2 else { return nil }
        let first = rows[0]
        guard !first.isEmpty else { return nil }

        let firstLines = first.compactMap { cell in
            // Cell line IDs are page-unique but not enough to recover style here;
            // explicit header vocabulary remains a weak fallback only. Style-based
            // detection is performed by matching through the block lines below.
            cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let headerVocabulary = firstLines.filter { text in
            let lower = text.lowercased()
            return lower.contains("name") || lower.contains("revenue")
                || lower.contains("growth") || lower.contains("date")
                || lower.contains("total") || lower.contains("amount")
        }.count
        if headerVocabulary * 2 >= first.count { return 0 }
        return nil
    }

    private static func nearestCaptionAnchor(
        to caption: PdfLayoutBlock,
        blocks: [PdfLayoutBlock],
        roleByID: [Int: PdfLayoutRoleAssignment]
    ) -> PdfLayoutBlock? {
        blocks
            .filter { candidate in
                candidate.id != caption.id
                    && roleByID[candidate.id]?.role != .caption
                    && roleByID[candidate.id]?.role != .footnote
                    && roleByID[candidate.id]?.role != .sidebar
            }
            .min { lhs, rhs in
                captionDistance(caption, lhs) < captionDistance(caption, rhs)
            }
    }

    private static func captionDistance(_ caption: PdfLayoutBlock, _ candidate: PdfLayoutBlock) -> CGFloat {
        let vertical: CGFloat
        if candidate.rect.maxY <= caption.rect.minY {
            vertical = caption.rect.minY - candidate.rect.maxY
        } else if caption.rect.maxY <= candidate.rect.minY {
            vertical = candidate.rect.minY - caption.rect.maxY
        } else {
            vertical = 0
        }
        return vertical + abs(caption.rect.midX - candidate.rect.midX) * 0.25
    }

    private static func isBottomSmallBlock(_ block: PdfLayoutBlock, pageMedianFont: CGFloat) -> Bool {
        guard block.rect.minY >= 0.70,
              pageMedianFont > 0,
              let font = blockFontSize(block), font > 0 else { return false }
        return font <= pageMedianFont * 0.80
    }

    private static func blockFontSize(_ block: PdfLayoutBlock) -> CGFloat? {
        let values = block.lines.compactMap(\.medianFontSize).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    private static func surroundingWhitespace(
        _ block: PdfLayoutBlock,
        blocks: [PdfLayoutBlock]
    ) -> (before: CGFloat, after: CGFloat) {
        let before = blocks
            .filter { $0.id != block.id && $0.rect.maxY <= block.rect.minY }
            .map { block.rect.minY - $0.rect.maxY }
            .min() ?? block.rect.minY
        let after = blocks
            .filter { $0.id != block.id && $0.rect.minY >= block.rect.maxY }
            .map { $0.rect.minY - block.rect.maxY }
            .min() ?? max(0, 1 - block.rect.maxY)
        return (before, after)
    }

    private static func beginsListItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        if "•◦▪▫‣⁃-*–—".contains(first) { return true }

        var index = trimmed.startIndex
        var digits = 0
        while index < trimmed.endIndex, trimmed[index].isNumber, digits < 4 {
            digits += 1
            index = trimmed.index(after: index)
        }
        if digits > 0, index < trimmed.endIndex, ".)]:".contains(trimmed[index]) {
            return true
        }
        if trimmed.count >= 2 {
            let prefix = Array(trimmed.prefix(2))
            if prefix[0].isLetter && ".)".contains(prefix[1]) { return true }
        }
        return false
    }

    private static func beginsReferenceMarker(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if first.isNumber || "*†‡".contains(first) { return true }
        return false
    }

    private static func looksLikeSeparator(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        let separatorCount = scalars.filter { scalar in
            "-—–_·•".unicodeScalars.contains(scalar)
        }.count
        return separatorCount >= 4 && semanticCharacterCount(text) <= 40
    }

    private static func clusterRows(
        _ cells: [PdfTableCell],
        tolerance: CGFloat
    ) -> [[PdfTableCell]] {
        var rows: [[PdfTableCell]] = []
        for cell in cells.sorted(by: { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) > 0.000_001 { return lhs.rect.midY < rhs.rect.midY }
            return lhs.rect.minX < rhs.rect.minX
        }) {
            if let index = rows.indices.min(by: { lhs, rhs in
                abs(rowMidY(rows[lhs]) - cell.rect.midY) < abs(rowMidY(rows[rhs]) - cell.rect.midY)
            }), abs(rowMidY(rows[index]) - cell.rect.midY) <= tolerance {
                rows[index].append(cell)
            } else {
                rows.append([cell])
            }
        }
        return rows.sorted { rowMidY($0) < rowMidY($1) }
    }

    private static func columnAlignmentScore(
        rows: [[PdfTableCell]],
        expectedColumns: Int
    ) -> Double {
        guard rows.count >= 2, expectedColumns >= 2 else { return 0 }
        let usable = rows.filter { $0.count == expectedColumns }
        guard usable.count >= 2 else { return 0.65 }

        var scores: [Double] = []
        for column in 0..<expectedColumns {
            let xs = usable.map { $0[column].rect.minX }
            guard let minX = xs.min(), let maxX = xs.max() else { continue }
            let spread = maxX - minX
            scores.append(max(0, 1 - Double(spread / 0.05)))
        }
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0, +) / Double(scores.count)
    }

    private static func rowMidY(_ row: [PdfTableCell]) -> CGFloat {
        guard !row.isEmpty else { return 0 }
        return row.map { $0.rect.midY }.reduce(0, +) / CGFloat(row.count)
    }

    private static func mode(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key > $1.key
        }.first?.key
    }

    private static func semanticCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                count += 1
            }
        }
    }

    private static func stableBlockOrder(_ lhs: PdfLayoutBlock, _ rhs: PdfLayoutBlock) -> Bool {
        if abs(lhs.rect.minY - rhs.rect.minY) > 0.000_001 { return lhs.rect.minY < rhs.rect.minY }
        if abs(lhs.rect.minX - rhs.rect.minX) > 0.000_001 { return lhs.rect.minX < rhs.rect.minX }
        if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
        return lhs.id < rhs.id
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
