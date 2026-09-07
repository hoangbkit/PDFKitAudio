import Foundation

/// Conservative page-level classification used to decide whether later layout
/// reconstruction is worth attempting. Phase 2 intentionally does not change
/// parser-selected text.
enum PdfLayoutComplexity: String, Equatable {
    case simpleSingleColumn
    case likelyMultiColumn
    case mixedRegions
    case likelyTableHeavy
    case irregularPositioned
    case unknown
}

struct PdfLayoutComplexityFeatures: Equatable {
    let fragmentCount: Int
    let leftEdgeClusterCount: Int
    let dominantLaneCount: Int
    let sideBySideRowCount: Int
    let alignedMultiItemRowCount: Int
    let maximumItemsPerRow: Int
    let singleItemRowCount: Int
    let longestInteriorGutter: CGFloat
    let dominantLaneSeparation: CGFloat
    let medianFragmentWidth: CGFloat
    let medianFragmentHeight: CGFloat
    let shortTextRatio: Double
    let narrowSideLaneDetected: Bool
    let mixedVerticalRegionsDetected: Bool
}

struct PdfLayoutComplexityAssessment: Equatable {
    let complexity: PdfLayoutComplexity
    let confidence: Double
    let shouldAnalyze: Bool
    let nativeTextQuality: PdfNativeTextQuality?
    let features: PdfLayoutComplexityFeatures
    let reasons: [String]
}

/// Transparent geometry-first classifier. It intentionally prefers false
/// negatives over false positives so already-good single-column books remain on
/// the existing fast path.
enum PdfLayoutComplexityDetector {
    static func assess(
        fragments: [PdfLayoutFragment],
        nativeText: String? = nil,
        nativeTextThreshold: Int = 20
    ) -> PdfLayoutComplexityAssessment {
        let valid = fragments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.rect.width > 0
                && $0.rect.height > 0
                && $0.rect.minX.isFinite
                && $0.rect.minY.isFinite
                && $0.rect.width.isFinite
                && $0.rect.height.isFinite
        }

        let quality = nativeText.map {
            PdfOCRPolicy.quality(of: $0, threshold: nativeTextThreshold)
        }

        guard !valid.isEmpty else {
            let features = PdfLayoutComplexityFeatures(
                fragmentCount: 0,
                leftEdgeClusterCount: 0,
                dominantLaneCount: 0,
                sideBySideRowCount: 0,
                alignedMultiItemRowCount: 0,
                maximumItemsPerRow: 0,
                singleItemRowCount: 0,
                longestInteriorGutter: 0,
                dominantLaneSeparation: 0,
                medianFragmentWidth: 0,
                medianFragmentHeight: 0,
                shortTextRatio: 0,
                narrowSideLaneDetected: false,
                mixedVerticalRegionsDetected: false
            )
            return PdfLayoutComplexityAssessment(
                complexity: .simpleSingleColumn,
                confidence: 1,
                shouldAnalyze: false,
                nativeTextQuality: quality,
                features: features,
                reasons: ["No positioned text requires layout reconstruction."]
            )
        }

        let medianHeight = median(valid.map { $0.rect.height })
        let medianWidth = median(valid.map { $0.rect.width })
        let edgeTolerance = max(0.014, min(0.035, medianHeight * 0.85))
        let rowTolerance = max(0.014, min(0.035, medianHeight * 0.80))

        let leftClusters = clusterLeftEdges(valid, tolerance: edgeTolerance)
        let rows = clusterRows(valid, tolerance: rowTolerance)
        let dominantThreshold = max(2, Int(ceil(Double(valid.count) * 0.18)))
        let dominantClusters = leftClusters.filter { $0.indices.count >= dominantThreshold }
        let rowStats = rowStatistics(rows: rows, fragments: valid)
        let pageWideGutter = longestInteriorGutter(fragments: valid)
        let laneSeparation = dominantLaneSeparation(
            fragments: valid,
            clusters: dominantClusters
        )
        let shortTextRatio = ratio(valid) { fragment in
            semanticCharacterCount(fragment.text) <= 22
        }
        let sideLane = detectsNarrowSideLane(
            fragments: valid,
            clusters: leftClusters,
            dominantClusters: dominantClusters
        )
        let mixedRegions = detectsMixedVerticalRegions(
            fragments: valid,
            rows: rows,
            rowStats: rowStats,
            dominantClusters: dominantClusters,
            medianFragmentWidth: medianWidth
        )

        let features = PdfLayoutComplexityFeatures(
            fragmentCount: valid.count,
            leftEdgeClusterCount: leftClusters.count,
            dominantLaneCount: dominantClusters.count,
            sideBySideRowCount: rowStats.sideBySideRowCount,
            alignedMultiItemRowCount: rowStats.alignedMultiItemRowCount,
            maximumItemsPerRow: rowStats.maximumItemsPerRow,
            singleItemRowCount: rowStats.singleItemRowCount,
            longestInteriorGutter: pageWideGutter,
            dominantLaneSeparation: laneSeparation,
            medianFragmentWidth: medianWidth,
            medianFragmentHeight: medianHeight,
            shortTextRatio: shortTextRatio,
            narrowSideLaneDetected: sideLane,
            mixedVerticalRegionsDetected: mixedRegions
        )

        // Table evidence is intentionally stronger than generic multi-lane
        // evidence. Two-column prose may align by row, so a 2-lane page needs
        // short/compact cell-like content. Three-or-more lanes can also qualify
        // when repeated rows are tightly packed, which catches multi-line cells
        // whose text boxes consume most of their column width.
        let compactCellRows = rowStats.alignedMultiItemRowCount >= 2
            && dominantClusters.count >= 2
            && shortTextRatio >= 0.72
            && medianWidth <= 0.22
        let denseGridRows = rowStats.tightAlignedRowCount >= 2
            && rowStats.maximumItemsPerRow >= 3
            && dominantClusters.count >= 3
        let explicitMultilineCells = rowStats.alignedMultiItemRowCount >= 2
            && rowStats.maximumItemsPerRow >= 3
            && ratio(valid) { $0.text.contains("\n") } >= 0.50
        let tableEvidence = compactCellRows || denseGridRows || explicitMultilineCells

        if tableEvidence {
            let confidence = clampedConfidence(
                0.74
                    + min(0.10, Double(rowStats.alignedMultiItemRowCount) * 0.02)
                    + (rowStats.maximumItemsPerRow >= 3 ? 0.08 : 0)
                    + (shortTextRatio >= 0.90 ? 0.04 : 0)
            )
            return assessment(
                .likelyTableHeavy,
                confidence: confidence,
                quality: quality,
                features: features,
                reasons: [
                    "Repeated aligned cell-like rows were detected.",
                    "Row density/compactness is stronger than ordinary column evidence."
                ]
            )
        }

        // Mixed-region detection deliberately does not use the page-wide gutter:
        // a full-width title/caption/conclusion legitimately crosses that gutter.
        // Instead, it relies on recurring lane separation plus row transitions.
        let mixedRegionEvidence = mixedRegions
            && dominantClusters.count >= 2
            && rowStats.alignedMultiItemRowCount >= 2
            && laneSeparation >= 0.015

        if mixedRegionEvidence {
            let confidence = clampedConfidence(
                0.74
                    + min(0.10, Double(rowStats.alignedMultiItemRowCount) * 0.02)
                    + min(0.08, Double(dominantClusters.count - 1) * 0.04)
                    + min(0.06, Double(laneSeparation) * 0.35)
            )
            return assessment(
                .mixedRegions,
                confidence: confidence,
                quality: quality,
                features: features,
                reasons: [
                    "Multiple recurring horizontal lanes were detected.",
                    "Single-row/spanning structure changes the lane model by vertical region."
                ]
            )
        }

        // Persistent lane separation is sufficient even when left/right lines do
        // not share a baseline (for example one column starts lower). Requiring
        // side-by-side rows alone would miss those layouts.
        let multiColumnEvidence = dominantClusters.count >= 2
            && laneSeparation >= 0.025
            && (
                rowStats.alignedMultiItemRowCount >= 2
                    || dominantClusters.allSatisfy { $0.indices.count >= 2 }
            )

        if multiColumnEvidence {
            let confidence = clampedConfidence(
                0.68
                    + min(0.14, Double(rowStats.alignedMultiItemRowCount) * 0.025)
                    + min(0.10, Double(dominantClusters.count - 1) * 0.05)
                    + min(0.08, Double(laneSeparation) * 0.40)
            )
            return assessment(
                .likelyMultiColumn,
                confidence: confidence,
                quality: quality,
                features: features,
                reasons: [
                    "Two or more stable left-edge lanes recur on the page.",
                    "Typical lane extents leave a persistent interior separation."
                ]
            )
        }

        if sideLane {
            let confidence = clampedConfidence(
                0.68 + min(0.12, Double(leftClusters.count - 1) * 0.04)
            )
            return assessment(
                .irregularPositioned,
                confidence: confidence,
                quality: quality,
                features: features,
                reasons: [
                    "A sparse side lane overlaps the vertical range of the dominant body lane."
                ]
            )
        }

        // A lone separated pair or overlapping indentation pattern is not enough
        // evidence to disturb the fast path. This protects sparse pages, poems,
        // dialogue, transformed pages, indented quotes, and numbered lists.
        if dominantClusters.count <= 1 && rowStats.sideBySideRowCount <= 1 {
            let confidence = clampedConfidence(
                leftClusters.count <= 2 ? 0.94 : 0.86
            )
            return PdfLayoutComplexityAssessment(
                complexity: .simpleSingleColumn,
                confidence: confidence,
                shouldAnalyze: false,
                nativeTextQuality: quality,
                features: features,
                reasons: ["No repeated multi-lane layout evidence exceeded the conservative gate."]
            )
        }

        return PdfLayoutComplexityAssessment(
            complexity: .unknown,
            confidence: 0.45,
            shouldAnalyze: false,
            nativeTextQuality: quality,
            features: features,
            reasons: ["Geometry is ambiguous; keep the existing parser fast path."]
        )
    }

    private static func assessment(
        _ complexity: PdfLayoutComplexity,
        confidence: Double,
        quality: PdfNativeTextQuality?,
        features: PdfLayoutComplexityFeatures,
        reasons: [String]
    ) -> PdfLayoutComplexityAssessment {
        let normalized = clampedConfidence(confidence)
        return PdfLayoutComplexityAssessment(
            complexity: complexity,
            confidence: normalized,
            shouldAnalyze: normalized >= 0.62,
            nativeTextQuality: quality,
            features: features,
            reasons: reasons
        )
    }

    private struct EdgeCluster {
        var center: CGFloat
        var indices: [Int]

        mutating func append(index: Int, x: CGFloat) {
            let oldCount = CGFloat(indices.count)
            center = ((center * oldCount) + x) / (oldCount + 1)
            indices.append(index)
        }
    }

    private struct RowCluster {
        var centerY: CGFloat
        var indices: [Int]

        mutating func append(index: Int, y: CGFloat) {
            let oldCount = CGFloat(indices.count)
            centerY = ((centerY * oldCount) + y) / (oldCount + 1)
            indices.append(index)
        }
    }

    private struct RowStatistics {
        let sideBySideRowCount: Int
        let alignedMultiItemRowCount: Int
        let tightAlignedRowCount: Int
        let maximumItemsPerRow: Int
        let singleItemRowCount: Int
        let sideBySideRowIndices: Set<Int>
        let singleItemRowIndices: Set<Int>
    }

    private static func clusterLeftEdges(
        _ fragments: [PdfLayoutFragment],
        tolerance: CGFloat
    ) -> [EdgeCluster] {
        let ordered = fragments.indices.sorted {
            fragments[$0].rect.minX < fragments[$1].rect.minX
        }
        var clusters: [EdgeCluster] = []

        for index in ordered {
            let x = fragments[index].rect.minX
            if var last = clusters.last, abs(last.center - x) <= tolerance {
                last.append(index: index, x: x)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append(EdgeCluster(center: x, indices: [index]))
            }
        }
        return clusters
    }

    private static func clusterRows(
        _ fragments: [PdfLayoutFragment],
        tolerance: CGFloat
    ) -> [RowCluster] {
        let ordered = fragments.indices.sorted {
            fragments[$0].rect.midY < fragments[$1].rect.midY
        }
        var rows: [RowCluster] = []

        for index in ordered {
            let y = fragments[index].rect.midY
            if var last = rows.last, abs(last.centerY - y) <= tolerance {
                last.append(index: index, y: y)
                rows[rows.count - 1] = last
            } else {
                rows.append(RowCluster(centerY: y, indices: [index]))
            }
        }
        return rows
    }

    private static func rowStatistics(
        rows: [RowCluster],
        fragments: [PdfLayoutFragment]
    ) -> RowStatistics {
        var sideBySideRows: Set<Int> = []
        var singleRows: Set<Int> = []
        var alignedMultiItemRows = 0
        var tightAlignedRows = 0
        var maximumItems = 0

        for (rowIndex, row) in rows.enumerated() {
            maximumItems = max(maximumItems, row.indices.count)
            let ordered = row.indices.sorted {
                fragments[$0].rect.minX < fragments[$1].rect.minX
            }

            if ordered.count >= 2 {
                alignedMultiItemRows += 1
                var hasMeaningfulGap = false
                var positiveGaps: [CGFloat] = []
                for pairIndex in 0..<(ordered.count - 1) {
                    let lhs = fragments[ordered[pairIndex]].rect
                    let rhs = fragments[ordered[pairIndex + 1]].rect
                    let gap = rhs.minX - lhs.maxX
                    if gap > 0 { positiveGaps.append(gap) }
                    if gap >= 0.035 {
                        hasMeaningfulGap = true
                    }
                }

                if hasMeaningfulGap {
                    sideBySideRows.insert(rowIndex)
                }

                if ordered.count >= 3,
                   !positiveGaps.isEmpty,
                   median(positiveGaps) <= 0.030 {
                    tightAlignedRows += 1
                }
            } else if row.indices.count == 1 {
                singleRows.insert(rowIndex)
            }
        }

        return RowStatistics(
            sideBySideRowCount: sideBySideRows.count,
            alignedMultiItemRowCount: alignedMultiItemRows,
            tightAlignedRowCount: tightAlignedRows,
            maximumItemsPerRow: maximumItems,
            singleItemRowCount: singleRows.count,
            sideBySideRowIndices: sideBySideRows,
            singleItemRowIndices: singleRows
        )
    }

    private static func detectsMixedVerticalRegions(
        fragments: [PdfLayoutFragment],
        rows: [RowCluster],
        rowStats: RowStatistics,
        dominantClusters: [EdgeCluster],
        medianFragmentWidth: CGFloat
    ) -> Bool {
        guard dominantClusters.count >= 2,
              !rowStats.sideBySideRowIndices.isEmpty,
              !rowStats.singleItemRowIndices.isEmpty else {
            return false
        }

        let multiRows = rowStats.sideBySideRowIndices.sorted()
        guard let firstMulti = multiRows.first,
              let lastMulti = multiRows.last else {
            return false
        }

        var hasSingleBefore = false
        var hasSingleAfter = false
        var hasSingleInside = false
        var hasStrongSingleton = false

        let fontSizes = fragments.compactMap { $0.style?.fontSize }
        let medianFontSize = fontSizes.isEmpty ? 0 : median(fontSizes)

        for rowIndex in rowStats.singleItemRowIndices {
            guard let fragmentIndex = rows[rowIndex].indices.first else { continue }
            let fragment = fragments[fragmentIndex]

            if rowIndex < firstMulti { hasSingleBefore = true }
            if rowIndex > lastMulti { hasSingleAfter = true }
            if rowIndex > firstMulti && rowIndex < lastMulti { hasSingleInside = true }

            // 1.30 is intentionally only used after strong recurring multi-lane
            // evidence. It captures a conclusion/summary whose glyph bounds are
            // wider than a column but do not span the full declared text box.
            let isWide = medianFragmentWidth > 0
                && fragment.rect.width >= medianFragmentWidth * 1.30
            let isEmphasized = (fragment.style?.isBold == true)
                || (medianFontSize > 0
                    && (fragment.style?.fontSize ?? 0) >= medianFontSize * 1.22)
            let bridgesLaneGap = fragmentBridgesDominantLaneGap(
                fragment.rect,
                fragments: fragments,
                clusters: dominantClusters
            )
            if isWide || isEmphasized || bridgesLaneGap {
                hasStrongSingleton = true
            }
        }

        return hasSingleInside
            || (hasSingleBefore && hasSingleAfter)
            || ((hasSingleBefore || hasSingleAfter) && hasStrongSingleton)
    }

    private static func detectsNarrowSideLane(
        fragments: [PdfLayoutFragment],
        clusters: [EdgeCluster],
        dominantClusters: [EdgeCluster]
    ) -> Bool {
        guard dominantClusters.count == 1,
              let dominant = dominantClusters.first,
              !dominant.indices.isEmpty else {
            return false
        }

        let bodyRects = dominant.indices.map { fragments[$0].rect }
        let bodyMinY = bodyRects.map(\.minY).min() ?? 0
        let bodyMaxY = bodyRects.map(\.maxY).max() ?? 0
        let dominantIndexSet = Set(dominant.indices)

        for cluster in clusters where !cluster.indices.contains(where: dominantIndexSet.contains) {
            for index in cluster.indices {
                let fragment = fragments[index]
                let horizontallySeparated = abs(fragment.rect.minX - dominant.center) >= 0.14
                let verticallyOverlapsBody = fragment.rect.midY >= bodyMinY - 0.02
                    && fragment.rect.midY <= bodyMaxY + 0.02
                if horizontallySeparated && verticallyOverlapsBody {
                    return true
                }
            }
        }
        return false
    }

    /// Measures separation using only recurring lane members, so a one-off
    /// full-width heading/caption does not erase an otherwise strong gutter.
    private static func dominantLaneSeparation(
        fragments: [PdfLayoutFragment],
        clusters: [EdgeCluster]
    ) -> CGFloat {
        guard clusters.count >= 2 else { return 0 }
        let ordered = clusters.sorted { $0.center < $1.center }
        var maximumSeparation: CGFloat = 0

        for index in 0..<(ordered.count - 1) {
            let lhs = ordered[index]
            let rhs = ordered[index + 1]
            let lhsRight = median(lhs.indices.map { fragments[$0].rect.maxX })
            let rhsLeft = median(rhs.indices.map { fragments[$0].rect.minX })
            maximumSeparation = max(maximumSeparation, rhsLeft - lhsRight)
        }

        return max(0, maximumSeparation)
    }

    private static func fragmentBridgesDominantLaneGap(
        _ rect: CGRect,
        fragments: [PdfLayoutFragment],
        clusters: [EdgeCluster]
    ) -> Bool {
        guard clusters.count >= 2 else { return false }
        let ordered = clusters.sorted { $0.center < $1.center }

        for index in 0..<(ordered.count - 1) {
            let lhs = ordered[index]
            let rhs = ordered[index + 1]
            let lhsRight = median(lhs.indices.map { fragments[$0].rect.maxX })
            let rhsLeft = median(rhs.indices.map { fragments[$0].rect.minX })
            let gap = rhsLeft - lhsRight
            guard gap >= 0.015 else { continue }

            let innerStart = lhsRight + gap * 0.35
            let innerEnd = rhsLeft - gap * 0.35
            if rect.minX <= innerStart && rect.maxX >= innerEnd {
                return true
            }
        }
        return false
    }

    private static func longestInteriorGutter(
        fragments: [PdfLayoutFragment],
        binCount: Int = 64
    ) -> CGFloat {
        guard binCount > 2 else { return 0 }
        var occupied = Array(repeating: false, count: binCount)
        let binWidth = 1 / CGFloat(binCount)

        for fragment in fragments {
            let rect = fragment.rect.standardized
            let start = max(0, min(binCount - 1, Int(floor(rect.minX / binWidth))))
            let end = max(0, min(binCount - 1, Int(floor(max(rect.minX, rect.maxX - 0.000_001) / binWidth))))
            if start <= end {
                for index in start...end {
                    occupied[index] = true
                }
            }
        }

        guard let firstOccupied = occupied.firstIndex(of: true),
              let lastOccupied = occupied.lastIndex(of: true),
              firstOccupied < lastOccupied else {
            return 0
        }

        var longest = 0
        var current = 0
        if firstOccupied + 1 < lastOccupied {
            for index in (firstOccupied + 1)..<lastOccupied {
                if occupied[index] {
                    longest = max(longest, current)
                    current = 0
                } else {
                    current += 1
                }
            }
        }
        longest = max(longest, current)
        return CGFloat(longest) * binWidth
    }

    private static func semanticCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                count += 1
            }
        }
    }

    private static func ratio<T>(_ values: [T], matching predicate: (T) -> Bool) -> Double {
        guard !values.isEmpty else { return 0 }
        let matches = values.reduce(into: 0) { count, value in
            if predicate(value) { count += 1 }
        }
        return Double(matches) / Double(values.count)
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

    private static func clampedConfidence(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
