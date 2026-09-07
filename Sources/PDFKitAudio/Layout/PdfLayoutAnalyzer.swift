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

    static func analyze(
        fragments: [PdfLayoutFragment],
        nativeText: String,
        nativeTextThreshold: Int,
        pageIndex: Int,
        mode: PdfLayoutMode,
        checkpoint: () throws -> Void = {}
    ) throws -> Result? {
        guard mode != .never else { return nil }

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
        guard !positioned.isEmpty else { return nil }
        guard uniqueIDs(positioned.map(\.id)) else { return nil }

        let assessment = PdfLayoutComplexityDetector.assess(
            fragments: positioned,
            nativeText: nativeText,
            nativeTextThreshold: nativeTextThreshold
        )
        switch mode {
        case .never:
            return nil
        case .auto:
            guard assessment.shouldAnalyze else { return nil }
        case .always:
            break
        }

        try checkpoint()
        let lines = PdfLayoutLineBuilder.build(fragments: positioned)
        guard conservesFragments(positioned, in: lines) else { return nil }

        let blocks = PdfLayoutBlockBuilder.build(lines: lines)
        guard !blocks.isEmpty,
              uniqueIDs(blocks.map(\.id)),
              conservesFragments(positioned, in: blocks) else {
            return nil
        }

        try checkpoint()
        let layout = PdfLayoutRegionDetector.segment(blocks: blocks)
        let special = PdfLayoutRoleClassifier.analyze(blocks: blocks, layout: layout)
        guard Set(special.assignments.map(\.blockID)) == Set(blocks.map(\.id)),
              special.assignments.count == blocks.count else {
            return nil
        }

        let readingOrder = PdfReadingOrderResolver.resolve(
            blocks: blocks,
            layout: layout,
            hints: special.readingOrderHints
        )
        try checkpoint()

        let blockIDs = Set(blocks.map(\.id))
        guard !readingOrder.usedFallback,
              readingOrder.confidence >= minimumReadingOrderConfidence,
              readingOrder.orderedBlockIDs.count == blocks.count,
              Set(readingOrder.orderedBlockIDs) == blockIDs else {
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
            return nil
        }

        let fingerprints = PdfDocumentLayoutFingerprintBuilder.make(
            pageIndex: pageIndex,
            blocks: blocks,
            analysis: special
        )
        return Result(
            text: analyzedText,
            fingerprints: fingerprints,
            assessment: assessment,
            readingOrder: readingOrder
        )
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
}
