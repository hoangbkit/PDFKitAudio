import Foundation

/// Page-local orchestration for the geometry-first layout pipeline.
///
/// This type deliberately returns only selected text plus compact document-level
/// fingerprints. Full fragment/line/block graphs die with the page so parser
/// memory remains bounded for long documents.
enum PdfLayoutAnalyzer {
    struct Result {
        let text: String
        let fingerprints: [PdfDocumentLayoutFingerprint]
        let assessment: PdfLayoutComplexityAssessment
        let readingOrder: PdfReadingOrderResult
    }

    private static let minimumReadingOrderConfidence = 0.62
    private static let minimumInformationRatio = 0.72
    private static let maximumInformationRatio = 2.20
    private static let minimumSimpleRepairConfidence = 0.82

    static func analyze(
        fragments: [PdfLayoutFragment],
        nativeText: String,
        nativeTextThreshold: Int,
        pageIndex: Int,
        mode: PdfLayoutMode,
        diagnostics: ((PdfLayoutDiagnostics.Snapshot) -> Void)? = nil,
        checkpoint: () throws -> Void = {}
    ) throws -> Result? {
        var diagnosticCapture = diagnostics.map { _ in
            PdfLayoutDiagnostics.Capture(pageIndex: pageIndex, mode: mode)
        }

        func finishDiagnostics(
            _ decision: PdfLayoutDiagnostics.Decision,
            reason: String
        ) {
            guard let diagnosticCapture else { return }
            diagnostics?(diagnosticCapture.snapshot(decision: decision, reason: reason))
        }

        guard mode != .never else {
            finishDiagnostics(.fastPath, reason: "Layout mode is .never; preserving legacy selected text without geometry analysis.")
            return nil
        }

        let positioned = PdfPositionedTextExtractor.deduplicated(fragments)
            .filter { fragment in
                !fragment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && fragment.rect.width > 0
                    && fragment.rect.height > 0
                    && fragment.rect.minX.isFinite
                    && fragment.rect.minY.isFinite
                    && fragment.rect.width.isFinite
                    && fragment.rect.height.isFinite
            }
        diagnosticCapture?.record(fragments: positioned)

        guard !positioned.isEmpty else {
            finishDiagnostics(.fallback, reason: "No usable positioned fragments were available; preserving selected text.")
            return nil
        }
        guard uniqueIDs(positioned.map(\.id)) else {
            finishDiagnostics(.fallback, reason: "Positioned fragment identifiers were not unique; preserving selected text.")
            return nil
        }

        let assessment = PdfLayoutComplexityDetector.assess(
            fragments: positioned,
            nativeText: nativeText,
            nativeTextThreshold: nativeTextThreshold
        )
        diagnosticCapture?.record(assessment: assessment)

        switch mode {
        case .never:
            finishDiagnostics(.fastPath, reason: "Layout mode is .never; preserving legacy selected text.")
            return nil
        case .auto:
            // Keep ordinary single-column pages on the exact legacy fast path.
            // A very small exception repairs an objectively broken PDF source
            // order when a high-confidence simple page contains a large vertical
            // backtrack (for example body text serialized before a title/header).
            guard assessment.shouldAnalyze
                    || shouldRepairSimpleOrder(fragments: positioned, assessment: assessment) else {
                finishDiagnostics(
                    .fastPath,
                    reason: "The conservative complexity gate kept this page on the legacy selected-text fast path."
                )
                return nil
            }
        case .always:
            break
        }

        try checkpoint()
        let lines = PdfLayoutLineBuilder.build(fragments: positioned)
        diagnosticCapture?.record(lines: lines)
        guard conservesFragments(positioned, in: lines) else {
            finishDiagnostics(.fallback, reason: "Line reconstruction failed exact fragment conservation.")
            return nil
        }

        let simpleColumns = PdfSimpleColumnLayout.resolve(lines: lines)
        let blocks = simpleColumns?.blocks ?? PdfLayoutBlockBuilder.build(lines: lines)
        diagnosticCapture?.record(blocks: blocks)
        guard !blocks.isEmpty else {
            finishDiagnostics(.fallback, reason: "Block reconstruction produced no readable blocks.")
            return nil
        }
        guard uniqueIDs(blocks.map(\.id)) else {
            finishDiagnostics(.fallback, reason: "Block identifiers were not unique.")
            return nil
        }
        guard conservesFragments(positioned, in: blocks) else {
            finishDiagnostics(.fallback, reason: "Block reconstruction failed exact fragment conservation.")
            return nil
        }

        try checkpoint()
        let layout = simpleColumns?.layout ?? PdfLayoutRegionDetector.segment(blocks: blocks)
        let rawSpecial = simpleColumns?.analysis ?? PdfLayoutRoleClassifier.analyze(blocks: blocks, layout: layout)
        let special = simpleColumns?.analysis ?? reconciledSpecialStructures(
            rawSpecial,
            assessment: assessment,
            blocks: blocks,
            layout: layout
        )
        diagnosticCapture?.record(layout: layout, analysis: special)

        guard Set(special.assignments.map(\.blockID)) == Set(blocks.map(\.id)),
              special.assignments.count == blocks.count else {
            finishDiagnostics(.fallback, reason: "Role classification did not annotate every reconstructed block exactly once.")
            return nil
        }

        let readingOrder = simpleColumns?.readingOrder ?? PdfReadingOrderResolver.resolve(
            blocks: blocks,
            layout: layout,
            hints: special.readingOrderHints
        )
        diagnosticCapture?.record(readingOrder: readingOrder)
        try checkpoint()

        let blockIDs = Set(blocks.map(\.id))
        guard !readingOrder.usedFallback else {
            finishDiagnostics(.fallback, reason: "Reading-order resolver used its geometric safety fallback.")
            return nil
        }
        guard readingOrder.confidence >= minimumReadingOrderConfidence else {
            finishDiagnostics(
                .fallback,
                reason: "Reading-order confidence \(readingOrder.confidence) was below the acceptance threshold \(minimumReadingOrderConfidence)."
            )
            return nil
        }
        guard readingOrder.orderedBlockIDs.count == blocks.count,
              Set(readingOrder.orderedBlockIDs) == blockIDs else {
            finishDiagnostics(.fallback, reason: "Reading-order resolution did not conserve every block exactly once.")
            return nil
        }

        let analyzedText = materialize(
            blocks: blocks,
            orderedBlockIDs: readingOrder.orderedBlockIDs,
            analysis: special
        )
        guard passesSanityChecks(
            output: analyzedText,
            fragments: positioned,
            blocks: blocks
        ) else {
            finishDiagnostics(.fallback, reason: "Analyzed output failed non-empty/information-ratio safety checks.")
            return nil
        }

        let fingerprints = PdfDocumentLayoutFingerprintBuilder.make(
            pageIndex: pageIndex,
            blocks: blocks,
            analysis: special
        )
        let result = Result(
            text: analyzedText,
            fingerprints: fingerprints,
            assessment: assessment,
            readingOrder: readingOrder
        )
        finishDiagnostics(.accepted, reason: simpleColumns == nil
            ? "Layout reconstruction passed all structural, confidence, and information-safety gates."
            : "Direct persistent-gutter column ordering passed all structural and information-safety gates.")
        return result
    }

    /// True only for a high-confidence single-column page whose source order has
    /// an unambiguous vertical reversal. This is intentionally narrower than the
    /// normal complexity gate so healthy book pages stay byte-for-byte legacy.
    static func shouldRepairSimpleOrder(
        fragments: [PdfLayoutFragment],
        assessment: PdfLayoutComplexityAssessment
    ) -> Bool {
        guard assessment.complexity == .simpleSingleColumn,
              assessment.confidence >= minimumSimpleRepairConfidence else {
            return false
        }

        let ordered = fragments
            .filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.rect.width > 0
                    && $0.rect.height > 0
                    && $0.rect.minX.isFinite
                    && $0.rect.minY.isFinite
                    && $0.rect.width.isFinite
                    && $0.rect.height.isFinite
            }
            .sorted {
                if $0.sourceOrder != $1.sourceOrder { return $0.sourceOrder < $1.sourceOrder }
                return $0.id < $1.id
            }
        guard ordered.count >= 2 else { return false }

        let medianHeight = median(ordered.map { $0.rect.height })
        let minimumBacktrack = max(0.035, min(0.10, medianHeight * 1.8))

        for index in 0..<(ordered.count - 1) {
            let first = ordered[index]
            let second = ordered[index + 1]
            let backtrack = first.rect.minY - second.rect.minY
            guard backtrack >= minimumBacktrack else { continue }

            let overlap = max(0, min(first.rect.maxX, second.rect.maxX) - max(first.rect.minX, second.rect.minX))
            let narrowerWidth = min(first.rect.width, second.rect.width)
            let overlapRatio = narrowerWidth > 0 ? overlap / narrowerWidth : 0
            let centersAreClose = abs(first.rect.midX - second.rect.midX) <= 0.20

            if overlapRatio >= 0.30 || centersAreClose {
                return true
            }
        }

        return false
    }

    /// Phase 2 and Phase 6 intentionally use different evidence. PDFKit line
    /// wrapping can make ordinary multi-column prose resemble a compact grid to
    /// the early detector/table classifier. When Phase 4 has reconstructed clear
    /// columns and the PDF content stream itself is serialized column-by-column,
    /// that is strong evidence for prose columns rather than a row-major table.
    private static func reconciledSpecialStructures(
        _ analysis: PdfSpecialStructureAnalysis,
        assessment: PdfLayoutComplexityAssessment,
        blocks: [PdfLayoutBlock],
        layout: PdfPageRegionLayout
    ) -> PdfSpecialStructureAnalysis {
        guard !analysis.tables.isEmpty else { return analysis }

        let detectorAlreadySaysColumns = assessment.complexity == .likelyMultiColumn
        let reconstructedColumnarProse = tableGridIsActuallyColumnarProse(
            analysis: analysis,
            blocks: blocks,
            layout: layout
        )
        guard detectorAlreadySaysColumns || reconstructedColumnarProse else {
            return analysis
        }

        let tableBlockIDs = analysis.tables.reduce(into: Set<Int>()) {
            $0.formUnion($1.blockIDs)
        }
        let assignments = analysis.assignments.map { assignment in
            guard assignment.role == .tableCell,
                  tableBlockIDs.contains(assignment.blockID) else {
                return assignment
            }
            return PdfLayoutRoleAssignment(
                blockID: assignment.blockID,
                role: .body,
                confidence: 0.72,
                signals: ["column reconstruction/source serialization outranks table-grid fallback"]
            )
        }

        return PdfSpecialStructureAnalysis(
            assignments: assignments,
            tables: [],
            readingOrderHints: analysis.readingOrderHints
        )
    }

    private static func tableGridIsActuallyColumnarProse(
        analysis: PdfSpecialStructureAnalysis,
        blocks: [PdfLayoutBlock],
        layout: PdfPageRegionLayout
    ) -> Bool {
        guard layout.primaryColumnCount >= 2,
              layout.primaryColumnCount <= 3,
              let region = layout.regions.first(where: { $0.kind == .columnar && $0.columns.count >= 2 }) else {
            return false
        }

        let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let tableIDs = analysis.tables.reduce(into: Set<Int>()) { $0.formUnion($1.blockIDs) }
        let orderedColumns = region.columns.sorted { lhs, rhs in
            if lhs.rect.minX != rhs.rect.minX { return lhs.rect.minX < rhs.rect.minX }
            return lhs.id < rhs.id
        }
        guard orderedColumns.allSatisfy({ $0.blockIDs.count >= 2 }) else { return false }

        let primaryIDs = Set(orderedColumns.flatMap(\.blockIDs))
        let covered = primaryIDs.intersection(tableIDs).count
        guard !primaryIDs.isEmpty,
              Double(covered) / Double(primaryIDs.count) >= 0.80 else {
            return false
        }

        let orderRanges: [(min: Int, max: Int)] = orderedColumns.compactMap { column in
            let orders = column.blockIDs.compactMap { blockByID[$0]?.sourceOrder }
            guard let minimum = orders.min(), let maximum = orders.max() else { return nil }
            return (minimum, maximum)
        }
        guard orderRanges.count == orderedColumns.count else { return false }

        let ascending = zip(orderRanges, orderRanges.dropFirst()).allSatisfy { lhs, rhs in
            lhs.max < rhs.min
        }
        let descending = zip(orderRanges, orderRanges.dropFirst()).allSatisfy { lhs, rhs in
            lhs.min > rhs.max
        }
        return ascending || descending
    }

    private static func materialize(
        blocks: [PdfLayoutBlock],
        orderedBlockIDs: [Int],
        analysis: PdfSpecialStructureAnalysis
    ) -> String {
        let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let rankedTables = analysis.tables
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.confidence != rhs.element.confidence {
                    return lhs.element.confidence > rhs.element.confidence
                }
                return lhs.offset < rhs.offset
            }

        var tableIndexByBlockID: [Int: Int] = [:]
        for pair in rankedTables {
            for blockID in pair.element.blockIDs where tableIndexByBlockID[blockID] == nil {
                tableIndexByBlockID[blockID] = pair.offset
            }
        }

        var emittedTables: Set<Int> = []
        var parts: [String] = []
        parts.reserveCapacity(orderedBlockIDs.count)

        for blockID in orderedBlockIDs {
            if let tableIndex = tableIndexByBlockID[blockID],
               analysis.tables.indices.contains(tableIndex) {
                if emittedTables.insert(tableIndex).inserted {
                    let tableText = analysis.tables[tableIndex].linearizedText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tableText.isEmpty {
                        parts.append(tableText)
                    }
                }
                continue
            }

            guard let block = blockByID[blockID] else { continue }
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(text)
            }
        }

        return parts.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func passesSanityChecks(
        output: String,
        fragments: [PdfLayoutFragment],
        blocks: [PdfLayoutBlock]
    ) -> Bool {
        let sourceMeaningful = fragments.contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if sourceMeaningful && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        guard uniqueIDs(blocks.map(\.id)) else { return false }

        let sourceInformation = informativeCharacterCount(
            fragments.map(\.text).joined(separator: "\n")
        )
        let outputInformation = informativeCharacterCount(output)
        if sourceInformation > 0 {
            let ratio = Double(outputInformation) / Double(sourceInformation)
            guard ratio >= minimumInformationRatio,
                  ratio <= maximumInformationRatio else {
                return false
            }
        }

        return true
    }

    private static func conservesFragments(
        _ source: [PdfLayoutFragment],
        in lines: [PdfLayoutLine]
    ) -> Bool {
        let sourceIDs = source.map(\.id)
        let reconstructedIDs = lines.flatMap { $0.fragments.map(\.id) }
        return sourceIDs.count == reconstructedIDs.count
            && Set(sourceIDs) == Set(reconstructedIDs)
    }

    private static func conservesFragments(
        _ source: [PdfLayoutFragment],
        in blocks: [PdfLayoutBlock]
    ) -> Bool {
        let sourceIDs = source.map(\.id)
        let reconstructedIDs = blocks.flatMap { block in
            block.lines.flatMap { $0.fragments.map(\.id) }
        }
        return sourceIDs.count == reconstructedIDs.count
            && Set(sourceIDs) == Set(reconstructedIDs)
    }

    private static func uniqueIDs(_ ids: [Int]) -> Bool {
        Set(ids).count == ids.count
    }

    private static func informativeCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                count += 1
            }
        }
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
