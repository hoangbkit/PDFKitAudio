import Foundation
import PDFKit

enum PdfTOCParser {
    static func parse(document: PDFDocument) -> [PdfTOCItem] {
        guard let outlineRoot = document.outlineRoot, outlineRoot.numberOfChildren > 0 else {
            return []
        }
        return walk(outline: outlineRoot, level: 0, path: [], document: document)
    }

    private static func walk(
        outline: PDFOutline,
        level: Int,
        path: [Int],
        document: PDFDocument
    ) -> [PdfTOCItem] {
        var items: [PdfTOCItem] = []
        items.reserveCapacity(outline.numberOfChildren)

        for childIndex in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: childIndex) else { continue }

            let childPath = path + [childIndex]
            let title = normalizedTitle(child.label)
            let resolvedPageIndex = resolvePageIndex(for: child, document: document)
            let children = walk(
                outline: child,
                level: level + 1,
                path: childPath,
                document: document
            )

            items.append(PdfTOCItem(
                id: "outline:\(childPath.map(String.init).joined(separator: "/"))",
                title: title,
                pageIndex: resolvedPageIndex,
                level: level,
                children: children
            ))
        }

        return items
    }

    private static func resolvePageIndex(
        for outline: PDFOutline,
        document: PDFDocument
    ) -> Int? {
        var destinations: [PDFDestination] = []
        if let destination = outline.destination {
            destinations.append(destination)
        }
        if let goToAction = outline.action as? PDFActionGoTo {
            destinations.append(goToAction.destination)
        }

        for destination in destinations {
            guard let page = destination.page else { continue }
            let index = document.index(for: page)
            guard index != NSNotFound,
                  index >= 0,
                  index < document.pageCount else {
                continue
            }
            return index
        }

        return nil
    }

    private static func normalizedTitle(_ label: String?) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
