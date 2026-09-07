import Foundation

enum PdfReadingOrderResolver {
    static func resolve(
        blocks: [PdfLayoutBlock],
        layout: PdfPageRegionLayout,
        hints: PdfReadingOrderHints = PdfReadingOrderHints()
    ) -> PdfReadingOrderResult {
        let direction = hints.writingDirection ?? dominantWritingDirection(in: blocks)
        let validBlocks = blocks.filter(isValid)
        var blockByID: [Int: PdfLayoutBlock] = [:]
        blockByID.reserveCapacity(validBlocks.count)
        for block in validBlocks {
            if blockByID[block.id] != nil {
                return fallback(
                    blocks: validBlocks,
                    direction: direction,
                    geometryConflictCount: 0,
                    diagnostics: ["Duplicate block identifier \(block.id) makes graph construction ambiguous."]
                )
            }
            blockByID[block.id] = block
        }

        guard !validBlocks.isEmpty else {
            return PdfReadingOrderResult(
                orderedBlockIDs: [],
                confidence: 1,
                writingDirection: direction,
                removedEdges: [],
                geometryConflictCount: 0,
                usedFallback: false,
                diagnostics: []
            )
        }

        let allIDs = Set(blockByID.keys)
        let assignedIDs = Set(layout.regions.flatMap { region in
            region.primaryBlockIDs + region.sidebarBlockIDs + region.spanningBlockIDs
        }).intersection(allIDs)
        let missingIDs = allIDs.subtracting(assignedIDs)
        let conflicts = geometryConflictCount(blocks: validBlocks, layout: layout)

        if !missingIDs.isEmpty {
            return fallback(
                blocks: validBlocks,
                direction: direction,
                geometryConflictCount: conflicts,
                diagnostics: ["Region layout omitted block IDs: \(missingIDs.sorted())."]
            )
        }

        if conflicts > 0 && layout.regions.contains(where: { $0.kind == .irregular }) {
            return fallback(
                blocks: validBlocks,
                direction: direction,
                geometryConflictCount: conflicts,
                diagnostics: ["Irregular region contains strongly overlapping blocks; geometric fallback is safer."]
            )
        }

        var graphEdges: [PdfReadingOrderEdge] = []
        var regionSequences: [[Int]] = []
        var alreadySequenced: Set<Int> = []

        for region in layout.regions.sorted(by: stableRegionOrder) {
            let sequence = sequenceForRegion(
                region,
                blockByID: blockByID,
                direction: direction,
                sidebarPolicy: hints.sidebarPolicy,
                excluding: alreadySequenced,
                edges: &graphEdges
            )
            guard !sequence.isEmpty else { continue }
            regionSequences.append(sequence)
            alreadySequenced.formUnion(sequence)
        }

        let unsequenced = allIDs.subtracting(alreadySequenced)
        if !unsequenced.isEmpty {
            return fallback(
                blocks: validBlocks,
                direction: direction,
                geometryConflictCount: conflicts,
                diagnostics: ["Region sequencing could not place block IDs: \(unsequenced.sorted())."]
            )
        }

        for index in 0..<(max(0, regionSequences.count - 1)) {
            guard let from = regionSequences[index].last,
                  let to = regionSequences[index + 1].first else {
                continue
            }
            graphEdges.append(edge(
                from: from,
                to: to,
                confidence: 0.97,
                reason: .regionSequence
            ))
        }

        appendFootnoteEdges(
            footnoteIDs: hints.footnoteBlockIDs.intersection(allIDs),
            blockByID: blockByID,
            direction: direction,
            edges: &graphEdges
        )
        appendCaptionEdges(
            attachments: hints.captionAttachments,
            validIDs: allIDs,
            edges: &graphEdges
        )
        for hint in hints.additionalPrecedence where
            hint.fromBlockID != hint.toBlockID
                && allIDs.contains(hint.fromBlockID)
                && allIDs.contains(hint.toBlockID) {
            graphEdges.append(edge(
                from: hint.fromBlockID,
                to: hint.toBlockID,
                confidence: hint.confidence,
                reason: hint.reason
            ))
        }

        var activeEdges = deduplicatedEdges(graphEdges)
        var removedEdges: [PdfReadingOrderEdge] = []
        var diagnostics: [String] = []
        var resolved: [Int]? = nil

        while resolved == nil {
            let attempt = topologicalSort(
                nodeIDs: allIDs,
                edges: activeEdges,
                blockByID: blockByID,
                direction: direction
            )
            if let ordered = attempt.ordered {
                resolved = ordered
                break
            }

            let cycleEdges = activeEdges.filter {
                attempt.unresolved.contains($0.fromBlockID)
                    && attempt.unresolved.contains($0.toBlockID)
            }
            guard let weakest = cycleEdges.sorted(by: weakerEdgeFirst).first else {
                return fallback(
                    blocks: validBlocks,
                    direction: direction,
                    geometryConflictCount: conflicts,
                    diagnostics: diagnostics + ["Graph remained unresolved without a removable cycle edge."]
                )
            }

            if let removalIndex = activeEdges.firstIndex(of: weakest) {
                activeEdges.remove(at: removalIndex)
            }
            removedEdges.append(weakest)
            diagnostics.append(
                "Removed \(weakest.reason.rawValue) edge \(weakest.fromBlockID)→\(weakest.toBlockID) at confidence \(formatted(weakest.confidence)) to resolve a cycle."
            )

            if removedEdges.count > graphEdges.count {
                return fallback(
                    blocks: validBlocks,
                    direction: direction,
                    geometryConflictCount: conflicts,
                    diagnostics: diagnostics + ["Cycle resolution exceeded the graph edge count."]
                )
            }
        }

        guard let ordered = resolved,
              ordered.count == allIDs.count,
              Set(ordered) == allIDs else {
            return fallback(
                blocks: validBlocks,
                direction: direction,
                geometryConflictCount: conflicts,
                diagnostics: diagnostics + ["Resolved graph did not conserve every block exactly once."]
            )
        }

        let confidence = readingOrderConfidence(
            layout: layout,
            removedEdgeCount: removedEdges.count,
            unknownCount: hints.unknownBlockIDs.intersection(allIDs).count,
            geometryConflictCount: conflicts
        )
        return PdfReadingOrderResult(
            orderedBlockIDs: ordered,
            confidence: confidence,
            writingDirection: direction,
            removedEdges: removedEdges,
            geometryConflictCount: conflicts,
            usedFallback: false,
            diagnostics: diagnostics
        )
    }

    private struct SortAttempt {
        let ordered: [Int]?
        let unresolved: Set<Int>
    }

    private static func sequenceForRegion(
        _ region: PdfLayoutRegion,
        blockByID: [Int: PdfLayoutBlock],
        direction: PdfLayoutWritingDirection,
        sidebarPolicy: PdfSidebarReadingPolicy,
        excluding excluded: Set<Int>,
        edges: inout [PdfReadingOrderEdge]
    ) -> [Int] {
        let regionIDs = Set(
            region.primaryBlockIDs + region.sidebarBlockIDs + region.spanningBlockIDs
        ).subtracting(excluded)
        guard !regionIDs.isEmpty else { return [] }

        if sidebarPolicy == .geometric {
            let sequence = stableSorted(
                regionIDs.compactMap { blockByID[$0] },
                direction: direction
            ).map(\.id)
            appendChain(
                sequence,
                confidence: max(0.62, region.confidence * 0.90),
                reason: .sameColumn,
                edges: &edges
            )
            return sequence
        }

        var primarySequence: [Int] = []
        switch region.kind {
        case .columnar:
            let orderedColumns = region.columns.sorted {
                if direction == .rightToLeft {
                    return $0.rect.minX > $1.rect.minX
                }
                return $0.rect.minX < $1.rect.minX
            }
            let deferredTrailing = deferredTrailingPrimaryBlockIDs(
                region: region,
                columns: orderedColumns,
                blockByID: blockByID
            )
            var columnSequences: [[Int]] = []
            var columnAssigned: Set<Int> = []

            for column in orderedColumns {
                let columnIDs = Set(column.blockIDs)
                    .intersection(regionIDs)
                    .subtracting(columnAssigned)
                    .subtracting(deferredTrailing)
                let sequence = stableSorted(
                    columnIDs.compactMap { blockByID[$0] },
                    direction: direction
                ).map(\.id)
                guard !sequence.isEmpty else { continue }
                appendChain(
                    sequence,
                    confidence: min(region.confidence, column.confidence),
                    reason: .sameColumn,
                    edges: &edges
                )
                columnSequences.append(sequence)
                columnAssigned.formUnion(sequence)
            }

            for index in 0..<(max(0, columnSequences.count - 1)) {
                guard let from = columnSequences[index].last,
                      let to = columnSequences[index + 1].first else { continue }
                edges.append(edge(
                    from: from,
                    to: to,
                    confidence: max(0.70, region.confidence * 0.94),
                    reason: .columnSequence
                ))
            }
            primarySequence = columnSequences.flatMap { $0 }

            let leftoverPrimary = Set(region.primaryBlockIDs)
                .intersection(regionIDs)
                .subtracting(primarySequence)
                .subtracting(deferredTrailing)
            if !leftoverPrimary.isEmpty {
                let leftover = stableSorted(
                    leftoverPrimary.compactMap { blockByID[$0] },
                    direction: direction
                ).map(\.id)
                if let from = primarySequence.last, let to = leftover.first {
                    edges.append(edge(
                        from: from,
                        to: to,
                        confidence: 0.62,
                        reason: .sameColumn
                    ))
                }
                appendChain(leftover, confidence: 0.62, reason: .sameColumn, edges: &edges)
                primarySequence += leftover
            }

            if !deferredTrailing.isEmpty {
                let trailing = stableSorted(
                    deferredTrailing.compactMap { blockByID[$0] },
                    direction: direction
                ).map(\.id)
                if let from = primarySequence.last, let to = trailing.first {
                    edges.append(edge(
                        from: from,
                        to: to,
                        confidence: max(0.68, region.confidence * 0.88),
                        reason: .regionSequence
                    ))
                }
                appendChain(
                    trailing,
                    confidence: max(0.68, region.confidence * 0.88),
                    reason: .regionSequence,
                    edges: &edges
                )
                primarySequence += trailing
            }

        case .spanning:
            primarySequence = stableSorted(
                region.spanningBlockIDs
                    .filter { regionIDs.contains($0) }
                    .compactMap { blockByID[$0] },
                direction: direction
            ).map(\.id)
            appendChain(
                primarySequence,
                confidence: max(0.76, region.confidence),
                reason: .sameColumn,
                edges: &edges
            )

        case .singleColumn, .irregular:
            primarySequence = stableSorted(
                region.primaryBlockIDs
                    .filter { regionIDs.contains($0) }
                    .compactMap { blockByID[$0] },
                direction: direction
            ).map(\.id)
            appendChain(
                primarySequence,
                confidence: max(0.62, region.confidence * 0.94),
                reason: .sameColumn,
                edges: &edges
            )
        }

        let sidebarSequence = stableSorted(
            region.sidebarBlockIDs
                .filter { regionIDs.contains($0) }
                .compactMap { blockByID[$0] },
            direction: direction
        ).map(\.id)

        if let from = primarySequence.last, let to = sidebarSequence.first {
            edges.append(edge(
                from: from,
                to: to,
                confidence: 0.82,
                reason: .sidebarAttachment
            ))
        }
        appendChain(
            sidebarSequence,
            confidence: 0.78,
            reason: .sidebarAttachment,
            edges: &edges
        )

        let sequence = primarySequence + sidebarSequence
        if !sequence.isEmpty { return sequence }

        let fallbackSequence = stableSorted(
            regionIDs.compactMap { blockByID[$0] },
            direction: direction
        ).map(\.id)
        appendChain(
            fallbackSequence,
            confidence: 0.55,
            reason: .sameColumn,
            edges: &edges
        )
        return fallbackSequence
    }

    /// Phase 4 can conservatively keep a short, left-aligned summary/footer in
    /// the nearest primary lane because PDFKit exposes glyph bounds rather than
    /// the invisible full-width drawing box. When such a block is observably
    /// wider than its lane peers and starts clearly below every primary-column
    /// body block, treat it as a trailing cross-column continuation for spoken
    /// order. This does not depend on hidden drawing-box geometry.
    private static func deferredTrailingPrimaryBlockIDs(
        region: PdfLayoutRegion,
        columns: [PdfLayoutColumn],
        blockByID: [Int: PdfLayoutBlock]
    ) -> Set<Int> {
        guard columns.count >= 2 else { return [] }
        let regionPrimary = Set(region.primaryBlockIDs)
        var result: Set<Int> = []

        for column in columns {
            let members = column.blockIDs
                .filter { regionPrimary.contains($0) }
                .compactMap { blockByID[$0] }
            guard members.count >= 2 else { continue }

            for candidate in members {
                let ownPeers = members.filter { $0.id != candidate.id }
                guard !ownPeers.isEmpty else { continue }

                let otherColumnBlocks = columns
                    .filter { $0.id != column.id }
                    .flatMap { $0.blockIDs }
                    .filter { regionPrimary.contains($0) }
                    .compactMap { blockByID[$0] }
                guard !otherColumnBlocks.isEmpty else { continue }

                let allBodyPeers = ownPeers + otherColumnBlocks
                let bodyBottom = allBodyPeers.map(\.rect.maxY).max() ?? 0
                guard candidate.rect.minY >= bodyBottom + 0.035 else { continue }

                let ownMedianWidth = median(ownPeers.map { $0.rect.width })
                let pageBodyMedianWidth = median(allBodyPeers.map { $0.rect.width })
                let referenceWidth = max(0.000_001, min(ownMedianWidth, pageBodyMedianWidth))
                guard candidate.rect.width >= referenceWidth * 1.12 else { continue }

                // A trailing continuation should remain close to the horizontal
                // span occupied by primary text rather than being a remote note.
                let primaryRect = allBodyPeers.dropFirst().reduce(allBodyPeers.first?.rect ?? .zero) {
                    $0.union($1.rect)
                }
                let horizontallyCompatible = candidate.rect.midX >= primaryRect.minX - 0.06
                    && candidate.rect.midX <= primaryRect.maxX + 0.06
                guard horizontallyCompatible else { continue }

                result.insert(candidate.id)
            }
        }

        return result
    }

    private static func appendFootnoteEdges(
        footnoteIDs: Set<Int>,
        blockByID: [Int: PdfLayoutBlock],
        direction: PdfLayoutWritingDirection,
        edges: inout [PdfReadingOrderEdge]
    ) {
        guard !footnoteIDs.isEmpty else { return }
        let footnotes = stableSorted(
            footnoteIDs.compactMap { blockByID[$0] },
            direction: direction
        ).map(\.id)
        let bodyIDs = Set(blockByID.keys).subtracting(footnoteIDs)

        if let firstFootnote = footnotes.first {
            for bodyID in bodyIDs.sorted() {
                edges.append(edge(
                    from: bodyID,
                    to: firstFootnote,
                    confidence: 0.94,
                    reason: .footnotePlacement
                ))
            }
        }
        appendChain(
            footnotes,
            confidence: 0.94,
            reason: .footnotePlacement,
            edges: &edges
        )
    }

    private static func appendCaptionEdges(
        attachments: [PdfReadingOrderAttachment],
        validIDs: Set<Int>,
        edges: inout [PdfReadingOrderEdge]
    ) {
        for attachment in attachments where
            attachment.blockID != attachment.anchorBlockID
                && validIDs.contains(attachment.blockID)
                && validIDs.contains(attachment.anchorBlockID) {
            edges.append(edge(
                from: attachment.anchorBlockID,
                to: attachment.blockID,
                confidence: attachment.confidence,
                reason: .captionAttachment
            ))
        }
    }

    private static func appendChain(
        _ ids: [Int],
        confidence: Double,
        reason: PdfReadingOrderEdgeReason,
        edges: inout [PdfReadingOrderEdge]
    ) {
        guard ids.count >= 2 else { return }
        for index in 0..<(ids.count - 1) {
            edges.append(edge(
                from: ids[index],
                to: ids[index + 1],
                confidence: confidence,
                reason: reason
            ))
        }
    }

    private static func topologicalSort(
        nodeIDs: Set<Int>,
        edges: [PdfReadingOrderEdge],
        blockByID: [Int: PdfLayoutBlock],
        direction: PdfLayoutWritingDirection
    ) -> SortAttempt {
        var indegree = Dictionary(uniqueKeysWithValues: nodeIDs.map { ($0, 0) })
        var outgoing: [Int: [PdfReadingOrderEdge]] = [:]

        for edge in edges where
            nodeIDs.contains(edge.fromBlockID)
                && nodeIDs.contains(edge.toBlockID)
                && edge.fromBlockID != edge.toBlockID {
            indegree[edge.toBlockID, default: 0] += 1
            outgoing[edge.fromBlockID, default: []].append(edge)
        }

        var ready = nodeIDs.filter { indegree[$0, default: 0] == 0 }
        var ordered: [Int] = []
        ordered.reserveCapacity(nodeIDs.count)

        while !ready.isEmpty {
            let next = ready.sorted {
                guard let lhs = blockByID[$0], let rhs = blockByID[$1] else { return $0 < $1 }
                return stableBlockOrder(lhs, rhs, direction: direction)
            }.first!
            ready.remove(next)
            ordered.append(next)

            let nextEdges = (outgoing[next] ?? []).sorted {
                if $0.toBlockID != $1.toBlockID { return $0.toBlockID < $1.toBlockID }
                return $0.reason.rawValue < $1.reason.rawValue
            }
            for edge in nextEdges {
                indegree[edge.toBlockID, default: 0] -= 1
                if indegree[edge.toBlockID] == 0 {
                    ready.insert(edge.toBlockID)
                }
            }
        }

        if ordered.count == nodeIDs.count {
            return SortAttempt(ordered: ordered, unresolved: [])
        }
        return SortAttempt(
            ordered: nil,
            unresolved: nodeIDs.subtracting(ordered)
        )
    }

    private static func deduplicatedEdges(_ edges: [PdfReadingOrderEdge]) -> [PdfReadingOrderEdge] {
        var bestByPair: [String: PdfReadingOrderEdge] = [:]
        for candidate in edges where candidate.fromBlockID != candidate.toBlockID {
            let key = "\(candidate.fromBlockID)>\(candidate.toBlockID)"
            if let existing = bestByPair[key] {
                if candidate.confidence > existing.confidence
                    || (candidate.confidence == existing.confidence
                        && candidate.reason.rawValue < existing.reason.rawValue) {
                    bestByPair[key] = candidate
                }
            } else {
                bestByPair[key] = candidate
            }
        }
        return bestByPair.values.sorted(by: stableEdgeOrder)
    }

    private static func weakerEdgeFirst(_ lhs: PdfReadingOrderEdge, _ rhs: PdfReadingOrderEdge) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
        if lhs.reason.rawValue != rhs.reason.rawValue { return lhs.reason.rawValue < rhs.reason.rawValue }
        if lhs.fromBlockID != rhs.fromBlockID { return lhs.fromBlockID < rhs.fromBlockID }
        return lhs.toBlockID < rhs.toBlockID
    }

    private static func stableEdgeOrder(_ lhs: PdfReadingOrderEdge, _ rhs: PdfReadingOrderEdge) -> Bool {
        if lhs.fromBlockID != rhs.fromBlockID { return lhs.fromBlockID < rhs.fromBlockID }
        if lhs.toBlockID != rhs.toBlockID { return lhs.toBlockID < rhs.toBlockID }
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        return lhs.reason.rawValue < rhs.reason.rawValue
    }

    private static func stableRegionOrder(_ lhs: PdfLayoutRegion, _ rhs: PdfLayoutRegion) -> Bool {
        if abs(lhs.rect.minY - rhs.rect.minY) > 0.000_001 {
            return lhs.rect.minY < rhs.rect.minY
        }
        return lhs.id < rhs.id
    }

    private static func stableSorted(
        _ blocks: [PdfLayoutBlock],
        direction: PdfLayoutWritingDirection
    ) -> [PdfLayoutBlock] {
        blocks.sorted { stableBlockOrder($0, $1, direction: direction) }
    }

    private static func stableBlockOrder(
        _ lhs: PdfLayoutBlock,
        _ rhs: PdfLayoutBlock,
        direction: PdfLayoutWritingDirection
    ) -> Bool {
        let rowTolerance = max(0.012, min(lhs.rect.height, rhs.rect.height) * 0.50)
        if abs(lhs.rect.minY - rhs.rect.minY) > rowTolerance {
            return lhs.rect.minY < rhs.rect.minY
        }
        if abs(lhs.rect.minX - rhs.rect.minX) > 0.000_001 {
            if direction == .rightToLeft {
                return lhs.rect.minX > rhs.rect.minX
            }
            return lhs.rect.minX < rhs.rect.minX
        }
        if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
        return lhs.id < rhs.id
    }

    private static func dominantWritingDirection(in blocks: [PdfLayoutBlock]) -> PdfLayoutWritingDirection {
        var ltr = 0
        var rtl = 0
        for line in blocks.flatMap(\.lines) {
            if line.writingDirection == .rightToLeft {
                rtl += 1
            } else {
                ltr += 1
            }
        }
        return rtl > ltr ? .rightToLeft : .leftToRight
    }

    private static func readingOrderConfidence(
        layout: PdfPageRegionLayout,
        removedEdgeCount: Int,
        unknownCount: Int,
        geometryConflictCount: Int
    ) -> Double {
        let regionConfidences = layout.regions.map(\.confidence)
        let regionBase = regionConfidences.isEmpty
            ? 0.78
            : regionConfidences.reduce(0, +) / Double(regionConfidences.count)
        let columnConfidences = layout.regions.flatMap { $0.columns.map(\.confidence) }
        let columnBase = columnConfidences.isEmpty
            ? regionBase
            : columnConfidences.reduce(0, +) / Double(columnConfidences.count)
        var confidence = regionBase * 0.65 + columnBase * 0.35
        confidence -= min(0.36, Double(removedEdgeCount) * 0.12)
        confidence -= min(0.20, Double(unknownCount) * 0.04)
        confidence -= min(0.30, Double(geometryConflictCount) * 0.10)
        return min(1, max(0, confidence))
    }

    private static func geometryConflictCount(
        blocks: [PdfLayoutBlock],
        layout: PdfPageRegionLayout
    ) -> Int {
        guard blocks.count >= 2 else { return 0 }
        let blockRegion = regionIndexByBlockID(layout)
        var count = 0
        for left in 0..<(blocks.count - 1) {
            for right in (left + 1)..<blocks.count {
                let lhs = blocks[left]
                let rhs = blocks[right]
                guard blockRegion[lhs.id] == blockRegion[rhs.id] else { continue }
                if overlapOverSmaller(lhs.rect, rhs.rect) >= 0.65 {
                    count += 1
                }
            }
        }
        return count
    }

    private static func regionIndexByBlockID(_ layout: PdfPageRegionLayout) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (index, region) in layout.regions.enumerated() {
            for id in region.primaryBlockIDs + region.sidebarBlockIDs + region.spanningBlockIDs {
                if result[id] == nil { result[id] = index }
            }
        }
        return result
    }

    private static func overlapOverSmaller(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let a = lhs.standardized
        let b = rhs.standardized
        let aArea = a.width * a.height
        let bArea = b.width * b.height
        guard aArea > 0, bArea > 0 else { return 0 }
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return (intersection.width * intersection.height) / min(aArea, bArea)
    }

    private static func fallback(
        blocks: [PdfLayoutBlock],
        direction: PdfLayoutWritingDirection,
        geometryConflictCount: Int,
        diagnostics: [String]
    ) -> PdfReadingOrderResult {
        PdfReadingOrderResult(
            orderedBlockIDs: stableSorted(blocks, direction: direction).map(\.id),
            confidence: min(0.45, max(0.20, 0.45 - Double(geometryConflictCount) * 0.05)),
            writingDirection: direction,
            removedEdges: [],
            geometryConflictCount: geometryConflictCount,
            usedFallback: true,
            diagnostics: diagnostics
        )
    }

    private static func edge(
        from: Int,
        to: Int,
        confidence: Double,
        reason: PdfReadingOrderEdgeReason
    ) -> PdfReadingOrderEdge {
        PdfReadingOrderEdge(
            fromBlockID: from,
            toBlockID: to,
            confidence: min(1, max(0, confidence)),
            reason: reason
        )
    }

    private static func isValid(_ block: PdfLayoutBlock) -> Bool {
        !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && block.rect.minX.isFinite
            && block.rect.minY.isFinite
            && block.rect.width.isFinite
            && block.rect.height.isFinite
            && block.rect.width > 0
            && block.rect.height > 0
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

    private static func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
