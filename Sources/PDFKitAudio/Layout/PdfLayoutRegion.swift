import Foundation

enum PdfLayoutRegionKind: String, Equatable {
    case singleColumn
    case columnar
    case spanning
    case irregular
}

struct PdfLayoutColumn: Equatable {
    let id: Int
    let rect: CGRect
    let blockIDs: [Int]
    let confidence: Double
}

struct PdfLayoutRegion: Equatable {
    let id: Int
    let rect: CGRect
    let kind: PdfLayoutRegionKind
    let columns: [PdfLayoutColumn]
    let primaryBlockIDs: [Int]
    let sidebarBlockIDs: [Int]
    let spanningBlockIDs: [Int]
    let confidence: Double
}

struct PdfPageRegionLayout: Equatable {
    let regions: [PdfLayoutRegion]
    let primaryColumnCount: Int
    let sidebarBlockIDs: [Int]
    let spanningBlockIDs: [Int]

    var isMultiColumn: Bool {
        primaryColumnCount >= 2
    }
}
