import Foundation

enum PdfLayoutRole: String, Equatable {
    case body
    case heading
    case listItem
    case sidebar
    case pullQuote
    case caption
    case footnote
    case tableCell
    case runningMatter
    case unknown
}

struct PdfLayoutRoleAssignment: Equatable {
    let blockID: Int
    let role: PdfLayoutRole
    let confidence: Double
    let signals: [String]

    init(blockID: Int, role: PdfLayoutRole, confidence: Double, signals: [String] = []) {
        self.blockID = blockID
        self.role = role
        self.confidence = min(1, max(0, confidence))
        self.signals = signals
    }
}

struct PdfTableCell: Equatable {
    let blockID: Int
    let lineID: Int
    let text: String
    let rect: CGRect
}

struct PdfDetectedTable: Equatable {
    let cellsByRow: [[PdfTableCell]]
    let columnCount: Int
    let headerRowIndex: Int?
    let confidence: Double
    let linearizedText: String

    var blockIDs: Set<Int> {
        Set(cellsByRow.flatMap { $0.map(\.blockID) })
    }
}

struct PdfSpecialStructureAnalysis: Equatable {
    let assignments: [PdfLayoutRoleAssignment]
    let tables: [PdfDetectedTable]
    let readingOrderHints: PdfReadingOrderHints

    func role(for blockID: Int) -> PdfLayoutRole {
        assignments.first(where: { $0.blockID == blockID })?.role ?? .unknown
    }

    func confidence(for blockID: Int) -> Double {
        assignments.first(where: { $0.blockID == blockID })?.confidence ?? 0
    }
}
