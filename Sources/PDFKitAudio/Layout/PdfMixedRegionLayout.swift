import Foundation

/// Resolve clear full-width/column transitions before paragraph merging can
/// connect text across a spanning heading or caption. Each band gets its own
/// gutter extent and column sequence; ambiguous bands use the general resolver.
enum PdfMixedRegionLayout {
    static func resolve(lines: [PdfLayoutLine]) -> PdfSimpleColumnLayout.Result? {
        let gutters = PdfSimpleColumnLayout.persistentGutters(lines: lines)
        guard (1...2).contains(gutters.count) else { return nil }
        let ordered = lines.sorted {
            if $0.rect.minY != $1.rect.minY { return $0.rect.minY < $1.rect.minY }
            if $0.rect.minX != $1.rect.minX { return $0.rect.minX < $1.rect.minX }
            return $0.id < $1.id
        }
        let spans = ordered.filter { line in
            gutters.contains { line.rect.minX < $0.center && line.rect.maxX > $0.center }
                && !ordered.contains { other in
                    other.id != line.id
                        && min(other.rect.maxY, line.rect.maxY) - max(other.rect.minY, line.rect.minY)
                            > min(other.rect.height, line.rect.height) * 0.35
                }
        }
        guard !spans.isEmpty else { return nil }

        var blocks: [PdfLayoutBlock] = []
        var regions: [PdfLayoutRegion] = []
        var assignments: [PdfLayoutRoleAssignment] = []
        var regionalGutters: [PdfLayoutGutter] = []
        var directions: [PdfLayoutWritingDirection] = []

        func appendSpanning(_ band: [PdfLayoutLine]) {
            guard !band.isEmpty else { return }
            let ids = PdfLayoutBlockBuilder.build(lines: band).map { block -> Int in
                let id = blocks.count
                blocks.append(PdfLayoutBlock(id: id, lines: block.lines, text: block.text,
                    rect: block.rect, sourceOrder: block.sourceOrder))
                assignments.append(PdfLayoutRoleAssignment(blockID: id,
                    role: block.lines.contains { $0.isPredominantlyBold == true } ? .heading : .body,
                    confidence: 0.92, signals: ["Spanning text between established column bands"]))
                return id
            }
            regions.append(PdfLayoutRegion(id: regions.count, rect: union(band.map(\.rect)),
                kind: .spanning, columns: [], primaryBlockIDs: [], sidebarBlockIDs: [],
                spanningBlockIDs: ids, confidence: 0.92))
        }

        func appendBand(_ band: [PdfLayoutLine]) -> Bool {
            guard !band.isEmpty else { return true }
            // A short region can contain one row per lane. Its gutter must agree
            // with persistent evidence elsewhere on the page before using it.
            var local = PdfSimpleColumnLayout.persistentGutters(lines: band, minimumRows: 1)
            if local.isEmpty {
                // Baselines need not coincide in adjacent columns. Extend an
                // established gutter only when both occupied lanes coexist
                // vertically and the band still leaves that gutter empty.
                local = gutters.compactMap { gutter in
                    let left = band.filter { $0.rect.maxX <= gutter.center }
                    let right = band.filter { $0.rect.minX >= gutter.center }
                    guard left.count >= 2, right.count >= 2,
                          left.count + right.count == band.count else { return nil }
                    let leftBounds = union(left.map(\.rect))
                    let rightBounds = union(right.map(\.rect))
                    guard leftBounds.maxX + 0.015 <= rightBounds.minX,
                          min(leftBounds.maxY, rightBounds.maxY) > max(leftBounds.minY, rightBounds.minY) else { return nil }
                    return PdfLayoutGutter(minX: leftBounds.maxX, maxX: rightBounds.minX,
                        verticalRange: min(leftBounds.minY, rightBounds.minY)...max(leftBounds.maxY, rightBounds.maxY),
                        confidence: 0.92)
                }
                if local.isEmpty {
                    // Multiple separated lanes with insufficient continuity are
                    // ambiguous, not evidence for a full-width paragraph.
                    guard !gutters.contains(where: { gutter in
                        band.contains { $0.rect.maxX <= gutter.center }
                            && band.contains { $0.rect.minX >= gutter.center }
                    }) else { return false }
                    appendSpanning(band)
                    return true
                }
            }
            guard local.allSatisfy({ candidate in
                gutters.contains {
                    min(candidate.maxX, $0.maxX) - max(candidate.minX, $0.minX) >= 0.015
                }
            }), let result = PdfSimpleColumnLayout.resolve(lines: band,
                establishedGutters: local, minimumLaneLineCount: 1) else { return false }

            let offset = blocks.count
            for block in result.blocks {
                blocks.append(PdfLayoutBlock(id: block.id + offset, lines: block.lines, text: block.text,
                    rect: block.rect, sourceOrder: block.sourceOrder))
            }
            assignments += result.analysis.assignments.map {
                PdfLayoutRoleAssignment(blockID: $0.blockID + offset, role: $0.role,
                    confidence: $0.confidence, signals: $0.signals)
            }
            for region in result.layout.regions {
                regions.append(PdfLayoutRegion(id: regions.count, rect: region.rect, kind: region.kind,
                    columns: region.columns.map {
                        PdfLayoutColumn(id: $0.id, rect: $0.rect,
                            blockIDs: $0.blockIDs.map { $0 + offset }, confidence: $0.confidence)
                    }, primaryBlockIDs: region.primaryBlockIDs.map { $0 + offset },
                    sidebarBlockIDs: [], spanningBlockIDs: region.spanningBlockIDs.map { $0 + offset },
                    confidence: region.confidence))
            }
            regionalGutters += result.gutters
            directions.append(result.readingOrder.writingDirection)
            return true
        }

        let spanIDs = Set(spans.map(\.id))
        var band: [PdfLayoutLine] = []
        var pendingSpans: [PdfLayoutLine] = []
        for line in ordered {
            if spanIDs.contains(line.id) {
                guard appendBand(band) else { return nil }
                band = []
                pendingSpans.append(line)
            } else {
                appendSpanning(pendingSpans)
                pendingSpans = []
                band.append(line)
            }
        }
        guard appendBand(band) else { return nil }
        appendSpanning(pendingSpans)
        guard !directions.isEmpty else { return nil }
        let direction = directions.filter { $0 == .rightToLeft }.count * 2 > directions.count
            ? PdfLayoutWritingDirection.rightToLeft : .leftToRight
        let layout = PdfPageRegionLayout(regions: regions,
            primaryColumnCount: regions.map { $0.columns.count }.max() ?? 0,
            sidebarBlockIDs: [], spanningBlockIDs: regions.flatMap(\.spanningBlockIDs))
        return PdfSimpleColumnLayout.Result(gutters: regionalGutters, blocks: blocks, layout: layout,
            analysis: PdfSpecialStructureAnalysis(assignments: assignments, tables: [],
                readingOrderHints: PdfReadingOrderHints(writingDirection: direction)),
            readingOrder: PdfReadingOrderResult(orderedBlockIDs: blocks.map(\.id), confidence: 0.92,
                writingDirection: direction, removedEdges: [], geometryConflictCount: 0, usedFallback: false,
                diagnostics: ["Direct region sequence with \(directions.count) gutter-bounded column band(s)."]))
    }

    private static func union(_ rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }
}
