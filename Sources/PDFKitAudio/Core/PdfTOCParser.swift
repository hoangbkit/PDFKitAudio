import Foundation
import PDFKit

enum PdfTOCParser {
    static func parse(document: PDFDocument) -> [PdfTOCItem] {
        guard let outlineRoot = document.outlineRoot, outlineRoot.numberOfChildren > 0 else { return [] }
        return walk(outline: outlineRoot, level: 0, document: document)
    }

    private static func walk(outline: PDFOutline, level: Int, document: PDFDocument) -> [PdfTOCItem] {
        var items: [PdfTOCItem] = []
        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            let title = child.label ?? "Untitled"

            let resolvedPageIndex: Int
            if let page = child.destination?.page {
                let index = document.index(for: page)
                resolvedPageIndex = index == NSNotFound ? 0 : index
            } else {
                resolvedPageIndex = 0
            }

            let children = walk(outline: child, level: level + 1, document: document)
            items.append(PdfTOCItem(
                title: title,
                pageIndex: resolvedPageIndex,
                level: level,
                children: children
            ))
        }
        return items
    }
}
