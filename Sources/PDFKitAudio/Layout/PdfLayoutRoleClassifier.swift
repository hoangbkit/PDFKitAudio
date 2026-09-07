import Foundation

enum PdfLayoutRoleClassifier {
    static func analyze(
        blocks: [PdfLayoutBlock],
        layout: PdfPageRegionLayout
    ) -> PdfSpecialStructureAnalysis {
        let valid = blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !valid.isEmpty else {
            return PdfSpecialStructureAnalysis(assignments: [], tables: [], readingOrderHints: PdfReadingOrderHints())
        }

        let pageMedianFont = median(valid.compactMap(blockFontSize))
        let tables = detectTables(blocks: valid)
        let tableBlockIDs = tables.reduce(into: Set<Int>()) { $0.formUnion($1.blockIDs) }
        let sidebarIDs = Set(layout.sidebarBlockIDs)
        let bottomSmallCount = valid.filter { isBottomSmall($0, medianFont: pageMedianFont) }.count
        let hasBottomRule = valid.contains { $0.rect.minY >= 0.65 && looksLikeSeparator($0.text) }

        var assignments: [PdfLayoutRoleAssignment] = []
        for block in valid.sorted(by: stableBlockOrder) {
            if tableBlockIDs.contains(block.id) {
                assignments.append(.init(blockID: block.id, role: .tableCell, confidence: tables.filter { $0.blockIDs.contains(block.id) }.map(\.confidence).max() ?? 0.82, signals: ["repeated aligned table grid"]))
                continue
            }
            if sidebarIDs.contains(block.id) {
                assignments.append(.init(blockID: block.id, role: .sidebar, confidence: 0.96, signals: ["Phase 4 sparse side-lane assignment"]))
                continue
            }
            if beginsListItem(block.text) {
                assignments.append(.init(blockID: block.id, role: .listItem, confidence: 0.96, signals: ["explicit list marker"])); continue
            }

            let footnote = footnoteScore(block, blocks: valid, medianFont: pageMedianFont, bottomSmallCount: bottomSmallCount, hasBottomRule: hasBottomRule)
            if footnote.score >= 0.72 {
                assignments.append(.init(blockID: block.id, role: .footnote, confidence: footnote.score, signals: footnote.signals)); continue
            }

            let heading = headingScore(block, blocks: valid, medianFont: pageMedianFont)
            if heading.score >= 0.70 {
                assignments.append(.init(blockID: block.id, role: .heading, confidence: heading.score, signals: heading.signals)); continue
            }

            let caption = captionScore(block, medianFont: pageMedianFont)
            if caption.score >= 0.72 {
                assignments.append(.init(blockID: block.id, role: .caption, confidence: caption.score, signals: caption.signals)); continue
            }

            let pullQuote = pullQuoteScore(block, medianFont: pageMedianFont)
            if pullQuote.score >= 0.72 {
                assignments.append(.init(blockID: block.id, role: .pullQuote, confidence: pullQuote.score, signals: pullQuote.signals)); continue
            }

            assignments.append(.init(blockID: block.id, role: .body, confidence: 0.72, signals: ["no special role crossed conservative threshold"]))
        }

        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.blockID, $0) })
        let footnoteIDs = Set(assignments.filter { $0.role == .footnote }.map(\.blockID))
        let captionAttachments = assignments.filter { $0.role == .caption }.compactMap { assignment -> PdfReadingOrderAttachment? in
            guard let caption = valid.first(where: { $0.id == assignment.blockID }),
                  let anchor = nearestCaptionAnchor(to: caption, blocks: valid, roles: byID) else { return nil }
            return PdfReadingOrderAttachment(blockID: caption.id, anchorBlockID: anchor.id, confidence: min(0.95, assignment.confidence))
        }
        let headingEdges = assignments.filter { $0.role == .heading && $0.confidence >= 0.80 }.compactMap { assignment -> PdfReadingOrderEdge? in
            guard let heading = valid.first(where: { $0.id == assignment.blockID }),
                  let next = valid.filter({ $0.id != heading.id && $0.rect.minY >= heading.rect.maxY - 0.005 }).sorted(by: stableBlockOrder).first else { return nil }
            return PdfReadingOrderEdge(fromBlockID: heading.id, toBlockID: next.id, confidence: min(0.90, assignment.confidence), reason: .semanticHint)
        }

        return PdfSpecialStructureAnalysis(
            assignments: assignments,
            tables: tables,
            readingOrderHints: PdfReadingOrderHints(
                footnoteBlockIDs: footnoteIDs,
                captionAttachments: captionAttachments,
                additionalPrecedence: headingEdges,
                unknownBlockIDs: []
            )
        )
    }

    private struct Score {
        var score: Double = 0
        var signals: [String] = []
        mutating func add(_ value: Double, _ signal: String) { score += value; signals.append(signal) }
        var final: Score { Score(score: min(1, max(0, score)), signals: signals) }
    }

    private static func headingScore(_ block: PdfLayoutBlock, blocks: [PdfLayoutBlock], medianFont: CGFloat) -> Score {
        var s = Score(score: 0.05)
        let font = blockFontSize(block) ?? 0
        if medianFont > 0 && font >= medianFont * 1.18 { s.add(0.38, "larger than page median") }
        if block.lines.contains(where: { $0.isPredominantlyBold == true }) { s.add(0.20, "bold/emphasized") }
        if semanticCount(block.text) <= 90 { s.add(0.12, "short text") }
        if abs(block.rect.midX - 0.5) <= 0.16 { s.add(0.10, "centered") }
        if block.rect.minY <= 0.25 { s.add(0.08, "near region/page start") }
        let gaps = surroundingWhitespace(block, blocks: blocks)
        if gaps.before >= 0.04 || gaps.after >= 0.06 { s.add(0.10, "surrounding whitespace") }
        return s.final
    }

    private static func captionScore(_ block: PdfLayoutBlock, medianFont: CGFloat) -> Score {
        var s = Score(score: 0.02)
        let font = blockFontSize(block) ?? 0
        let lower = block.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let explicit = lower.hasPrefix("figure ") || lower.hasPrefix("fig. ") || lower.hasPrefix("table ") || lower.hasPrefix("caption ")
        if explicit { s.add(0.40, "explicit caption prefix") }
        if medianFont > 0 && font > 0 && font <= medianFont * 0.84 { s.add(0.30, "smaller than body") }
        if semanticCount(block.text) <= 140 { s.add(0.10, "caption-length text") }
        if abs(block.rect.midX - 0.5) <= 0.18 { s.add(0.10, "centered/aligned") }
        if block.rect.minY >= 0.55 && block.rect.minY < 0.74 { s.add(0.22, "typical below-figure/caption vertical zone") }
        return s.final
    }

    private static func pullQuoteScore(_ block: PdfLayoutBlock, medianFont: CGFloat) -> Score {
        var s = Score(score: 0.02)
        let font = blockFontSize(block) ?? 0
        if block.rect.minY < 0.60 { s.add(0.12, "inside body region rather than caption zone") }
        if block.rect.width <= 0.35 { s.add(0.24, "narrow isolated block") }
        if abs(block.rect.midX - 0.5) <= 0.14 { s.add(0.24, "centered callout placement") }
        if medianFont > 0 && font > 0 && font <= medianFont * 0.90 { s.add(0.16, "slightly smaller than body") }
        if semanticCount(block.text) <= 160 { s.add(0.10, "short callout text") }
        return s.final
    }

    private static func footnoteScore(_ block: PdfLayoutBlock, blocks: [PdfLayoutBlock], medianFont: CGFloat, bottomSmallCount: Int, hasBottomRule: Bool) -> Score {
        var s = Score(score: 0.02)
        guard block.rect.minY >= 0.70 else { return s }
        let font = blockFontSize(block) ?? 0
        s.add(0.24, "bottom page zone")
        if medianFont > 0 && font > 0 && font <= medianFont * 0.78 { s.add(0.30, "substantially smaller font") }
        if semanticCount(block.text) <= 220 { s.add(0.08, "short note text") }
        if block.rect.minY >= 0.76 { s.add(0.08, "deep bottom placement") }
        if bottomSmallCount >= 2 { s.add(0.10, "cluster of small bottom blocks") }
        if hasBottomRule { s.add(0.10, "separator/rule evidence") }
        if beginsReferenceMarker(block.text) { s.add(0.14, "reference marker") }
        if surroundingWhitespace(block, blocks: blocks).before >= 0.18 { s.add(0.08, "large body separation") }
        return s.final
    }

    private static func detectTables(blocks: [PdfLayoutBlock]) -> [PdfDetectedTable] {
        let fragments = blocks.flatMap { $0.lines.flatMap(\.fragments) }
        let assessment = PdfLayoutComplexityDetector.assess(fragments: fragments)
        let cells = blocks.flatMap { block in block.lines.map { PdfTableCell(blockID: block.id, lineID: $0.id, text: $0.text, rect: $0.rect) } }
        guard cells.count >= 4 else { return [] }

        let tolerance = max(0.012, min(0.035, median(cells.map { $0.rect.height }) * 0.80))
        let rows = clusterRows(cells, tolerance: tolerance).filter { $0.count >= 2 }.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
        guard rows.count >= 2 else { return [] }
        let maximumItems = rows.map(\.count).max() ?? 0
        let phase2Table = assessment.complexity == .likelyTableHeavy
        let obviousThreeLaneGrid = maximumItems >= 3 && rows.filter { $0.count >= 3 }.count >= 2
        guard phase2Table || obviousThreeLaneGrid else { return [] }

        let columnCount = mode(rows.map(\.count)) ?? maximumItems
        guard columnCount >= 2 else { return [] }
        let stableRows = rows.filter { abs($0.count - columnCount) <= 1 }
        guard stableRows.count >= 2 else { return [] }
        let alignment = columnAlignmentScore(rows: stableRows, expectedColumns: columnCount)
        guard alignment >= 0.68 else { return [] }

        let headerIndex = detectHeaderRow(stableRows, blocks: blocks)
        let linearized = PdfTableLinearizer.linearize(rows: stableRows, headerRowIndex: headerIndex)
        let base = phase2Table ? assessment.confidence : 0.78
        let confidence = min(0.97, max(0.72, base * 0.70 + alignment * 0.30))
        return [PdfDetectedTable(cellsByRow: stableRows, columnCount: columnCount, headerRowIndex: headerIndex, confidence: confidence, linearizedText: linearized)]
    }

    private static func detectHeaderRow(_ rows: [[PdfTableCell]], blocks: [PdfLayoutBlock]) -> Int? {
        guard rows.count >= 2, let first = rows.first, !first.isEmpty else { return nil }
        let lineBold: [Int: Bool] = Dictionary(uniqueKeysWithValues: blocks.flatMap { block in block.lines.map { ($0.id, $0.isPredominantlyBold == true) } })
        let boldCount = first.filter { lineBold[$0.lineID] == true }.count
        if boldCount == first.count { return 0 }

        let vocabularyCount = first.filter { cell in
            let lower = cell.text.lowercased()
            return lower.contains("name") || lower.contains("revenue") || lower.contains("growth") || lower.contains("date") || lower.contains("total") || lower.contains("amount")
        }.count
        return vocabularyCount * 2 >= first.count ? 0 : nil
    }

    private static func nearestCaptionAnchor(to caption: PdfLayoutBlock, blocks: [PdfLayoutBlock], roles: [Int: PdfLayoutRoleAssignment]) -> PdfLayoutBlock? {
        blocks.filter {
            $0.id != caption.id && roles[$0.id]?.role != .caption && roles[$0.id]?.role != .footnote && roles[$0.id]?.role != .sidebar
        }.min { captionDistance(caption, $0) < captionDistance(caption, $1) }
    }

    private static func captionDistance(_ caption: PdfLayoutBlock, _ candidate: PdfLayoutBlock) -> CGFloat {
        let vertical: CGFloat
        if candidate.rect.maxY <= caption.rect.minY { vertical = caption.rect.minY - candidate.rect.maxY }
        else if caption.rect.maxY <= candidate.rect.minY { vertical = candidate.rect.minY - caption.rect.maxY }
        else { vertical = 0 }
        return vertical + abs(caption.rect.midX - candidate.rect.midX) * 0.25
    }

    private static func clusterRows(_ cells: [PdfTableCell], tolerance: CGFloat) -> [[PdfTableCell]] {
        var rows: [[PdfTableCell]] = []
        for cell in cells.sorted(by: { $0.rect.midY == $1.rect.midY ? $0.rect.minX < $1.rect.minX : $0.rect.midY < $1.rect.midY }) {
            if let index = rows.indices.min(by: { abs(rowMidY(rows[$0]) - cell.rect.midY) < abs(rowMidY(rows[$1]) - cell.rect.midY) }), abs(rowMidY(rows[index]) - cell.rect.midY) <= tolerance {
                rows[index].append(cell)
            } else { rows.append([cell]) }
        }
        return rows.sorted { rowMidY($0) < rowMidY($1) }
    }

    private static func columnAlignmentScore(rows: [[PdfTableCell]], expectedColumns: Int) -> Double {
        let usable = rows.filter { $0.count == expectedColumns }
        guard usable.count >= 2 else { return 0.68 }
        var scores: [Double] = []
        for c in 0..<expectedColumns {
            let xs = usable.map { $0[c].rect.minX }
            guard let minX = xs.min(), let maxX = xs.max() else { continue }
            scores.append(max(0, 1 - Double((maxX - minX) / 0.05)))
        }
        return scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
    }

    private static func mode(_ values: [Int]) -> Int? {
        var counts: [Int: Int] = [:]
        values.forEach { counts[$0, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key > $1.key : $0.value > $1.value }.first?.key
    }

    private static func blockFontSize(_ block: PdfLayoutBlock) -> CGFloat? { medianOptional(block.lines.compactMap(\.medianFontSize)) }
    private static func isBottomSmall(_ block: PdfLayoutBlock, medianFont: CGFloat) -> Bool { block.rect.minY >= 0.70 && (blockFontSize(block) ?? .greatestFiniteMagnitude) <= medianFont * 0.80 }
    private static func beginsReferenceMarker(_ text: String) -> Bool { guard let c = text.trimmingCharacters(in: .whitespacesAndNewlines).first else { return false }; return c.isNumber || "*†‡".contains(c) }
    private static func looksLikeSeparator(_ text: String) -> Bool { text.filter { "-—–_·•".contains($0) }.count >= 4 && semanticCount(text) <= 40 }
    private static func rowMidY(_ row: [PdfTableCell]) -> CGFloat { row.isEmpty ? 0 : row.map { $0.rect.midY }.reduce(0, +) / CGFloat(row.count) }
    private static func semanticCount(_ text: String) -> Int { text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count }

    private static func beginsListItem(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return false }
        if "•◦▪▫‣⁃-*–—".contains(first) { return true }
        var i = t.startIndex; var digits = 0
        while i < t.endIndex && t[i].isNumber && digits < 4 { digits += 1; i = t.index(after: i) }
        if digits > 0 && i < t.endIndex && ".)]:".contains(t[i]) { return true }
        if t.count >= 2 { let p = Array(t.prefix(2)); if p[0].isLetter && ".)".contains(p[1]) { return true } }
        return false
    }

    private static func surroundingWhitespace(_ block: PdfLayoutBlock, blocks: [PdfLayoutBlock]) -> (before: CGFloat, after: CGFloat) {
        let before = blocks.filter { $0.id != block.id && $0.rect.maxY <= block.rect.minY }.map { block.rect.minY - $0.rect.maxY }.min() ?? block.rect.minY
        let after = blocks.filter { $0.id != block.id && $0.rect.minY >= block.rect.maxY }.map { $0.rect.minY - block.rect.maxY }.min() ?? max(0, 1 - block.rect.maxY)
        return (before, after)
    }

    private static func stableBlockOrder(_ a: PdfLayoutBlock, _ b: PdfLayoutBlock) -> Bool {
        if abs(a.rect.minY - b.rect.minY) > 0.000_001 { return a.rect.minY < b.rect.minY }
        if abs(a.rect.minX - b.rect.minX) > 0.000_001 { return a.rect.minX < b.rect.minX }
        if a.sourceOrder != b.sourceOrder { return a.sourceOrder < b.sourceOrder }
        return a.id < b.id
    }

    private static func median(_ values: [CGFloat]) -> CGFloat { medianOptional(values) ?? 0 }
    private static func medianOptional(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted(); let m = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}
