import Foundation

/// Persistent whitespace measured between occupied line intervals. Coordinates
/// are normalized with the same top-left origin as positioned fragments.
struct PdfLayoutGutter: Equatable {
    let minX: CGFloat
    let maxX: CGFloat
    let verticalRange: ClosedRange<CGFloat>
    let confidence: Double

    var center: CGFloat { (minX + maxX) / 2 }
}

/// The conservative ordinary-column path. It runs before block clustering and
/// table inference, which can otherwise turn short column prose into table rows.
/// Mixed interior spans, sparse side lanes, and cell-like text use the general
/// resolver. No text is synthesized or removed here.
enum PdfSimpleColumnLayout {
    struct Result {
        let gutters: [PdfLayoutGutter]
        let blocks: [PdfLayoutBlock]
        let layout: PdfPageRegionLayout
        let analysis: PdfSpecialStructureAnalysis
        let readingOrder: PdfReadingOrderResult
    }

    static func resolve(
        lines: [PdfLayoutLine],
        establishedGutters: [PdfLayoutGutter]? = nil,
        minimumLaneLineCount: Int = 2
    ) -> Result? {
        let gutters = establishedGutters ?? persistentGutters(lines: lines)
        guard (1...2).contains(gutters.count),
              let bodyTop = gutters.map({ $0.verticalRange.lowerBound }).min(),
              let pairedBottom = gutters.map({ $0.verticalRange.upperBound }).max() else { return nil }

        let sorted = lines.sorted(by: verticalOrder)
        let rowStarts = Array(Set(sorted.map { $0.rect.minY })).sorted()
        let gaps = zip(rowStarts, rowStarts.dropFirst()).map { $1 - $0 }.filter { $0 > 0.005 }
        let normalGap = median(gaps)
        // A detached trailing section is outside the columns. Ordinary unequal
        // column heights stay in their lanes until a genuine vertical break.
        var bodyBottom: CGFloat = 1
        var previousBottom = pairedBottom
        for line in sorted where line.rect.minY > pairedBottom {
            if line.rect.minY - previousBottom > max(0.045, normalGap * 1.5) {
                bodyBottom = previousBottom
                break
            }
            previousBottom = max(previousBottom, line.rect.maxY)
        }

        var prefix: [PdfLayoutLine] = []
        var suffix: [PdfLayoutLine] = []
        var lanes = Array(repeating: [PdfLayoutLine](), count: gutters.count + 1)
        let pairedLines = sorted.filter { $0.rect.minY >= bodyTop - 0.001 && $0.rect.maxY <= pairedBottom + 0.001 }
        for line in sorted {
            let lane = gutters.filter { line.rect.midX > $0.center }.count
            if line.rect.maxY < bodyTop + 0.001 {
                let continuesLane = pairedLines.contains { candidate in
                    gutters.filter { candidate.rect.midX > $0.center }.count == lane
                        && abs(candidate.rect.minX - line.rect.minX) <= 0.015
                        && min(candidate.rect.height, line.rect.height) / max(candidate.rect.height, line.rect.height) >= 0.90
                }
                if continuesLane {
                    lanes[lane].append(line)
                } else {
                    prefix.append(line)
                }
                continue
            }
            if line.rect.minY > bodyBottom {
                suffix.append(line)
                continue
            }
            let crosses = gutters.contains { line.rect.minX < $0.center && line.rect.maxX > $0.center }
            if crosses {
                // A full-width ending can follow the columns, but an interior
                // span requires the mixed-region resolver.
                guard line.rect.minY > pairedBottom else { return nil }
                suffix.append(line)
                bodyBottom = min(bodyBottom, line.rect.minY - 0.001)
                continue
            }
            if line.rect.minY > pairedBottom {
                let established = lanes[lane].filter { $0.rect.minY <= pairedBottom }
                guard established.contains(where: { abs($0.rect.minX - line.rect.minX) <= 0.015 }) else {
                    // A trailing inset/full-width section whose short text does
                    // not physically cross the gutter is still mixed structure.
                    return nil
                }
            }
            lanes[lane].append(line)
        }

        guard lanes.allSatisfy({ $0.count >= minimumLaneLineCount }) else { return nil }
        let counts = lanes.map(\.count)
        guard Double(counts.min()!) / Double(counts.max()!) >= 0.35 else { return nil }
        let heights = lanes.map { median($0.map { $0.rect.height }) }
        guard heights.min()! / heights.max()! >= 0.80 else { return nil }

        // Geometry alone cannot distinguish a borderless table from aligned
        // columns. Require sentence evidence in every lane; compact cell grids
        // retain their table path. Wrapped prose may end only every few lines.
        guard lanes.allSatisfy({ lane in
            let endings = lane.filter {
                guard let last = $0.text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
                return ".!?。！？".contains(last)
            }.count
            return endings >= minimumLaneLineCount && Double(endings) / Double(lane.count) >= 0.30
        }) else { return nil }

        let rtl = lanes.flatMap { $0 }.filter { $0.writingDirection == .rightToLeft }.count
        let direction: PdfLayoutWritingDirection = rtl * 2 > counts.reduce(0, +) ? .rightToLeft : .leftToRight
        let laneOrder = direction == .rightToLeft ? Array(lanes.indices.reversed()) : Array(lanes.indices)
        var blocks: [PdfLayoutBlock] = []
        func appendBlocks(_ lines: [PdfLayoutLine]) -> [Int] {
            let built = PdfLayoutBlockBuilder.build(lines: lines)
            return built.map { block in
                let id = blocks.count
                blocks.append(PdfLayoutBlock(id: id, lines: block.lines, text: block.text,
                                             rect: block.rect, sourceOrder: block.sourceOrder))
                return id
            }
        }
        let prefixIDs = appendBlocks(prefix)
        var columns: [PdfLayoutColumn] = []
        for lane in laneOrder {
            let ids = appendBlocks(lanes[lane])
            columns.append(PdfLayoutColumn(id: lane, rect: union(lanes[lane].map(\.rect)), blockIDs: ids, confidence: 0.94))
        }
        let suffixIDs = appendBlocks(suffix)
        var regions: [PdfLayoutRegion] = []
        func appendOuterRegion(_ ids: [Int]) {
            guard !ids.isEmpty else { return }
            regions.append(PdfLayoutRegion(id: regions.count, rect: union(ids.map { blocks[$0].rect }),
                kind: .spanning, columns: [], primaryBlockIDs: [], sidebarBlockIDs: [],
                spanningBlockIDs: ids, confidence: 0.94))
        }
        appendOuterRegion(prefixIDs)
        regions.append(PdfLayoutRegion(id: regions.count, rect: union(columns.map(\.rect)), kind: .columnar,
            columns: columns.sorted { $0.id < $1.id }, primaryBlockIDs: columns.flatMap(\.blockIDs),
            sidebarBlockIDs: [], spanningBlockIDs: [], confidence: 0.94))
        appendOuterRegion(suffixIDs)
        let layout = PdfPageRegionLayout(regions: regions, primaryColumnCount: lanes.count,
            sidebarBlockIDs: [], spanningBlockIDs: prefixIDs + suffixIDs)
        let analysis = PdfSpecialStructureAnalysis(assignments: blocks.map {
            PdfLayoutRoleAssignment(blockID: $0.id, role: .body, confidence: 0.94,
                signals: ["Persistent gutters and sentence-bearing column lanes"])
        }, tables: [], readingOrderHints: PdfReadingOrderHints(writingDirection: direction))
        return Result(gutters: gutters, blocks: blocks, layout: layout, analysis: analysis,
            readingOrder: PdfReadingOrderResult(orderedBlockIDs: blocks.map(\.id), confidence: 0.94,
                writingDirection: direction, removedEdges: [], geometryConflictCount: 0, usedFallback: false,
                diagnostics: ["Direct column-major order from \(gutters.count) persistent whitespace gutter(s)."]))
    }

    /// Intersect recurring empty X intervals, rather than clustering block left
    /// edges or guessing from page-width percentages. Short last lines contribute
    /// wider intervals without moving the persistent core of a gutter.
    static func persistentGutters(lines: [PdfLayoutLine], minimumRows: Int = 2) -> [PdfLayoutGutter] {
        struct Evidence {
            var minX: CGFloat
            var maxX: CGFloat
            var top: CGFloat
            var bottom: CGFloat
            var rows: Set<Int>
        }
        let sorted = lines.sorted(by: verticalOrder)
        var evidence: [Evidence] = []
        for (index, left) in sorted.enumerated() {
            for right in sorted.dropFirst(index + 1) {
                if right.rect.minY > left.rect.maxY { break }
                let overlap = min(left.rect.maxY, right.rect.maxY) - max(left.rect.minY, right.rect.minY)
                guard overlap > min(left.rect.height, right.rect.height) * 0.5 else { continue }
                let a = left.rect.minX < right.rect.minX ? left : right
                let b = left.rect.minX < right.rect.minX ? right : left
                guard b.rect.minX - a.rect.maxX >= 0.015 else { continue }
                // Only adjacent occupied intervals can bound a gutter.
                guard !sorted.contains(where: {
                    $0.rect.minX > a.rect.minX && $0.rect.minX < b.rect.minX
                        && $0.rect.maxY > max(a.rect.minY, b.rect.minY)
                        && $0.rect.minY < min(a.rect.maxY, b.rect.maxY)
                }) else { continue }
                if let match = evidence.indices.first(where: {
                    min(evidence[$0].maxX, b.rect.minX) - max(evidence[$0].minX, a.rect.maxX) >= 0.015
                }) {
                    evidence[match].minX = max(evidence[match].minX, a.rect.maxX)
                    evidence[match].maxX = min(evidence[match].maxX, b.rect.minX)
                    evidence[match].top = min(evidence[match].top, a.rect.minY, b.rect.minY)
                    evidence[match].bottom = max(evidence[match].bottom, a.rect.maxY, b.rect.maxY)
                    evidence[match].rows.insert(index)
                } else {
                    evidence.append(Evidence(minX: a.rect.maxX, maxX: b.rect.minX,
                        top: min(a.rect.minY, b.rect.minY), bottom: max(a.rect.maxY, b.rect.maxY), rows: [index]))
                }
            }
        }
        return evidence.filter { $0.rows.count >= minimumRows && (minimumRows == 1 || $0.bottom - $0.top >= 0.025) }.map {
            PdfLayoutGutter(minX: $0.minX, maxX: $0.maxX, verticalRange: $0.top...$0.bottom, confidence: 0.94)
        }.sorted { $0.minX < $1.minX }
    }

    static func fragmentGutters(_ fragments: [PdfLayoutFragment]) -> [PdfLayoutGutter] {
        persistentGutters(lines: fragments.map {
            PdfLayoutLine(id: $0.id, fragments: [$0], text: $0.text, rect: $0.rect,
                writingDirection: .leftToRight, sourceOrder: $0.sourceOrder)
        })
    }

    private static func verticalOrder(_ lhs: PdfLayoutLine, _ rhs: PdfLayoutLine) -> Bool {
        if lhs.rect.minY != rhs.rect.minY { return lhs.rect.minY < rhs.rect.minY }
        if lhs.rect.minX != rhs.rect.minX { return lhs.rect.minX < rhs.rect.minX }
        return lhs.id < rhs.id
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    private static func union(_ rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }
}
