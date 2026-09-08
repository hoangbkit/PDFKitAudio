import Foundation

/// Debug-only, page-local diagnostics for the geometry-first layout pipeline.
///
/// The public parser API intentionally does not expose this type. Diagnostics are
/// created only when an internal caller supplies a capture hook to
/// `PdfLayoutAnalyzer.analyze`, so normal parsing keeps the same page-bounded
/// memory behavior and does not pay JSON/text formatting costs.
enum PdfLayoutDiagnostics {
    enum Decision: String, Codable, Equatable {
        case accepted
        case fastPath
        case fallback
    }

    struct Rect: Codable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: CGRect) {
            x = Double(rect.minX)
            y = Double(rect.minY)
            width = Double(rect.width)
            height = Double(rect.height)
        }
    }

    struct FragmentRecord: Codable, Equatable {
        let id: Int
        let sourceOrder: Int
        let source: String
        let confidence: Double
        let rect: Rect
        let text: String
    }

    struct LineRecord: Codable, Equatable {
        let id: Int
        let sourceOrder: Int
        let direction: String
        let rect: Rect
        let fragmentIDs: [Int]
        let text: String
    }

    struct BlockRecord: Codable, Equatable {
        let id: Int
        let sourceOrder: Int
        let rect: Rect
        let lineIDs: [Int]
        let role: String
        let roleConfidence: Double
        let text: String
    }

    struct ColumnRecord: Codable, Equatable {
        let id: Int
        let rect: Rect
        let blockIDs: [Int]
        let confidence: Double
    }

    struct GutterRecord: Codable, Equatable {
        let regionID: Int
        let leftColumnID: Int
        let rightColumnID: Int
        let x: Double
        let width: Double
    }

    struct RegionRecord: Codable, Equatable {
        let id: Int
        let kind: String
        let rect: Rect
        let confidence: Double
        let primaryBlockIDs: [Int]
        let sidebarBlockIDs: [Int]
        let spanningBlockIDs: [Int]
        let columns: [ColumnRecord]
    }

    struct EdgeRecord: Codable, Equatable {
        let fromBlockID: Int
        let toBlockID: Int
        let confidence: Double
        let reason: String
    }

    struct ComplexityRecord: Codable, Equatable {
        let category: String
        let confidence: Double
        let shouldAnalyze: Bool
        let reasons: [String]
        let fragmentCount: Int
        let dominantLaneCount: Int
        let sideBySideRowCount: Int
        let alignedMultiItemRowCount: Int
        let longestInteriorGutter: Double
        let dominantLaneSeparation: Double
        let narrowSideLaneDetected: Bool
        let mixedVerticalRegionsDetected: Bool
    }

    struct Snapshot: Codable, Equatable {
        let pageIndex: Int
        let mode: String
        let decision: Decision
        let decisionReason: String
        let complexity: ComplexityRecord?
        let fragments: [FragmentRecord]
        let lines: [LineRecord]
        let blocks: [BlockRecord]
        let regions: [RegionRecord]
        let gutters: [GutterRecord]
        let readingOrderEdges: [EdgeRecord]
        let removedReadingOrderEdges: [EdgeRecord]
        let orderedBlockIDs: [Int]
        let readingOrderConfidence: Double?
        let readingOrderUsedFallback: Bool?
        let readingOrderDiagnostics: [String]

        var textDescription: String {
            var output: [String] = []
            output.append("page=\(pageIndex) mode=\(mode) decision=\(decision.rawValue)")
            output.append("reason=\(decisionReason)")
            if let complexity {
                output.append(
                    "complexity=\(complexity.category) confidence=\(Self.number(complexity.confidence)) shouldAnalyze=\(complexity.shouldAnalyze)"
                )
                if !complexity.reasons.isEmpty {
                    output.append("complexityReasons=\(complexity.reasons.joined(separator: " | "))")
                }
            }
            output.append("fragments=\(fragments.count) lines=\(lines.count) blocks=\(blocks.count) regions=\(regions.count) gutters=\(gutters.count)")
            if let readingOrderConfidence {
                output.append(
                    "readingOrder confidence=\(Self.number(readingOrderConfidence)) fallback=\(readingOrderUsedFallback ?? false) order=\(orderedBlockIDs)"
                )
            }
            for region in regions {
                output.append(
                    "region[\(region.id)] kind=\(region.kind) confidence=\(Self.number(region.confidence)) columns=\(region.columns.map(\.id)) primary=\(region.primaryBlockIDs) sidebars=\(region.sidebarBlockIDs) spanning=\(region.spanningBlockIDs)"
                )
            }
            for gutter in gutters {
                output.append(
                    "gutter region=\(gutter.regionID) columns=\(gutter.leftColumnID)->\(gutter.rightColumnID) x=\(Self.number(gutter.x)) width=\(Self.number(gutter.width))"
                )
            }
            for edge in readingOrderEdges {
                output.append(
                    "edge \(edge.fromBlockID)->\(edge.toBlockID) reason=\(edge.reason) confidence=\(Self.number(edge.confidence))"
                )
            }
            for edge in removedReadingOrderEdges {
                output.append(
                    "removedEdge \(edge.fromBlockID)->\(edge.toBlockID) reason=\(edge.reason) confidence=\(Self.number(edge.confidence))"
                )
            }
            output.append(contentsOf: readingOrderDiagnostics.map { "readingOrderDiagnostic=\($0)" })
            return output.joined(separator: "\n")
        }

        var jsonString: String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private static func number(_ value: Double) -> String {
            String(format: "%.3f", value)
        }
    }

    struct Capture {
        private let pageIndex: Int
        private let mode: PdfLayoutMode
        private var fragments: [PdfLayoutFragment] = []
        private var assessment: PdfLayoutComplexityAssessment?
        private var lines: [PdfLayoutLine] = []
        private var blocks: [PdfLayoutBlock] = []
        private var layout: PdfPageRegionLayout?
        private var analysis: PdfSpecialStructureAnalysis?
        private var readingOrder: PdfReadingOrderResult?

        init(pageIndex: Int, mode: PdfLayoutMode) {
            self.pageIndex = pageIndex
            self.mode = mode
        }

        mutating func record(fragments: [PdfLayoutFragment]) {
            self.fragments = fragments
        }

        mutating func record(assessment: PdfLayoutComplexityAssessment) {
            self.assessment = assessment
        }

        mutating func record(lines: [PdfLayoutLine]) {
            self.lines = lines
        }

        mutating func record(blocks: [PdfLayoutBlock]) {
            self.blocks = blocks
        }

        mutating func record(layout: PdfPageRegionLayout, analysis: PdfSpecialStructureAnalysis) {
            self.layout = layout
            self.analysis = analysis
        }

        mutating func record(readingOrder: PdfReadingOrderResult) {
            self.readingOrder = readingOrder
        }

        func snapshot(decision: Decision, reason: String) -> Snapshot {
            let assignmentByBlockID = Dictionary(
                uniqueKeysWithValues: (analysis?.assignments ?? []).map { ($0.blockID, $0) }
            )

            let fragmentRecords = fragments.map { fragment in
                FragmentRecord(
                    id: fragment.id,
                    sourceOrder: fragment.sourceOrder,
                    source: sourceName(fragment.source),
                    confidence: fragment.confidence,
                    rect: Rect(fragment.rect),
                    text: clipped(fragment.text)
                )
            }
            let lineRecords = lines.map { line in
                LineRecord(
                    id: line.id,
                    sourceOrder: line.sourceOrder,
                    direction: directionName(line.writingDirection),
                    rect: Rect(line.rect),
                    fragmentIDs: line.fragments.map(\.id),
                    text: clipped(line.text)
                )
            }
            let blockRecords = blocks.map { block in
                let assignment = assignmentByBlockID[block.id]
                return BlockRecord(
                    id: block.id,
                    sourceOrder: block.sourceOrder,
                    rect: Rect(block.rect),
                    lineIDs: block.lines.map(\.id),
                    role: assignment?.role.rawValue ?? PdfLayoutRole.unknown.rawValue,
                    roleConfidence: assignment?.confidence ?? 0,
                    text: clipped(block.text)
                )
            }

            let regionRecords = (layout?.regions ?? []).map { region in
                RegionRecord(
                    id: region.id,
                    kind: region.kind.rawValue,
                    rect: Rect(region.rect),
                    confidence: region.confidence,
                    primaryBlockIDs: region.primaryBlockIDs,
                    sidebarBlockIDs: region.sidebarBlockIDs,
                    spanningBlockIDs: region.spanningBlockIDs,
                    columns: region.columns.map { column in
                        ColumnRecord(
                            id: column.id,
                            rect: Rect(column.rect),
                            blockIDs: column.blockIDs,
                            confidence: column.confidence
                        )
                    }
                )
            }

            let gutterRecords = (layout?.regions ?? []).flatMap { region in
                gutters(in: region)
            }
            let effectiveEdges = effectiveReadingOrderEdges(
                readingOrder: readingOrder,
                layout: layout,
                analysis: analysis
            )
            let removedEdges = readingOrder?.removedEdges.map(edgeRecord) ?? []

            let complexityRecord = assessment.map { assessment in
                ComplexityRecord(
                    category: assessment.complexity.rawValue,
                    confidence: assessment.confidence,
                    shouldAnalyze: assessment.shouldAnalyze,
                    reasons: assessment.reasons,
                    fragmentCount: assessment.features.fragmentCount,
                    dominantLaneCount: assessment.features.dominantLaneCount,
                    sideBySideRowCount: assessment.features.sideBySideRowCount,
                    alignedMultiItemRowCount: assessment.features.alignedMultiItemRowCount,
                    longestInteriorGutter: Double(assessment.features.longestInteriorGutter),
                    dominantLaneSeparation: Double(assessment.features.dominantLaneSeparation),
                    narrowSideLaneDetected: assessment.features.narrowSideLaneDetected,
                    mixedVerticalRegionsDetected: assessment.features.mixedVerticalRegionsDetected
                )
            }

            return Snapshot(
                pageIndex: pageIndex,
                mode: modeName(mode),
                decision: decision,
                decisionReason: reason,
                complexity: complexityRecord,
                fragments: fragmentRecords,
                lines: lineRecords,
                blocks: blockRecords,
                regions: regionRecords,
                gutters: gutterRecords,
                readingOrderEdges: effectiveEdges,
                removedReadingOrderEdges: removedEdges,
                orderedBlockIDs: readingOrder?.orderedBlockIDs ?? [],
                readingOrderConfidence: readingOrder?.confidence,
                readingOrderUsedFallback: readingOrder?.usedFallback,
                readingOrderDiagnostics: readingOrder?.diagnostics ?? []
            )
        }

        private func gutters(in region: PdfLayoutRegion) -> [GutterRecord] {
            let columns = region.columns.sorted {
                if $0.rect.minX != $1.rect.minX { return $0.rect.minX < $1.rect.minX }
                return $0.id < $1.id
            }
            guard columns.count >= 2 else { return [] }

            return zip(columns, columns.dropFirst()).compactMap { left, right in
                let width = right.rect.minX - left.rect.maxX
                guard width > 0 else { return nil }
                return GutterRecord(
                    regionID: region.id,
                    leftColumnID: left.id,
                    rightColumnID: right.id,
                    x: Double(left.rect.maxX),
                    width: Double(width)
                )
            }
        }

        private func effectiveReadingOrderEdges(
            readingOrder: PdfReadingOrderResult?,
            layout: PdfPageRegionLayout?,
            analysis: PdfSpecialStructureAnalysis?
        ) -> [EdgeRecord] {
            guard let readingOrder else { return [] }
            let order = readingOrder.orderedBlockIDs
            guard order.count >= 2 else { return [] }

            return zip(order, order.dropFirst()).map { from, to in
                let reason = effectiveReason(
                    from: from,
                    to: to,
                    layout: layout,
                    analysis: analysis
                )
                return EdgeRecord(
                    fromBlockID: from,
                    toBlockID: to,
                    confidence: readingOrder.confidence,
                    reason: reason
                )
            }
        }

        private func effectiveReason(
            from: Int,
            to: Int,
            layout: PdfPageRegionLayout?,
            analysis: PdfSpecialStructureAnalysis?
        ) -> String {
            if analysis?.readingOrderHints.footnoteBlockIDs.contains(to) == true {
                return PdfReadingOrderEdgeReason.footnotePlacement.rawValue
            }
            if analysis?.readingOrderHints.captionAttachments.contains(where: {
                $0.anchorBlockID == from && $0.blockID == to
            }) == true {
                return PdfReadingOrderEdgeReason.captionAttachment.rawValue
            }
            if let explicit = analysis?.readingOrderHints.additionalPrecedence.first(where: {
                $0.fromBlockID == from && $0.toBlockID == to
            }) {
                return explicit.reason.rawValue
            }

            guard let layout else { return "resolvedOrder" }
            let fromRegion = layout.regions.first { contains(blockID: from, in: $0) }
            let toRegion = layout.regions.first { contains(blockID: to, in: $0) }
            if fromRegion?.id != toRegion?.id {
                return PdfReadingOrderEdgeReason.regionSequence.rawValue
            }
            if toRegion?.sidebarBlockIDs.contains(to) == true {
                return PdfReadingOrderEdgeReason.sidebarAttachment.rawValue
            }
            if let region = fromRegion,
               let fromColumn = region.columns.first(where: { $0.blockIDs.contains(from) }),
               let toColumn = region.columns.first(where: { $0.blockIDs.contains(to) }) {
                return fromColumn.id == toColumn.id
                    ? PdfReadingOrderEdgeReason.sameColumn.rawValue
                    : PdfReadingOrderEdgeReason.columnSequence.rawValue
            }
            return PdfReadingOrderEdgeReason.sameColumn.rawValue
        }

        private func contains(blockID: Int, in region: PdfLayoutRegion) -> Bool {
            region.primaryBlockIDs.contains(blockID)
                || region.sidebarBlockIDs.contains(blockID)
                || region.spanningBlockIDs.contains(blockID)
        }

        private func edgeRecord(_ edge: PdfReadingOrderEdge) -> EdgeRecord {
            EdgeRecord(
                fromBlockID: edge.fromBlockID,
                toBlockID: edge.toBlockID,
                confidence: edge.confidence,
                reason: edge.reason.rawValue
            )
        }

        private func modeName(_ mode: PdfLayoutMode) -> String {
            switch mode {
            case .auto: return "auto"
            case .never: return "never"
            case .always: return "always"
            }
        }

        private func directionName(_ direction: PdfLayoutWritingDirection) -> String {
            switch direction {
            case .leftToRight: return "leftToRight"
            case .rightToLeft: return "rightToLeft"
            }
        }

        private func sourceName(_ source: PdfExtractionSource) -> String {
            switch source {
            case .native: return "native"
            case .ocr: return "ocr"
            case .empty: return "empty"
            }
        }

        private func clipped(_ text: String, limit: Int = 160) -> String {
            guard text.count > limit else { return text }
            let end = text.index(text.startIndex, offsetBy: limit)
            return String(text[..<end]) + "…"
        }
    }
}
