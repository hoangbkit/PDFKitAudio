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
    let maximumItemsPerRow: Int
    let singleItemRowCount: Int
    let longestInteriorGutter: CGFloat
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
                maximumItemsPerRow: 0,
                singleItemRowCount: 0,
                longestInteriorGutter: 0,
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
        let gutter = longestInteriorGutter(fragments: valid)
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
            dominantLaneCount: dominantClusters.count,
            medianFragmentWidth: medianWidth
        )

        let features = PdfLayoutComplexityFeatures(
            fragmentCount: valid.count,
            leftEdgeClusterCount: leftClusters.count,
            dominantLaneCount: dominantClusters.count,
            sideBySideRowCount: rowStats.sideBySideRowCount,
            maximumItemsPerRow: rowStats.maximumItemsPerRow,
            singleItemRowCount: rowStats.singleItemRowCount,
            longestInteriorGutter: gutter,
            medianFragmentWidth: medianWidth,
            medianFragmentHeight: medianHeight,
            shortTextRatio: shortTextRatio,
            narrowSideLaneDetected: sideLane,
            mixedVerticalRegionsDetected: mixedRegions
        )

        let tableEvidence = rowStats.sideBySideRowCount >= 2
            && rowStats.maximumItemsPerRow >= 2
            && shortTextRatio >= 0.72
            && dominantClusters.count >= 2
            && gutter >= 0.025

        if tableEvidence {
            let confidence = clampedConfidence(
                0.72
                    + min(0.12, Double(rowStats.sideBySideRowCount) * 0.025)
                    + (rowStats.maximumItemsPerRow >= 3 ? 0.08 : 0)
                    + (shortTextRatio >= 0.90 ? 0.05 : 0)
            )
            return assessment(
                .likelyTableHeavy,
                confidence: confidence,
                quality: quality,
                features: features,
                reasons: [
                    "Repeated aligned multi-item rows were detected.",
                    "Most positioned fragments are short cell-like strings."
                ]
            )
        }

        let multiColumnEvidence = dominantClusters.count >= 2
            && rowStats.sideBySideRowCount >= 2
            && gutter >= 0.035

        if multiColumnEvidence && mixedRegions {
            let confidence = clampedConfidence(
                0.72
                    + min(0.12, Double(rowStats.sideBySideRowCount) * 0.025)
                    + min(0.08, Double(dominantClusters.count - 1) * 0.04)
                    + min(0.06, Double(gutter) * 0.30)
            )
            return assessment(
                .mixedRegions,
                confidence: confidence,
                quality: quality,
                features: features,
                reasons: [
                    "Multiple stable horizontal lanes were detected.",
                    "The number or width/style of lanes changes by vertical region."
                ]
            )
        }

        if multiColumnEvidence {
            let confidence = clampedConfidence(
                0.68
                    + min(0.14, Double(rowStats.sideBySideRowCount) * 0.03)
                    + min(0.10, Double(dominantClusters.count - 1) * 0.05)
                    + min(0.06, Double(gutter) * 0.30)
            )
            return assessment(
                .likelyMultiColumn,
                confidence: confidence,
                quality: quality,
                features: features,
                reasons: [
                    "Two or more stable left-edge lanes recur across rows.",
                    "A persistent interior horizontal gutter separates those lanes."
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

        // A lone separated pair is not enough evidence to disturb the fast path.
        // This protects sparse pages, poems, dialogue, transformed pages, and
        // numbered lists from being over-classified.
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
        var maximumItems = 0

        for (rowIndex, row) in rows.enumerated() {
            maximumItems = max(maximumItems, row.indices.count)
            let ordered = row.indices.sorted {
                fragments[$0].rect.minX < fragments[$1].rect.minX
            }
            var hasMeaningfulGap = false
            if ordered.count >= 2 {
                for pairIndex in 0..<(ordered.count - 1) {
                    let lhs = fragments[ordered[pairIndex]].rect
                    let rhs = fragments[ordered[pairIndex + 1]].rect
                    if rhs.minX - lhs.maxX >= 0.035 {
                        hasMeaningfulGap = true
                        break
                    }
                }
            }

            if hasMeaningfulGap {
                sideBySideRows.insert(rowIndex)
            } else if row.indices.count == 1 {
                singleRows.insert(rowIndex)
            }
        }

        return RowStatistics(
            sideBySideRowCount: sideBySideRows.count,
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
        dominantLaneCount: Int,
        medianFragmentWidth: CGFloat
    ) -> Bool {
        guard dominantLaneCount >= 2,
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

            let isWide = medianFragmentWidth > 0
                && fragment.rect.width >= medianFragmentWidth * 1.45
            let isEmphasized = (fragment.style?.isBold == true)
                || (medianFontSize > 0
                    && (fragment.style?.fontSize ?? 0) >= medianFontSize * 1.22)
            if isWide || isEmphasized {
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
