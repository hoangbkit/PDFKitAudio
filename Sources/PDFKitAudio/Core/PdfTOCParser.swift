import Foundation
import PDFKit

enum PdfTOCParser {
    static func parse(document: PDFDocument) -> [PdfTOCItem] {
        guard let outlineRoot = document.outlineRoot, outlineRoot.numberOfChildren > 0 else { return [] }
        return walk(outline: outlineRoot, level: 0)
    }

    private static func walk(outline: PDFOutline, level: Int) -> [PdfTOCItem] {
        var items: [PdfTOCItem] = []
        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            let title = child.label ?? "Untitled"
            let pageIndex = child.destination?.page?.pageRef?.pageNumber.map { $0 - 1 } ?? 0
            // Fallback: try action destination
            let resolvedPageIndex: Int
            if let dest = child.destination, let page = dest.page, let idx = outline.document?.index(for: page) {
                resolvedPageIndex = idx
            } else {
                resolvedPageIndex = pageIndex
            }
            let children = walk(outline: child, level: level + 1)
            items.append(PdfTOCItem(title: title, pageIndex: resolvedPageIndex, level: level, children: children))
        }
        return items
    }
}

// Extension to safely get page number from PDFPageRef
private extension PDFPage {
    var pageRef: PDFPage? { self }
}

private extension Int {
    var pageNumber: Int? { self }
}
