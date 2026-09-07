import Foundation

enum PdfReadingOrderEdgeReason: String, Equatable {
    case sameColumn
    case columnSequence
    case regionSequence
    case sidebarAttachment
    case footnotePlacement
    case captionAttachment
    case semanticHint
}

struct PdfReadingOrderEdge: Equatable {
    let fromBlockID: Int
    let toBlockID: Int
    let confidence: Double
    let reason: PdfReadingOrderEdgeReason
}

enum PdfSidebarReadingPolicy: String, Equatable {
    case afterPrimaryRegion
    case geometric
}

struct PdfReadingOrderAttachment: Equatable {
    let blockID: Int
    let anchorBlockID: Int
    let confidence: Double

    init(blockID: Int, anchorBlockID: Int, confidence: Double = 0.94) {
        self.blockID = blockID
        self.anchorBlockID = anchorBlockID
        self.confidence = min(1, max(0, confidence))
    }
}

struct PdfReadingOrderHints: Equatable {
    var writingDirection: PdfLayoutWritingDirection?
    var sidebarPolicy: PdfSidebarReadingPolicy
    var footnoteBlockIDs: Set<Int>
    var captionAttachments: [PdfReadingOrderAttachment]
    var additionalPrecedence: [PdfReadingOrderEdge]
    var unknownBlockIDs: Set<Int>

    init(
        writingDirection: PdfLayoutWritingDirection? = nil,
        sidebarPolicy: PdfSidebarReadingPolicy = .afterPrimaryRegion,
        footnoteBlockIDs: Set<Int> = [],
        captionAttachments: [PdfReadingOrderAttachment] = [],
        additionalPrecedence: [PdfReadingOrderEdge] = [],
        unknownBlockIDs: Set<Int> = []
    ) {
        self.writingDirection = writingDirection
        self.sidebarPolicy = sidebarPolicy
        self.footnoteBlockIDs = footnoteBlockIDs
        self.captionAttachments = captionAttachments
        self.additionalPrecedence = additionalPrecedence
        self.unknownBlockIDs = unknownBlockIDs
    }
}

struct PdfReadingOrderResult: Equatable {
    let orderedBlockIDs: [Int]
    let confidence: Double
    let writingDirection: PdfLayoutWritingDirection
    let removedEdges: [PdfReadingOrderEdge]
    let geometryConflictCount: Int
    let usedFallback: Bool
    let diagnostics: [String]
}
