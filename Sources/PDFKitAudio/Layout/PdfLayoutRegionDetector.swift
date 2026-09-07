import Foundation

enum PdfLayoutRegionDetector {
    static func segment(blocks: [PdfLayoutBlock]) -> PdfPageRegionLayout {
        let valid = blocks.filter(isValid).sorted(by: stableBlockOrder)
        guard !valid.isEmpty else {
            return PdfPageRegionLayout(
                regions: [],
                primaryColumnCount: 0,
                sidebarBlockIDs: [],
                spanningBlockIDs: []
            )
        }

        let sidebarIDs = detectSidebarBlockIDs(in: valid)
        let nonSidebar = valid.filter { !sidebarIDs.contains($0.id) }
        let globalColumns = detectPrimaryColumns(in: nonSidebar).columns
        let spanningIDs = detectSpanningBlockIDs(
            in: nonSidebar,
            primaryColumns: globalColumns
        )

        let regions = buildRegions(
            blocks: valid,
            sidebarIDs: sidebarIDs,
            spanningIDs: spanningIDs
        )
        let maximumColumns = regions.map { $0.columns.count }.max() ?? 0

        return PdfPageRegionLayout(
            regions: regions,
            primaryColumnCount: maximumColumns,
            sidebarBlockIDs: sidebarIDs.sorted(),
            spanningBlockIDs: spanningIDs.sorted()
        )
    }

    private struct ColumnDetection {
        let columns: [PdfLayoutColumn]
        let kind: PdfLayoutRegionKind
        let confidence: Double
    }

    private struct LaneCluster {
        var blocks: [PdfLayoutBlock]
        var centerX: CGFloat

        var rect: CGRect {
            unionRect(blocks.map(\.rect))
        }

        var medianWidth: CGFloat {
            PdfLayoutRegionDetector.median(blocks.map { $0.rect.width })
        }

        mutating func append(_ block: PdfLayoutBlock) {
            let count = CGFloat(blocks.count)
            centerX = ((centerX * count) + block.rect.minX) / (count + 1)
            blocks.append(block)
        }
    }

    private static func buildRegions(
        blocks: [PdfLayoutBlock],
        sidebarIDs: Set<Int>,
        spanningIDs: Set<Int>
    ) -> [PdfLayoutRegion] {
        let spanning = blocks
            .filter { spanningIDs.contains($0.id) }
            .sorted(by: stableBlockOrder)

        guard !spanning.isEmpty else {
            return regionForBand(
                id: 0,
                blocks: blocks,
                sidebarIDs: sidebarIDs,
                verticalRange: 0...1
            ).map { [$0] } ?? []
        }

        var regions: [PdfLayoutRegion] = []
        var cursor: CGFloat = 0

        for span in spanning {
            let bandEnd = max(cursor, min(1, span.rect.minY))
            if bandEnd - cursor > 0.000_5,
               let region = regionForBand(
                    id: regions.count,
                    blocks: blocks.filter { !spanningIDs.contains($0.id) },
                    sidebarIDs: sidebarIDs,
                    verticalRange: cursor...bandEnd
               ) {
                regions.append(region)
            }

            let sidebars = blocks
                .filter { sidebarIDs.contains($0.id) && verticalOverlap($0.rect, span.rect) > 0 }
                .map(\.id)
                .sorted()
            regions.append(PdfLayoutRegion(
                id: regions.count,
                rect: span.rect,
                kind: .spanning,
                columns: [],
                primaryBlockIDs: [],
                sidebarBlockIDs: sidebars,
                spanningBlockIDs: [span.id],
                confidence: 0.92
            ))
            cursor = max(cursor, min(1, span.rect.maxY))
        }

        if cursor < 1,
           let region = regionForBand(
                id: regions.count,
                blocks: blocks.filter { !spanningIDs.contains($0.id) },
                sidebarIDs: sidebarIDs,
                verticalRange: cursor...1
           ) {
            regions.append(region)
        }

        return regions.enumerated().map { index, region in
            PdfLayoutRegion(
                id: index,
                rect: region.rect,
                kind: region.kind,
                columns: region.columns,
                primaryBlockIDs: region.primaryBlockIDs,
                sidebarBlockIDs: region.sidebarBlockIDs,
                spanningBlockIDs: region.spanningBlockIDs,
                confidence: region.confidence
            )
        }
    }

    private static func regionForBand(
        id: Int,
        blocks: [PdfLayoutBlock],
        sidebarIDs: Set<Int>,
        verticalRange: ClosedRange<CGFloat>
    ) -> PdfLayoutRegion? {
        let epsilon: CGFloat = 0.002
        let members = blocks.filter { block in
            block.rect.midY >= verticalRange.lowerBound - epsilon
                && block.rect.midY <= verticalRange.upperBound + epsilon
        }
        guard !members.isEmpty else { return nil }

        let sidebarBlocks = members.filter { sidebarIDs.contains($0.id) }
        let primaryBlocks = members.filter { !sidebarIDs.contains($0.id) }
        let detection = detectPrimaryColumns(in: primaryBlocks)
        let rect = unionRect(members.map(\.rect))

        return PdfLayoutRegion(
            id: id,
            rect: rect,
            kind: detection.kind,
            columns: detection.columns,
            primaryBlockIDs: primaryBlocks.map(\.id).sorted(),
            sidebarBlockIDs: sidebarBlocks.map(\.id).sorted(),
            spanningBlockIDs: [],
            confidence: detection.confidence
        )
    }

    private static func detectPrimaryColumns(
        in blocks: [PdfLayoutBlock]
    ) -> ColumnDetection {
        guard !blocks.isEmpty else {
            return ColumnDetection(columns: [], kind: .singleColumn, confidence: 1)
        }

        let ordered = blocks.sorted(by: stableBlockOrder)
        let laneEligible = ordered.filter { $0.rect.width <= 0.55 }
        let clusters = clusterLanes(laneEligible)
        let candidateSets = sideBySideCandidateSets(clusters)

        if let best = candidateSets.max(by: { candidateScore($0) < candidateScore($1) }) {
            let sorted = best.sorted { $0.rect.minX < $1.rect.minX }
            let columns = sorted.enumerated().map { index, cluster in
                PdfLayoutColumn(
                    id: index,
                    rect: cluster.rect,
                    blockIDs: cluster.blocks.map(\.id).sorted(),
                    confidence: columnConfidence(cluster, peers: sorted)
                )
            }
            return ColumnDetection(
                columns: columns,
                kind: .columnar,
                confidence: min(0.98, max(0.72, candidateScore(sorted)))
            )
        }

        let allRect = unionRect(ordered.map(\.rect))
        let singleColumn = PdfLayoutColumn(
            id: 0,
            rect: allRect,
            blockIDs: ordered.map(\.id).sorted(),
            confidence: 0.88
        )
        return ColumnDetection(
            columns: [singleColumn],
            kind: .singleColumn,
            confidence: 0.88
        )
    }

    private static func clusterLanes(_ blocks: [PdfLayoutBlock]) -> [LaneCluster] {
        guard !blocks.isEmpty else { return [] }
        let ordered = blocks.sorted {
            if abs($0.rect.minX - $1.rect.minX) > 0.000_001 {
                return $0.rect.minX < $1.rect.minX
            }
            return stableBlockOrder($0, $1)
        }
        let medianWidth = median(ordered.map { $0.rect.width })
        let tolerance = max(0.040, min(0.070, medianWidth * 0.18))
        var clusters: [LaneCluster] = []

        for block in ordered {
            if let index = clusters.indices.min(by: {
                abs(clusters[$0].centerX - block.rect.minX)
                    < abs(clusters[$1].centerX - block.rect.minX)
            }), abs(clusters[index].centerX - block.rect.minX) <= tolerance {
                clusters[index].append(block)
            } else {
                clusters.append(LaneCluster(blocks: [block], centerX: block.rect.minX))
            }
        }

        return clusters.sorted { $0.rect.minX < $1.rect.minX }
    }

    private static func sideBySideCandidateSets(
        _ clusters: [LaneCluster]
    ) -> [[LaneCluster]] {
        guard clusters.count >= 2 else { return [] }
        var candidates: [[LaneCluster]] = []

        for left in 0..<(clusters.count - 1) {
            for right in (left + 1)..<clusters.count {
                let pair = [clusters[left], clusters[right]]
                if validPrimaryLaneSet(pair) {
                    candidates.append(pair)
                }
            }
        }

        if clusters.count >= 3 {
            for first in 0..<(clusters.count - 2) {
                for second in (first + 1)..<(clusters.count - 1) {
                    for third in (second + 1)..<clusters.count {
                        let triple = [clusters[first], clusters[second], clusters[third]]
                        if validPrimaryLaneSet(triple) {
                            candidates.append(triple)
                        }
                    }
                }
            }
        }

        return candidates
    }

    private static func validPrimaryLaneSet(_ lanes: [LaneCluster]) -> Bool {
        guard lanes.count >= 2 && lanes.count <= 3 else { return false }
        let ordered = lanes.sorted { $0.rect.minX < $1.rect.minX }

        for index in 0..<(ordered.count - 1) {
            let lhs = ordered[index]
            let rhs = ordered[index + 1]
            let gap = rhs.rect.minX - lhs.rect.maxX
            guard gap >= 0.012 else { return false }

            let overlap = verticalOverlap(lhs.rect, rhs.rect)
            let denominator = max(0.000_001, min(lhs.rect.height, rhs.rect.height))
            let overlapRatio = overlap / denominator
            let bothSubstantial = lhs.rect.height >= 0.09 && rhs.rect.height >= 0.09
            guard overlapRatio >= 0.18 || bothSubstantial else { return false }

            let widthRatio = min(lhs.medianWidth, rhs.medianWidth)
                / max(0.000_001, max(lhs.medianWidth, rhs.medianWidth))
            let heightRatio = min(lhs.rect.height, rhs.rect.height)
                / max(0.000_001, max(lhs.rect.height, rhs.rect.height))
            guard widthRatio >= 0.42 || heightRatio >= 0.72 else { return false }
        }

        return true
    }

    private static func candidateScore(_ lanes: [LaneCluster]) -> Double {
        guard lanes.count >= 2 else { return 0 }
        let ordered = lanes.sorted { $0.rect.minX < $1.rect.minX }
        var gutterScore: CGFloat = 0
        var overlapScore: CGFloat = 0

        for index in 0..<(ordered.count - 1) {
            let lhs = ordered[index].rect
            let rhs = ordered[index + 1].rect
            gutterScore += min(0.20, max(0, rhs.minX - lhs.maxX))
            let denominator = max(0.000_001, min(lhs.height, rhs.height))
            overlapScore += min(1, verticalOverlap(lhs, rhs) / denominator)
        }

        let pairCount = CGFloat(ordered.count - 1)
        let normalizedGutter = min(1, (gutterScore / pairCount) / 0.08)
        let normalizedOverlap = overlapScore / pairCount
        let countBonus: Double = ordered.count == 3 ? 0.05 : 0
        return min(
            0.98,
            0.62
                + Double(normalizedGutter) * 0.16
                + Double(normalizedOverlap) * 0.15
                + countBonus
        )
    }

    private static func columnConfidence(
        _ lane: LaneCluster,
        peers: [LaneCluster]
    ) -> Double {
        let verticalContinuity = min(1, max(0, lane.rect.height / 0.35))
        let width = lane.medianWidth
        let peerMedianWidth = median(peers.map { $0.medianWidth })
        let widthSimilarity = peerMedianWidth > 0
            ? min(1, min(width, peerMedianWidth) / max(width, peerMedianWidth))
            : 1
        return min(0.99, 0.70 + Double(verticalContinuity) * 0.17 + Double(widthSimilarity) * 0.10)
    }

    private static func detectSpanningBlockIDs(
        in blocks: [PdfLayoutBlock],
        primaryColumns: [PdfLayoutColumn]
    ) -> Set<Int> {
        guard primaryColumns.count >= 2 else { return [] }
        let orderedColumns = primaryColumns.sorted { $0.rect.minX < $1.rect.minX }
        let columnIDs = Set(primaryColumns.flatMap(\.blockIDs))
        let medianColumnWidth = median(primaryColumns.map { $0.rect.width })
        var gutterCenters: [CGFloat] = []

        for index in 0..<(orderedColumns.count - 1) {
            let lhs = orderedColumns[index].rect
            let rhs = orderedColumns[index + 1].rect
            if rhs.minX > lhs.maxX {
                gutterCenters.append((lhs.maxX + rhs.minX) / 2)
            }
        }

        guard !gutterCenters.isEmpty else { return [] }
        var result: Set<Int> = []

        for block in blocks where !columnIDs.contains(block.id) {
            let crossesGutter = gutterCenters.contains { center in
                block.rect.minX <= center - 0.006 && block.rect.maxX >= center + 0.006
            }
            let wideEnough = block.rect.width >= max(0.56, medianColumnWidth * 1.30)
            if crossesGutter && wideEnough {
                result.insert(block.id)
            }
        }

        // A global lane seed may accidentally include a later/earlier wide block
        // only when its left edge resembles one column. Recheck every block so
        // spanning content is not hidden merely by seed membership.
        for block in blocks where !result.contains(block.id) {
            let crossesGutter = gutterCenters.contains { center in
                block.rect.minX <= center - 0.006 && block.rect.maxX >= center + 0.006
            }
            let wideEnough = block.rect.width >= max(0.62, medianColumnWidth * 1.45)
            if crossesGutter && wideEnough {
                result.insert(block.id)
            }
        }

        return result
    }

    private static func detectSidebarBlockIDs(
        in blocks: [PdfLayoutBlock]
    ) -> Set<Int> {
        guard blocks.count >= 2 else { return [] }
        var result: Set<Int> = []

        for candidate in blocks {
            for body in blocks where body.id != candidate.id {
                guard candidate.rect.width <= body.rect.width * 0.62,
                      candidate.rect.height <= body.rect.height * 0.72 else {
                    continue
                }

                let overlap = verticalOverlap(candidate.rect, body.rect)
                let verticalContainment = overlap / max(0.000_001, candidate.rect.height)
                guard verticalContainment >= 0.48 else { continue }

                let horizontalOverlap = horizontalOverlapRatio(candidate.rect, body.rect)
                let outsideBodyLane = candidate.rect.midX < body.rect.minX
                    || candidate.rect.midX > body.rect.maxX
                if horizontalOverlap <= 0.28 || outsideBodyLane {
                    result.insert(candidate.id)
                    break
                }
            }
        }

        return result
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

    private static func stableBlockOrder(_ lhs: PdfLayoutBlock, _ rhs: PdfLayoutBlock) -> Bool {
        if abs(lhs.rect.minY - rhs.rect.minY) > 0.000_001 {
            return lhs.rect.minY < rhs.rect.minY
        }
        if abs(lhs.rect.minX - rhs.rect.minX) > 0.000_001 {
            return lhs.rect.minX < rhs.rect.minX
        }
        return lhs.sourceOrder < rhs.sourceOrder
    }

    private static func verticalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }

    private static func horizontalOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        return overlap / max(0.000_001, min(lhs.width, rhs.width))
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
